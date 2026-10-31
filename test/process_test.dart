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

  final usedPorts = <int>{};
  Future<int> freePort() async {
    while (true) {
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = probe.port;
      await probe.close();
      // Keep certificate pins from different test scenarios on distinct endpoints.
      if (usedPorts.add(port)) return port;
    }
  }

  Future<RunningReceiver> receive(
    int port,
    String output, {
    void Function(String)? onLine,
    Directory? state,
    bool once = true,
    String bind = '127.0.0.1',
  }) async {
    final process = await Process.start(executable, [
      '--state-dir',
      (state ?? receiver.directory).path,
      'receive',
      '--bind',
      bind,
      '--port',
      '$port',
      '--output',
      output,
      '--no-discover',
      if (once) '--once',
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

  Future<ProcessResult> sendFile(
    int port,
    String source, {
    String host = '127.0.0.1',
    String? fingerprint,
  }) => Process.run(executable, [
    '--state-dir',
    sender.directory.path,
    'send',
    source,
    '--ip',
    host,
    '--port',
    '$port',
    '--peer-fingerprint',
    fingerprint ?? receiver.fingerprint,
  ]).timeout(const Duration(seconds: 30));

  Future<void> stop(RunningReceiver running) async {
    running.process.kill();
    await running.process.exitCode.timeout(const Duration(seconds: 10));
  }

  test(
    'compiled CLI transfers a directory with spaces, Unicode, binary and empty entries locally',
    () async {
      final source = Directory('${temp.path}/photos with spaces');
      await Directory(
        '${source.path}/文件/empty directory',
      ).create(recursive: true);
      await File('${source.path}/empty.txt').writeAsString('');
      await File(
        '${source.path}/文件/照片.bin',
      ).writeAsBytes(List.generate(1048583, (i) => i % 256));
      for (var i = 0; i < 64; i++) {
        await File(
          '${source.path}/note $i.txt',
        ).writeAsString('file $i — café 日本語');
      }
      final manifest = await Manifest.collect(source.path);
      final port = await freePort();
      final output = Directory('${temp.path}/folder-output');
      final running = await receive(port, output.path);
      try {
        await running.ready;
        final result = await sendFile(port, source.path);
        expect(
          result.exitCode,
          0,
          reason: '${result.stderr}\n${running.output}',
        );
        expect(
          await running.process.exitCode.timeout(const Duration(seconds: 10)),
          0,
          reason: running.output.toString(),
        );
        expect(
          result.stdout,
          contains(
            '${manifest.files} verified files, 0 skipped, ${manifest.bytes} bytes sent',
          ),
        );
        for (final entry in manifest.entries) {
          final destination = p.joinAll([
            output.path,
            ...entry.path.split('/'),
          ]);
          if (entry.directory) {
            expect(
              await Directory(destination).exists(),
              isTrue,
              reason: entry.path,
            );
          } else {
            expect(
              await File(destination).length(),
              entry.size,
              reason: entry.path,
            );
            expect(
              await hashFile(File(destination)),
              entry.hash,
              reason: entry.path,
            );
          }
        }
      } finally {
        await stop(running);
      }
    },
  );

  test(
    'sender and receiver share one local identity and retries send zero file bytes',
    () async {
      final source = File('${temp.path}/shared-identity.txt')
        ..writeAsStringSync('same device');
      final output = '${temp.path}/shared-output';
      for (var attempt = 0; attempt < 2; attempt++) {
        final port = await freePort();
        final running = await receive(port, output, state: sender.directory);
        try {
          await running.ready;
          final result = await sendFile(
            port,
            source.path,
            fingerprint: sender.fingerprint,
          );
          expect(
            result.exitCode,
            0,
            reason: '${result.stderr}\n${running.output}',
          );
          expect(
            await running.process.exitCode.timeout(const Duration(seconds: 10)),
            0,
          );
          expect(
            result.stdout,
            contains('${attempt == 0 ? await source.length() : 0} bytes sent'),
          );
          expect(
            await File('$output/shared-identity.txt').readAsString(),
            'same device',
          );
        } finally {
          await stop(running);
        }
      }
      final ownTrust =
          (await TrustStore(sender.directory).list())[sender.fingerprint]
              as Map;
      expect(ownTrust['endpoints'], hasLength(2));
    },
  );

  test(
    'one running receiver accepts multiple independent sender processes',
    () async {
      final port = await freePort();
      final output = '${temp.path}/persistent-output';
      final running = await receive(port, output, once: false);
      try {
        await running.ready;
        for (var i = 0; i < 3; i++) {
          final source = File('${temp.path}/session-$i.txt')
            ..writeAsStringSync('session $i');
          final result = await sendFile(port, source.path);
          expect(
            result.exitCode,
            0,
            reason: '${result.stderr}\n${running.output}',
          );
          expect(
            await File('$output/session-$i.txt').readAsString(),
            'session $i',
          );
        }
      } finally {
        await stop(running);
      }
    },
  );

  test(
    'compiled CLI refuses an existing file without reporting success or overwriting it',
    () async {
      final source = File('${temp.path}/protected.txt')
        ..writeAsStringSync('replacement');
      final output = Directory('${temp.path}/protected-output')..createSync();
      final destination = File('${output.path}/protected.txt')
        ..writeAsStringSync('original');
      final port = await freePort();
      final running = await receive(port, output.path);
      try {
        await running.ready;
        final result = await sendFile(port, source.path);
        expect(result.exitCode, 1);
        expect(result.stdout, isNot(contains('Complete:')));
        expect(result.stderr, contains('conflict'));
        expect(
          await running.process.exitCode.timeout(const Duration(seconds: 10)),
          1,
        );
        expect(await destination.readAsString(), 'original');
      } finally {
        await stop(running);
      }
    },
  );

  test('compiled CLI sends over IPv6 loopback on the same device', () async {
    ServerSocket probe;
    try {
      probe = await ServerSocket.bind(InternetAddress.loopbackIPv6, 0);
    } on SocketException {
      markTestSkipped('This host does not provide IPv6 loopback');
      return;
    }
    final port = probe.port;
    await probe.close();
    final source = File('${temp.path}/ipv6.txt')
      ..writeAsStringSync('IPv6 local transfer');
    final output = '${temp.path}/ipv6-output';
    final running = await receive(port, output, bind: '::1');
    try {
      await running.ready;
      final result = await sendFile(port, source.path, host: '::1');
      expect(result.exitCode, 0, reason: '${result.stderr}\n${running.output}');
      expect(
        await running.process.exitCode.timeout(const Duration(seconds: 10)),
        0,
      );
      expect(
        await File('$output/ipv6.txt').readAsString(),
        'IPv6 local transfer',
      );
    } finally {
      await stop(running);
    }
  });
}
