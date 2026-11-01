import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:nshare/nshare.dart';
import 'package:nshare_app/controller.dart';

void main() {
  late Directory root;
  late String executable;
  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('nshare_flutter_interop_');
    executable = '${root.path}/${Platform.isWindows ? 'nshare.exe' : 'nshare'}';
    final build = await Process.run(
      Platform.environment['NSHARE_DART'] ?? 'dart',
      ['compile', 'exe', 'bin/nshare.dart', '-o', executable],
      workingDirectory: '../..',
    );
    if (build.exitCode != 0) {
      throw StateError('CLI compilation failed: ${build.stderr}');
    }
  });
  tearDownAll(() => root.delete(recursive: true));
  Future<NshareController> controller(String name) async {
    final c = NshareController(
      stateDirectory: Directory('${root.path}/$name/state'),
      receiveDirectory: Directory('${root.path}/$name/received'),
    );
    c.confirm = (_, _) async => true;
    await c.initialize();
    if (!c.ready) throw StateError(c.error ?? 'not initialized');
    return c;
  }

  Future<int> freePort() async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = s.port;
    await s.close();
    return port;
  }

  Future<void> awaitCompleted(NshareController c) async {
    final timeout = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(timeout)) {
      final jobs = await QueueStore(c.stateDirectory!).list();
      if (jobs.any((j) => j.status == JobStatus.failed)) {
        throw StateError('Job failed: ${jobs.first.error}');
      }
      if (jobs.isNotEmpty &&
          jobs.every((j) => j.status == JobStatus.completed)) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    throw TimeoutException('Transfer did not complete');
  }

  test(
    'controller code pairing records mutual trust and then sends a real folder',
    () async {
      final sender = await controller('code-sender');
      final receiver = await controller('code-receiver');
      final codes = <String>[];
      sender.confirm = (_, details) async {
        codes.add(details);
        return true;
      };
      receiver.confirm = (_, details) async {
        codes.add(details);
        return true;
      };
      try {
        await receiver.startReceiver(port: 0);
        final port = receiver.service!.receiver!.port;
        final pin = await sender.pairAddress('127.0.0.1', port);
        expect(pin, receiver.identity!.fingerprint);
        expect(
          codes.where((v) => v.startsWith('Matching code:')).toSet(),
          hasLength(1),
        );
        final folder = await Directory('${root.path}/paired-folder').create();
        await File(
          '${folder.path}/nested.txt',
        ).writeAsString('paired controller folder');
        await sender.enqueue(folder.path, '127.0.0.1', port, pin);
        await awaitCompleted(sender);
        expect(
          await File(
            '${receiver.receiveDirectory!.path}/paired-folder/nested.txt',
          ).readAsString(),
          'paired controller folder',
        );
      } finally {
        await sender.shutdown();
        sender.dispose();
        await receiver.shutdown();
        receiver.dispose();
      }
    },
  );

  testWidgets('native CLI sends real bytes to Flutter receiver controller', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final c = await controller('cli-to-flutter');
      try {
        await c.startReceiver(port: 0);
        final file = File('${root.path}/cli-source.bin');
        final data = List.generate(131073, (i) => i % 251);
        await file.writeAsBytes(data);
        final sent = await Process.run(executable, [
          '--state-dir',
          '${root.path}/native-sender',
          'send',
          file.path,
          '--ip',
          '127.0.0.1',
          '--port',
          '${c.service!.receiver!.port}',
          '--peer-fingerprint',
          c.identity!.fingerprint,
        ]);
        expect(sent.exitCode, 0, reason: sent.stderr.toString());
        expect(
          await File(
            '${c.receiveDirectory!.path}/cli-source.bin',
          ).readAsBytes(),
          data,
        );
      } finally {
        await c.shutdown();
        c.dispose();
      }
    });
  });
  testWidgets(
    'Flutter persistent queue sends real bytes to native CLI receiver',
    (tester) async {
      await tester.runAsync(() async {
        final c = await controller('flutter-to-cli');
        final receiverState = Directory('${root.path}/native-receiver');
        final identity = await DeviceIdentity.load(receiverState);
        final port = await freePort();
        final process = await Process.start(executable, [
          '--state-dir',
          receiverState.path,
          'receive',
          '--port',
          '$port',
          '--bind',
          '127.0.0.1',
          '--no-discover',
          '--once',
          '--accept',
          '--output',
          '${root.path}/native-out',
          '--peer-fingerprint',
          c.identity!.fingerprint,
        ]);
        final ready = Completer<void>();
        final stderr = StringBuffer();
        final logs = process.stderr
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen((line) {
              stderr.writeln(line);
              if (line.startsWith('Listening on') && !ready.isCompleted) {
                ready.complete();
              }
            });
        final drained = process.stdout.drain<void>();
        try {
          await ready.future.timeout(const Duration(seconds: 10));
          final file = File('${root.path}/flutter-source.txt');
          await file.writeAsString('Flutter → CLI 日本語');
          await c.enqueue(file.path, '127.0.0.1', port, identity.fingerprint);
          await awaitCompleted(c);
          expect(await process.exitCode, 0, reason: stderr.toString());
          expect(
            await File(
              '${root.path}/native-out/flutter-source.txt',
            ).readAsString(),
            'Flutter → CLI 日本語',
          );
        } finally {
          process.kill();
          await process.exitCode;
          await logs.cancel();
          await drained;
          await c.shutdown();
          c.dispose();
        }
      });
    },
  );
  testWidgets(
    'two Flutter application controllers exchange a real queued folder',
    (tester) async {
      await tester.runAsync(() async {
        final sender = await controller('flutter-sender');
        final receiver = await controller('flutter-receiver');
        try {
          await receiver.startReceiver(port: 0);
          final folder = Directory('${root.path}/flutter-folder')..createSync();
          await File('${folder.path}/empty').writeAsString('');
          await File(
            '${folder.path}/notes.txt',
          ).writeAsString('real Flutter TLS transfer');
          await sender.enqueue(
            folder.path,
            '127.0.0.1',
            receiver.service!.receiver!.port,
            receiver.identity!.fingerprint,
          );
          await awaitCompleted(sender);
          expect(
            await File(
              '${receiver.receiveDirectory!.path}/flutter-folder/notes.txt',
            ).readAsString(),
            'real Flutter TLS transfer',
          );
          expect(
            await File(
              '${receiver.receiveDirectory!.path}/flutter-folder/empty',
            ).length(),
            0,
          );
        } finally {
          await sender.shutdown();
          await receiver.shutdown();
          sender.dispose();
          receiver.dispose();
        }
      });
    },
  );
}
