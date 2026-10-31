import 'dart:io';
import 'package:nshare/nshare.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  setUp(
    () async => root = await Directory.systemTemp.createTemp('nshare_picker_'),
  );
  tearDown(() => root.delete(recursive: true));
  for (final directory in [false, true]) {
    test(
      'picker staging rejects ${directory ? 'a directory' : 'a missing file'} without retaining a snapshot',
      () async {
        final path = '${root.path}/selected';
        if (directory) await Directory(path).create();
        final imports = Directory('${root.path}/imports');
        await expectLater(
          stageSourceFile(File(path), imports),
          throwsA(isA<NshareException>()),
        );
        expect(await imports.exists(), isFalse);
      },
    );
  }
  test(
    'persistent picker copy survives cache deletion and completes a real queued TLS transfer',
    () async {
      final cached = File('${root.path}/picker-cache.txt');
      await cached.writeAsString('Picker data survives cache removal.');
      final staged = await stageSourceFile(
        cached,
        Directory('${root.path}/imports'),
      );
      await cached.delete();
      final sender = await DeviceIdentity.load(
        Directory('${root.path}/sender'),
      );
      final receiver = await DeviceIdentity.load(
        Directory('${root.path}/receiver'),
      );
      final server = await TransferReceiver.start(
        identity: receiver,
        trust: TrustStore(receiver.directory),
        output: Directory('${root.path}/out'),
        approveOffer: (_) async => true,
        expectedFingerprint: sender.fingerprint,
        bind: InternetAddress.loopbackIPv4,
        port: 0,
        discover: false,
      );
      try {
        final store = QueueStore(sender.directory);
        await store.add(
          staged.path,
          '127.0.0.1',
          server.port,
          receiver.fingerprint,
        );
        await QueueRunner(store, sender, TrustStore(sender.directory)).run();
        expect((await store.list()).single.status, JobStatus.completed);
        expect(
          await File('${root.path}/out/picker-cache.txt').readAsString(),
          'Picker data survives cache removal.',
        );
      } finally {
        await server.close();
      }
    },
  );
}
