import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:nshare/nshare.dart';
import 'package:nshare/src/identity/identity.dart';
import 'package:nshare/src/protocol/protocol.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late DeviceIdentity client, server;
  var sequence = 0;
  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('matching_code_');
    client = await DeviceIdentity.load(Directory('${root.path}/client'));
    server = await DeviceIdentity.load(Directory('${root.path}/server'));
  });
  tearDownAll(() => root.delete(recursive: true));
  Future<TrustStore> fresh(String name) async =>
      TrustStore(await Directory('${root.path}/$name-${sequence++}').create());

  test(
    'matching codes pair both devices and enable an actual trusted transfer',
    () async {
      final clientTrust = await fresh('out'), serverTrust = await fresh('in');
      final codes = <String>[];
      final receiver = await TransferReceiver.start(
        output: Directory('${root.path}/received'),
        identity: server,
        trust: serverTrust,
        port: 0,
        discover: false,
        approvePeer: (peer) async {
          codes.add(peer.confirmationCode!);
          return true;
        },
        approveOffer: (_) async => true,
      );
      try {
        final peer = await pairByCode(
          '127.0.0.1',
          receiver.port,
          client,
          clientTrust,
          approvePeer: (peer) async {
            codes.add(peer.confirmationCode!);
            return true;
          },
        );
        expect(peer.fingerprint, server.fingerprint);
        expect(codes, hasLength(2));
        expect(codes.first, codes.last);
        expect(codes.first, matches(RegExp(r'^\d{4} \d{4} \d{5}$')));
        expect(await clientTrust.list(), contains(server.fingerprint));
        expect(await serverTrust.list(), contains(client.fingerprint));
        final source = await File(
          '${root.path}/paired.txt',
        ).writeAsString('paired file payload');
        final result = await sendPath(
          source.path,
          '127.0.0.1',
          receiver.port,
          client,
          clientTrust,
        );
        expect(result.files, 1);
        expect(
          await File('${root.path}/received/paired.txt').readAsString(),
          'paired file payload',
        );
      } finally {
        await receiver.close();
      }
    },
  );

  for (final rejectClient in [false, true]) {
    test(
      '${rejectClient ? 'client' : 'receiver'} decline leaves both trust stores unchanged',
      () async {
        final a = await fresh('decline-a'), b = await fresh('decline-b');
        final receiver = await TransferReceiver.start(
          output: Directory('${root.path}/decline'),
          identity: server,
          trust: b,
          approveOffer: (_) async => false,
          port: 0,
          discover: false,
          approvePeer: (_) async => rejectClient,
        );
        try {
          await expectLater(
            pairByCode(
              '127.0.0.1',
              receiver.port,
              client,
              a,
              approvePeer: (_) async => !rejectClient,
            ),
            throwsA(isA<NshareException>()),
          );
          await receiver.close();
          expect(await a.list(), isEmpty);
          expect(await b.list(), isEmpty);
        } finally {
          await receiver.close();
        }
      },
    );
  }

  test(
    'every session has a fresh matching code, including already trusted devices',
    () async {
      final a = await fresh('repeat-a'), b = await fresh('repeat-b');
      final codes = <String>[];
      var receiverApprovals = 0;
      final receiver = await TransferReceiver.start(
        output: Directory('${root.path}/repeat'),
        identity: server,
        trust: b,
        approveOffer: (_) async => false,
        port: 0,
        discover: false,
        approvePeer: (_) async {
          receiverApprovals++;
          return true;
        },
      );
      try {
        for (var i = 0; i < 3; i++) {
          await pairByCode(
            '127.0.0.1',
            receiver.port,
            client,
            a,
            approvePeer: (peer) async {
              codes.add(peer.confirmationCode!);
              return true;
            },
          );
        }
        expect(codes.toSet(), hasLength(3));
        expect(receiverApprovals, 3);
      } finally {
        await receiver.close();
      }
    },
  );

  test(
    'noninteractive receiver cannot automatically accept a code pairing',
    () async {
      final a = await fresh('auto-a'), b = await fresh('auto-b');
      final receiver = await TransferReceiver.start(
        output: Directory('${root.path}/auto'),
        identity: server,
        trust: b,
        approveOffer: (_) async => false,
        expectedFingerprint: client.fingerprint,
        port: 0,
        discover: false,
      );
      try {
        await expectLater(
          pairByCode(
            '127.0.0.1',
            receiver.port,
            client,
            a,
            approvePeer: (_) async => true,
          ),
          throwsA(isA<NshareException>()),
        );
        expect(await a.list(), isEmpty);
        expect(await b.list(), isEmpty);
      } finally {
        await receiver.close();
      }
    },
  );

  test('cancelling a pending code approval does not save trust', () async {
    final a = await fresh('cancel-a'), b = await fresh('cancel-b');
    final token = CancellationToken();
    final receiver = await TransferReceiver.start(
      output: Directory('${root.path}/cancel'),
      identity: server,
      trust: b,
      approveOffer: (_) async => false,
      port: 0,
      discover: false,
      approvePeer: (_) async => true,
    );
    try {
      await expectLater(
        pairByCode(
          '127.0.0.1',
          receiver.port,
          client,
          a,
          cancellation: token,
          approvePeer: (_) {
            token.cancel();
            return Completer<bool>().future;
          },
        ),
        throwsA(isA<NshareException>()),
      );
      await receiver.close();
      expect(await a.list(), isEmpty);
      expect(await b.list(), isEmpty);
    } finally {
      await receiver.close();
    }
  });

  // Exercise the receiver with deliberately modified wire messages.
  for (final attack in [
    'bad commitment',
    'changed secret',
    'wrong signature',
    'replayed proof',
    'missing mutual confirmation',
  ]) {
    test('code handshake rejects $attack before storing trust', () async {
      final trust = await fresh('attack');
      final listener = await SecureServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
        server.serverContext,
      );
      final incoming = listener.first.then((socket) async {
        final wire = WireConnection(socket);
        try {
          await expectLater(
            authenticateIncoming(
              wire,
              server,
              trust,
              approve: (_) async => true,
            ),
            throwsA(isA<NshareException>()),
          );
        } finally {
          await wire.close();
        }
      });
      final wire = WireConnection(
        await SecureSocket.connect(
          '127.0.0.1',
          listener.port,
          context: SecurityContext(withTrustedRoots: false),
          onBadCertificate: (_) => true,
        ),
      );
      try {
        final nonce = randomNonce(), secret = randomNonce();
        final commit = sha256
            .convert(
              utf8.encode(
                jsonEncode([
                  'nshare-confirmation-commit-v1',
                  client.fingerprint,
                  server.fingerprint,
                  nonce,
                  secret,
                ]),
              ),
            )
            .toString();
        await wire.send(WireType.hello, {
          'name': client.name,
          'certificate': client.certificate,
          'nonce': nonce,
          'extensions': supportedExtensions.toList(),
          'codeCommit': attack == 'bad commitment' ? 'invalid' : commit,
        });
        if (attack != 'bad commitment') {
          final challenge = await wire.expect(WireType.challenge);
          final transcript = utf8.encode(
            jsonEncode([
              'nshare-confirmation-code-v1',
              client.fingerprint,
              server.fingerprint,
              nonce,
              attack == 'replayed proof' ? randomNonce() : challenge['nonce'],
              secret,
            ]),
          );
          await wire.send(WireType.proof, {
            'codeSecret': attack == 'changed secret' ? randomNonce() : secret,
            'signature': base64.encode(
              attack == 'wrong signature'
                  ? server.sign(transcript)
                  : client.sign(transcript),
            ),
          });
          if (attack == 'missing mutual confirmation') {
            await wire.expect(WireType.ready);
            await wire.send(WireType.authConfirm, {'approved': false});
          }
        }
        await incoming;
        expect(await trust.list(), isEmpty);
      } finally {
        await wire.close();
        await listener.close();
      }
    });
  }

  test(
    'code pairing refuses a legacy peer rather than silently downgrading',
    () async {
      final trust = await fresh('legacy');
      final listener = await SecureServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
        server.serverContext,
      );
      final incoming = listener.first.then((socket) async {
        final wire = WireConnection(socket);
        try {
          await wire.expect(WireType.hello);
          await wire.send(WireType.challenge, {'nonce': randomNonce()});
        } finally {
          await wire.close();
        }
      });
      try {
        await expectLater(
          pairByCode(
            '127.0.0.1',
            listener.port,
            client,
            trust,
            approvePeer: (_) async => fail('Downgraded code approval'),
          ),
          throwsA(
            isA<NshareException>().having((e) => e.code, 'code', 'unsupported'),
          ),
        );
        await incoming;
        expect(await trust.list(), isEmpty);
      } finally {
        await listener.close();
      }
    },
  );
}
