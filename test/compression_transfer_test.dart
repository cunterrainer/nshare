import 'dart:io';
import 'dart:math';
import 'package:nshare/nshare.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late DeviceIdentity sender, receiver;
  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('nshare_compressed_');
    sender = await DeviceIdentity.load(Directory('${root.path}/sender'));
    receiver = await DeviceIdentity.load(Directory('${root.path}/receiver'));
  });
  tearDownAll(() => root.delete(recursive: true));
  for (final compression in [false, true]) {
    for (final allowed in [false, true]) {
      test('TLS compression requested=$compression allowed=$allowed', () async {
        final file = File('${root.path}/data-$compression-$allowed.bin');
        await file.writeAsBytes(List.filled(140000, 42));
        final errors = <Object>[];
        final server = await TransferReceiver.start(
          identity: receiver,
          trust: TrustStore(receiver.directory),
          output: Directory('${file.path}.out'),
          approveOffer: (_) async => true,
          expectedFingerprint: sender.fingerprint,
          bind: InternetAddress.loopbackIPv4,
          port: 0,
          discover: false,
          allowCompression: allowed,
          onError: errors.add,
        );
        try {
          final operation = sendPath(
            file.path,
            '127.0.0.1',
            server.port,
            sender,
            TrustStore(sender.directory),
            expectedFingerprint: receiver.fingerprint,
            compression: compression,
          );
          if (compression && !allowed) {
            await expectLater(operation, throwsA(isA<NshareException>()));
            expect(
              await File(
                '${file.path}.out/${file.uri.pathSegments.last}',
              ).exists(),
              isFalse,
            );
          } else {
            final result = await operation;
            expect(result.files, 1);
            expect(result.networkBytes, compression ? lessThan(1000) : 140000);
            expect(
              await File(
                '${file.path}.out/${file.uri.pathSegments.last}',
              ).readAsBytes(),
              await file.readAsBytes(),
            );
          }
        } finally {
          await server.close();
        }
      });
    }
  }
  test('incompressible TLS blocks use raw DATA without expansion', () async {
    final random = Random(42);
    final file = File('${root.path}/random.bin');
    await file.writeAsBytes(List.generate(140000, (_) => random.nextInt(256)));
    final server = await TransferReceiver.start(
      identity: receiver,
      trust: TrustStore(receiver.directory),
      output: Directory('${root.path}/random-out'),
      approveOffer: (_) async => true,
      expectedFingerprint: sender.fingerprint,
      bind: InternetAddress.loopbackIPv4,
      port: 0,
      discover: false,
      allowCompression: true,
    );
    try {
      final result = await sendPath(
        file.path,
        '127.0.0.1',
        server.port,
        sender,
        TrustStore(sender.directory),
        expectedFingerprint: receiver.fingerprint,
        compression: true,
      );
      expect(result.networkBytes, 140000);
      expect(
        await File('${root.path}/random-out/random.bin').readAsBytes(),
        await file.readAsBytes(),
      );
    } finally {
      await server.close();
    }
  });
}
