import 'dart:async';
import 'dart:io';
import 'package:nshare/nshare.dart';
import 'package:test/test.dart';

void main() {
  test(
    'queue retries a real unavailable peer and completes when its listener returns',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'nshare_queue_reconnect_',
      );
      final sender = await DeviceIdentity.load(
        Directory('${root.path}/sender'),
      );
      final receiver = await DeviceIdentity.load(
        Directory('${root.path}/receiver'),
      );
      final source = File('${root.path}/source.txt');
      await source.writeAsString('automatic network recovery');
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = probe.port;
      await probe.close();
      final queue = QueueStore(sender.directory);
      await queue.add(source.path, '127.0.0.1', port, receiver.fingerprint);
      final runner = QueueRunner(queue, sender, TrustStore(sender.directory));
      final running = runner.run();
      TransferReceiver? server;
      try {
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while ((await queue.list()).single.status != JobStatus.waitingForPeer) {
          if (DateTime.now().isAfter(deadline)) {
            throw TimeoutException('Job did not enter network backoff');
          }
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        server = await TransferReceiver.start(
          identity: receiver,
          trust: TrustStore(receiver.directory),
          output: Directory('${root.path}/out'),
          approveOffer: (_) async => true,
          expectedFingerprint: sender.fingerprint,
          bind: InternetAddress.loopbackIPv4,
          port: port,
          discover: false,
        );
        await running.timeout(const Duration(seconds: 20));
        final job = (await queue.list()).single;
        expect(job.status, JobStatus.completed);
        expect(job.retryCount, inInclusiveRange(1, 3));
        expect(
          await File('${root.path}/out/source.txt').readAsString(),
          'automatic network recovery',
        );
      } finally {
        runner.stop();
        await running;
        await server?.close();
        await root.delete(recursive: true);
      }
    },
  );
}
