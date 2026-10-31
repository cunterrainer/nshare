import 'dart:async';
import 'dart:io';
import 'package:nshare/core.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late DeviceIdentity sender, receiverIdentity;
  setUpAll(() async {
    temp = await Directory.systemTemp.createTemp('nshare_transfer_');
    sender = await DeviceIdentity.load(Directory('${temp.path}/sender'));
    receiverIdentity = await DeviceIdentity.load(
      Directory('${temp.path}/receiver'),
    );
  });
  tearDownAll(() => temp.delete(recursive: true));

  test(
    'real TLS transfer preserves nested files, empty entries and Unicode',
    () async {
      final source = Directory('${temp.path}/source');
      await Directory('${source.path}/empty').create(recursive: true);
      await File('${source.path}/empty.txt').writeAsString('');
      final data = List.generate(180000, (i) => i % 251);
      await File('${source.path}/文件.bin').writeAsBytes(data);
      final outcome = Completer<TransferResult>();
      final server = await TransferReceiver.start(
        identity: receiverIdentity,
        trust: TrustStore(receiverIdentity.directory),
        output: Directory('${temp.path}/out'),
        approveOffer: (_) async => true,
        expectedFingerprint: sender.fingerprint,
        bind: InternetAddress.loopbackIPv4,
        port: 0,
        discover: false,
        onResult: outcome.complete,
        onError: outcome.completeError,
      );
      try {
        final result = await sendPath(
          source.path,
          '127.0.0.1',
          server.port,
          sender,
          TrustStore(sender.directory),
          expectedFingerprint: receiverIdentity.fingerprint,
        );
        expect(result.files, 2);
        expect((await outcome.future).files, 2);
        expect(
          await File('${temp.path}/out/source/文件.bin').readAsBytes(),
          data,
        );
        expect(
          await Directory('${temp.path}/out/source/empty').exists(),
          isTrue,
        );
        expect(await File('${temp.path}/out/source/empty.txt').length(), 0);
      } finally {
        await server.close();
      }
    },
  );
  test(
    'refused offer never writes destination and sender does not claim success',
    () async {
      final source = File('${temp.path}/refused.txt')
        ..writeAsStringSync('refused');
      final errors = <Object>[];
      final server = await TransferReceiver.start(
        identity: receiverIdentity,
        trust: TrustStore(receiverIdentity.directory),
        output: Directory('${temp.path}/refused-out'),
        approveOffer: (_) async => false,
        expectedFingerprint: sender.fingerprint,
        bind: InternetAddress.loopbackIPv4,
        port: 0,
        discover: false,
        onError: errors.add,
      );
      try {
        await expectLater(
          sendPath(
            source.path,
            '127.0.0.1',
            server.port,
            sender,
            TrustStore(sender.directory),
            expectedFingerprint: receiverIdentity.fingerprint,
          ),
          throwsA(isA<NshareException>()),
        );
        expect(await Directory('${temp.path}/refused-out').exists(), isFalse);
      } finally {
        await server.close();
      }
      expect(errors, isNotEmpty);
    },
  );
}
