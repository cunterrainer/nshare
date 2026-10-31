import 'dart:io';
import 'dart:convert';
import 'package:nshare/nshare.dart';
import 'package:test/test.dart';

void main() {
  test(
    'native CLI starts a queue-only owner receiver with an explicit verified policy',
    () async {
      final root = await Directory.systemTemp.createTemp('nshare_control_');
      LocalService? owner;
      try {
        final sender = await DeviceIdentity.load(
          Directory('${root.path}/sender'),
        );
        final receiver = await DeviceIdentity.load(
          Directory('${root.path}/receiver'),
        );
        final progress = <TransferProgress>[];
        owner = await LocalService.start(
          receiver.directory,
          receiver,
          TrustStore(receiver.directory),
          onProgress: progress.add,
        );
        final client = LocalServiceClient(receiver.directory);
        expect((await client.status())['receiverPort'], isNull);
        final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final port = probe.port;
        await probe.close();
        final output = Directory('${root.path}/out')..createSync();
        await File('${output.path}/keep.txt').writeAsString('existing bytes');
        final executable =
            '${root.path}/${Platform.isWindows ? 'control-cli.exe' : 'control-cli'}';
        final build = await Process.run(Platform.resolvedExecutable, [
          'compile',
          'exe',
          'bin/nshare.dart',
          '-o',
          executable,
        ]);
        expect(build.exitCode, 0, reason: build.stderr.toString());
        final control = await Process.run(executable, [
          '--state-dir',
          receiver.directory.path,
          'service',
          '--action',
          'start',
          '--output',
          output.path,
          '--port',
          '$port',
          '--accept',
          '--allow-compression',
          '--conflict',
          'skip',
          '--peer-fingerprint',
          sender.fingerprint,
        ]);
        expect(control.exitCode, 0, reason: control.stderr.toString());
        final state = jsonDecode(control.stdout as String) as Map;
        expect(state['receiverPort'], port);
        expect(state['approvalMode'], 'automatic');
        expect(state['conflict'], 'skip');
        expect(state['allowCompression'], isTrue);
        expect(state['output'], output.absolute.path);
        final source = File('${root.path}/keep.txt');
        await source.writeAsString('replacement bytes');
        final skipped = await sendPath(
          source.path,
          '127.0.0.1',
          port,
          sender,
          TrustStore(sender.directory),
          expectedFingerprint: receiver.fingerprint,
        );
        expect(skipped.skipped, 1);
        expect(
          await File('${output.path}/keep.txt').readAsString(),
          'existing bytes',
        );
        final fresh = File('${root.path}/fresh.txt');
        await fresh.writeAsString('received through the controlled owner');
        final result = await sendPath(
          fresh.path,
          '127.0.0.1',
          port,
          sender,
          TrustStore(sender.directory),
          expectedFingerprint: receiver.fingerprint,
          compression: true,
        );
        expect(result.files, 1);
        expect(
          await File('${output.path}/fresh.txt').readAsString(),
          await fresh.readAsString(),
        );
        expect(
          progress.any((p) => p.phase == TransferPhase.transferring),
          isTrue,
        );
        await expectLater(
          client.startReceiver(
            output: output,
            port: port,
            accept: true,
            allowCompression: false,
          ),
          throwsA(isA<NshareException>()),
        );
        await client.stop();
        await owner.done;
      } finally {
        await owner?.close();
        await root.delete(recursive: true);
      }
    },
  );
  test(
    'service shutdown waits for an in-flight receiver start to release its port',
    () async {
      final root = await Directory.systemTemp.createTemp('nshare_start_stop_');
      LocalService? owner;
      try {
        final identity = await DeviceIdentity.load(root);
        owner = await LocalService.start(root, identity, TrustStore(root));
        final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final port = probe.port;
        await probe.close();
        final opening = owner.startReceiver(
          output: Directory('${root.path}/out'),
          port: port,
          discover: false,
          approveOffer: (_) async => false,
        );
        final rejected = expectLater(opening, throwsA(isA<NshareException>()));
        await owner.close();
        await rejected;
        final rebound = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          port,
        );
        await rebound.close();
      } finally {
        await owner?.close();
        await root.delete(recursive: true);
      }
    },
  );
}
