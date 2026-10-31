import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:nshare/nshare.dart';
import 'package:path/path.dart' as p;

class CliResult {
  CliResult(this.code, this.out, this.err);
  final int code;
  final String out;
  final String err;
  @override
  String toString() => 'exit=$code\nstdout: $out\nstderr: $err';
}

class CliChild {
  CliChild(this.process, {void Function(String)? onLine}) {
    final stdoutDone = process.stdout
        .transform(utf8.decoder)
        .forEach(_out.write);
    final stderrDone = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .forEach((line) {
          _err.writeln(line);
          if (line.startsWith('Listening on') && !_ready.isCompleted) {
            _ready.complete();
          }
          onLine?.call(line);
        });
    result = process.exitCode.then((code) async {
      await Future.wait([stdoutDone, stderrDone]);
      return CliResult(code, _out.toString(), _err.toString());
    });
    unawaited(process.stdin.close());
  }
  final Process process;
  final _out = StringBuffer(), _err = StringBuffer();
  final _ready = Completer<void>();
  late final Future<CliResult> result;
  Future<void> ready() => Future.any([
    _ready.future,
    result.then<void>(
      (result) => throw StateError('Receiver exited before listening: $result'),
    ),
  ]).timeout(const Duration(seconds: 20));
  Future<CliResult> finish() => result.timeout(const Duration(seconds: 30));
  Future<void> stop() async {
    process.kill();
    await result.timeout(const Duration(seconds: 10));
  }
}

/// Native processes only. Each scenario has isolated identity/trust/output paths.
class NativeCli {
  NativeCli._(this.root, this.executable, this.sender, this.receiver);
  final Directory root;
  final String executable;
  final DeviceIdentity sender, receiver;
  final _ports = <int>{};
  static Future<NativeCli> create() async {
    final root = await Directory.systemTemp.createTemp('nshare_native_matrix_');
    try {
      final executable = p.join(
        root.path,
        Platform.isWindows ? 'nshare.exe' : 'nshare',
      );
      final build = await Process.run(Platform.resolvedExecutable, [
        'compile',
        'exe',
        'bin/nshare.dart',
        '-o',
        executable,
      ]);
      if (build.exitCode != 0) {
        throw StateError('${build.stdout}\n${build.stderr}');
      }
      final sender = await DeviceIdentity.load(
        Directory(p.join(root.path, 'seed-sender')),
      );
      final receiver = await DeviceIdentity.load(
        Directory(p.join(root.path, 'seed-receiver')),
      );
      return NativeCli._(root, executable, sender, receiver);
    } catch (_) {
      await root.delete(recursive: true);
      rethrow;
    }
  }

  Future<void> close() => root.delete(recursive: true);
  Future<Scenario> scenario() async {
    final directory = await root.createTemp('case_');
    final senderState = Directory(p.join(directory.path, 'sender'));
    final receiverState = Directory(p.join(directory.path, 'receiver'));
    for (final pair in [(sender, senderState), (receiver, receiverState)]) {
      await pair.$2.create();
      await File(
        p.join(pair.$1.directory.path, 'identity.json'),
      ).copy(p.join(pair.$2.path, 'identity.json'));
    }
    return Scenario(this, directory, senderState, receiverState);
  }

  Future<int> port({InternetAddress? address}) async {
    while (true) {
      final probe = await ServerSocket.bind(
        address ?? InternetAddress.loopbackIPv4,
        0,
      );
      final port = probe.port;
      await probe.close();
      if (_ports.add(port)) return port;
    }
  }

  Future<CliChild> start(
    Directory state,
    List<String> args, {
    void Function(String)? onLine,
  }) async => CliChild(
    await Process.start(executable, ['--state-dir', state.path, ...args]),
    onLine: onLine,
  );
  Future<CliResult> run(Directory state, List<String> args) async {
    final child = await start(state, args);
    try {
      return await child.finish();
    } finally {
      await child.stop();
    }
  }
}

class Scenario {
  Scenario(this.cli, this.directory, this.senderState, this.receiverState);
  final NativeCli cli;
  final Directory directory, senderState, receiverState;
  Directory get output => Directory(p.join(directory.path, 'received'));
  Future<File> file(String name, List<int> bytes) async {
    final file = File(p.join(directory.path, 'source', name));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
    return file;
  }

  Future<CliChild> receive(
    int port, {
    String conflict = 'refuse',
    bool once = true,
    bool accept = true,
    bool sharedIdentity = false,
    String? pin,
    bool usePin = true,
    String host = '127.0.0.1',
    void Function(String)? onLine,
  }) async {
    final child = await cli.start(
      sharedIdentity ? senderState : receiverState,
      [
        'receive',
        '--bind',
        host,
        '--port',
        '$port',
        '--no-discover',
        '--output',
        output.path,
        '--conflict',
        conflict,
        if (once) '--once',
        if (accept) '--accept',
        if (usePin) ...['--peer-fingerprint', pin ?? cli.sender.fingerprint],
      ],
      onLine: onLine,
    );
    try {
      await child.ready();
      return child;
    } catch (_) {
      await child.stop();
      rethrow;
    }
  }

  Future<CliResult> send(
    String path,
    int port, {
    bool sharedIdentity = false,
    bool usePin = true,
    bool resume = true,
    String host = '127.0.0.1',
  }) => cli.run(senderState, [
    'send',
    path,
    '--ip',
    host,
    '--port',
    '$port',
    if (!resume) '--no-resume',
    if (usePin) ...[
      '--peer-fingerprint',
      sharedIdentity ? cli.sender.fingerprint : cli.receiver.fingerprint,
    ],
  ]);
}
