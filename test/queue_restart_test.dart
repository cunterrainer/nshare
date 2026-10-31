import 'dart:io';
import 'package:nshare/nshare.dart';
import 'package:nshare/src/storage/storage.dart';
import 'package:test/test.dart';

void main() {
  test(
    'queued restart discards a corrupt retained prefix and verifies the replacement',
    () async {
      final root = await Directory.systemTemp.createTemp('nshare_restart_');
      TransferReceiver? server;
      try {
        final source = File('${root.path}/file.bin');
        await source.writeAsBytes(List.filled(140000, 1));
        final sender = await DeviceIdentity.load(
          Directory('${root.path}/sender'),
        );
        final receiver = await DeviceIdentity.load(
          Directory('${root.path}/receiver'),
        );
        final output = Directory('${root.path}/out');
        final manifest = await Manifest.collect(source.path);
        final destination = await DestinationStore.open(
          output,
          manifest,
          sender.fingerprint,
          ConflictPolicy.refuse,
        );
        await destination
            .partial(manifest.entries.single)
            .writeAsBytes(List.filled(65536, 2));
        server = await TransferReceiver.start(
          identity: receiver,
          trust: TrustStore(receiver.directory),
          output: output,
          approveOffer: (_) async => true,
          expectedFingerprint: sender.fingerprint,
          bind: InternetAddress.loopbackIPv4,
          port: 0,
          discover: false,
        );
        final store = QueueStore(sender.directory);
        final job = await store.add(
          source.path,
          '127.0.0.1',
          server.port,
          receiver.fingerprint,
        );
        await QueueRunner(store, sender, TrustStore(sender.directory)).run();
        expect((await store.list()).single.status, JobStatus.failed);
        expect(await File('${output.path}/file.bin').exists(), isFalse);
        await store.change(job.id, 'restart');
        expect((await store.list()).single.resume, isFalse);
        await QueueRunner(store, sender, TrustStore(sender.directory)).run();
        expect((await store.list()).single.status, JobStatus.completed);
        expect(
          await File('${output.path}/file.bin').readAsBytes(),
          await source.readAsBytes(),
        );
      } finally {
        await server?.close();
        await root.delete(recursive: true);
      }
    },
  );
}
