import 'dart:io';
import 'dart:typed_data';
import 'package:nshare/src/identity/identity.dart';
import 'package:nshare/src/protocol/protocol.dart';
import 'package:nshare/core.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late DeviceIdentity sender, receiver;
  setUpAll(() async {
    temp = await Directory.systemTemp.createTemp('nshare_identity_');
    sender = await DeviceIdentity.load(Directory('${temp.path}/sender'));
    receiver = await DeviceIdentity.load(Directory('${temp.path}/receiver'));
  });
  tearDownAll(() => temp.delete(recursive: true));
  test(
    'identity persists and signatures cannot be replayed for another challenge',
    () async {
      expect(
        (await DeviceIdentity.load(sender.directory)).fingerprint,
        sender.fingerprint,
      );
      final signature = sender.sign([1, 2, 3]);
      expect(verifyProof(sender.certificate, [1, 2, 3], signature), isTrue);
      expect(verifyProof(sender.certificate, [1, 2, 4], signature), isFalse);
      expect(verifyProof(receiver.certificate, [1, 2, 3], signature), isFalse);
    },
  );
  test(
    'real TLS connection verifies both identities before application data',
    () async {
      final server = await SecureServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
        receiver.serverContext,
      );
      final incoming = server.first.then((socket) async {
        final wire = WireConnection(socket);
        try {
          final peer = await authenticateIncoming(
            wire,
            receiver,
            TrustStore(receiver.directory),
            expectedFingerprint: sender.fingerprint,
          );
          expect(peer.fingerprint, sender.fingerprint);
          expect((await wire.read()).payload, [42]);
        } finally {
          await wire.close();
        }
      });
      final wire = await connectAuthenticated(
        '127.0.0.1',
        server.port,
        sender,
        TrustStore(sender.directory),
        expectedFingerprint: receiver.fingerprint,
      );
      await wire.sendBytes(WireType.data, Uint8List.fromList([42]));
      await incoming;
      await wire.close();
      await server.close();
    },
  );
  test(
    'trust rejects changed endpoint identity and can be forgotten',
    () async {
      final trust = TrustStore(sender.directory);
      await trust.approve(
        receiver.peer,
        null,
        expectedFingerprint: receiver.fingerprint,
        endpoint: 'test:1',
      );
      await expectLater(
        trust.approve(sender.peer, (_) async => true, endpoint: 'test:1'),
        throwsA(isA<NshareException>()),
      );
      await trust.forget(receiver.fingerprint);
      expect((await trust.list()).containsKey(receiver.fingerprint), isFalse);
    },
  );
}
