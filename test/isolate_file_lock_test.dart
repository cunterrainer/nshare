import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'package:nshare/nshare.dart';
import 'package:nshare/src/core/file_lock.dart';
import 'package:test/test.dart';

Future<void> attemptLease(List<Object> arguments) async {
  final port = arguments[0] as SendPort;
  try {
    final lease = await FileLease.acquire(File(arguments[1] as String));
    await lease.close();
    port.send('acquired');
  } on FileSystemException {
    port.send('busy');
  }
}

Future<void> waitForLease(List<Object> arguments) async {
  final port = arguments[0] as SendPort;
  port.send('ready');
  final lease = await FileLease.acquire(
    File(arguments[1] as String),
    blocking: true,
  );
  await lease.close();
  port.send('acquired');
}

Future<void> incrementState(List<Object> arguments) async {
  final port = arguments[0] as SendPort;
  final store = StateStore(Directory(arguments[1] as String), 'counter');
  for (var i = 0; i < 20; i++) {
    await store.update((data) async {
      final before = data['counter'] as int;
      await Future<void>.delayed(const Duration(milliseconds: 1));
      data['counter'] = before + 1;
    });
  }
  port.send('done');
}

Future<void> attemptService(List<Object> arguments) async {
  final port = arguments[0] as SendPort;
  final state = Directory(arguments[1] as String);
  final identity = await DeviceIdentity.load(state);
  try {
    final service = await LocalService.start(
      state,
      identity,
      TrustStore(state),
    );
    await service.close();
    port.send('owned');
  } on NshareException catch (error) {
    port.send(error.code);
  }
}

void main() {
  late Directory root;
  setUp(
    () async => root = await Directory.systemTemp.createTemp('isolate_lock_'),
  );
  tearDown(() => root.delete(recursive: true));
  test('another isolate cannot acquire a held owner lease', () async {
    final file = File('${root.path}/owner.lock');
    final owner = await FileLease.acquire(file);
    final port = ReceivePort();
    try {
      await Isolate.spawn(attemptLease, [port.sendPort, file.path]);
      expect(await port.first.timeout(const Duration(seconds: 10)), 'busy');
    } finally {
      port.close();
      await owner.close();
    }
    final replacement = await FileLease.acquire(file);
    await replacement.close();
  });
  test(
    'blocking isolate acquires the lease after its owner releases it',
    () async {
      final file = File('${root.path}/blocking.lock');
      final owner = await FileLease.acquire(file);
      final port = ReceivePort();
      final events = StreamIterator(port);
      try {
        await Isolate.spawn(waitForLease, [port.sendPort, file.path]);
        expect(await events.moveNext(), isTrue);
        expect(events.current, 'ready');
        var acquired = false;
        final next = events.moveNext().then((value) {
          acquired = true;
          return value;
        });
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(acquired, isFalse);
        await owner.close();
        expect(await next.timeout(const Duration(seconds: 10)), isTrue);
        expect(events.current, 'acquired');
      } finally {
        await owner.close();
        await events.cancel();
        port.close();
      }
    },
  );
  test(
    'read-modify-write transactions serialize across Flutter-style isolates',
    () async {
      final store = StateStore(root, 'counter');
      await store.update((data) {
        data['counter'] = 0;
      });
      final ports = List.generate(3, (_) => ReceivePort());
      try {
        await Future.wait([
          for (final port in ports)
            Isolate.spawn(incrementState, [port.sendPort, root.path]),
        ]);
        await Future.wait([for (final port in ports) port.first]);
        expect((await store.read())['counter'], 60);
      } finally {
        for (final port in ports) {
          port.close();
        }
      }
    },
  );
  test(
    'a second engine attaches instead of replacing an existing service owner',
    () async {
      final identity = await DeviceIdentity.load(root);
      final service = await LocalService.start(
        root,
        identity,
        TrustStore(root),
      );
      final port = ReceivePort();
      try {
        await Isolate.spawn(attemptService, [port.sendPort, root.path]);
        expect(await port.first.timeout(const Duration(seconds: 15)), 'busy');
        expect(
          (await LocalServiceClient(root).status())['queueRunning'],
          isTrue,
        );
      } finally {
        port.close();
        await service.close();
      }
    },
  );
  test(
    'failed contenders preserve the original lock seen by older CLI processes',
    () async {
      final file = File('${root.path}/legacy.lock');
      final owner = await FileLease.acquire(file);
      try {
        await expectLater(
          FileLease.acquire(file),
          throwsA(isA<FileSystemException>()),
        );
        final script = await File('${root.path}/legacy.dart').writeAsString('''
import 'dart:io';
Future<void> main(List<String> args) async {
  final file = await File(args.single).open(mode: FileMode.append);
  var status = 0;
  try { await file.lock(FileLock.exclusive); }
  on FileSystemException { status = 73; }
  finally { await file.close(); }
  exit(status);
}
''');
        final result = await Process.run(Platform.resolvedExecutable, [
          script.path,
          file.path,
        ]);
        expect(
          result.exitCode,
          73,
          reason: '${result.stdout} ${result.stderr}',
        );
      } finally {
        await owner.close();
      }
    },
  );
}
