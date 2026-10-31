import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:nshare/core.dart';
import 'package:nshare/src/storage/storage.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

class RunningReceiver {
  RunningReceiver(this.process, this.ready, this.output);
  final Process process;
  final Future<void> ready;
  final StringBuffer output;
}

void main() {
  late Directory temp;
  late String executable;
  late DeviceIdentity sender, receiver;
  setUpAll(() async {
    temp = await Directory.systemTemp.createTemp('nshare_process_');
    executable = p.join(
      temp.path,
      Platform.isWindows ? 'nshare.exe' : 'nshare',
    );
    final build = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'exe',
      'bin/nshare.dart',
      '-o',
      executable,
    ]);
    expect(build.exitCode, 0, reason: '${build.stdout}\n${build.stderr}');
    sender = await DeviceIdentity.load(Directory('${temp.path}/sender'));
    receiver = await DeviceIdentity.load(Directory('${temp.path}/receiver'));
  });
  tearDownAll(() => temp.delete(recursive: true));

  Future<int> freePort() async {
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();
    return port;
  }

  Future<RunningReceiver> receive(
    int port,
    String output, {
    void Function(String)? onLine,
  }) async {
    final process = await Process.start(executable, [
      '--state-dir',
      receiver.directory.path,
      'receive',
      '--bind',
      '127.0.0.1',
      '--port',
      '$port',
      '--output',
      output,
      '--no-discover',
      '--once',
      '--accept',
      '--peer-fingerprint',
      sender.fingerprint,
    ]);
    final ready = Completer<void>();
    final messages = StringBuffer();
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          messages.writeln(line);
          if (line.startsWith('Listening on') && !ready.isCompleted) {
            ready.complete();
          }
          onLine?.call(line);
        });
    process.stdout.transform(utf8.decoder).listen(messages.write);
    unawaited(
      process.exitCode.then((code) {
        if (!ready.isCompleted) {
          ready.completeError(StateError('Receiver exited $code: $messages'));
        }
      }),
    );
    return RunningReceiver(
      process,
      ready.future.timeout(const Duration(seconds: 15)),
      messages,
    );
  }

  Future<Process> send(int port, String source) => Process.start(executable, [
    '--state-dir',
    sender.directory.path,
    'send',
    source,
    '--ip',
    '127.0.0.1',
    '--port',
    '$port',
    '--peer-fingerprint',
    receiver.fingerprint,
  ]);

  test(
    'compiled CLI survives killed sender and resumes after both processes restart',
    () async {
      final file = File('${temp.path}/large.bin');
      final writer = file.openWrite();
      final block = List<int>.generate(65536, (i) => i % 251);
      for (var i = 0; i < 512; i++) {
        writer.add(block);
      }
      await writer.close();
      final output = '${temp.path}/output';
      var port = await freePort();
      Process? sending;
      final interrupted = Completer<void>();
      var receiving = await receive(
        port,
        output,
        onLine: (line) {
          if (line.startsWith('transferring:') &&
              !interrupted.isCompleted &&
              sending != null) {
            sending.kill();
            interrupted.complete();
          }
        },
      );
      try {
        await receiving.ready;
        sending = await send(port, file.path);
        final first = sending;
        final logs = StringBuffer();
        first.stdout.transform(utf8.decoder).listen(logs.write);
        first.stderr.transform(utf8.decoder).listen(logs.write);
        await interrupted.future.timeout(const Duration(seconds: 30));
        expect(
          await first.exitCode.timeout(const Duration(seconds: 10)),
          isNot(0),
        );
        expect(
          await receiving.process.exitCode.timeout(const Duration(seconds: 15)),
          isNot(0),
        );
        expect(await File('$output/large.bin').exists(), isFalse);
        final parts = await Directory('$output/.nshare-state')
            .list(recursive: true)
            .where((e) => e is File && e.path.endsWith('.part'))
            .cast<File>()
            .toList();
        expect(await parts.single.length(), greaterThan(0));
        expect(await parts.single.length(), lessThan(await file.length()));
      } finally {
        sending?.kill();
        receiving.process.kill();
        await receiving.process.exitCode;
      }
      port = await freePort();
      receiving = await receive(port, output);
      try {
        await receiving.ready;
        final result = await Process.run(executable, [
          '--state-dir',
          sender.directory.path,
          'send',
          file.path,
          '--ip',
          '127.0.0.1',
          '--port',
          '$port',
          '--peer-fingerprint',
          receiver.fingerprint,
        ]);
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}\n${receiving.output}',
        );
        expect(
          await receiving.process.exitCode.timeout(const Duration(seconds: 20)),
          0,
          reason: receiving.output.toString(),
        );
        expect(await hashFile(File('$output/large.bin')), await hashFile(file));
        final sent = RegExp(
          r'(\d+) bytes sent',
        ).firstMatch(result.stdout as String);
        expect(sent, isNotNull);
        expect(int.parse(sent!.group(1)!), lessThan(await file.length()));
      } finally {
        receiving.process.kill();
        await receiving.process.exitCode;
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
