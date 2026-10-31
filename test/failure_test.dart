import 'dart:async';
import 'dart:io';
import 'package:nshare/nshare.dart';
import 'package:nshare/src/identity/identity.dart';
import 'package:nshare/src/protocol/protocol.dart';
import 'package:nshare/src/storage/storage.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late DeviceIdentity sender, receiver;
  setUpAll(() async {
    temp = await Directory.systemTemp.createTemp('nshare_failures_');
    sender = await DeviceIdentity.load(Directory('${temp.path}/sender'));
    receiver = await DeviceIdentity.load(Directory('${temp.path}/receiver'));
  });
  tearDownAll(() => temp.delete(recursive: true));

  test('out-of-order messages fail before destination writes', () async {
    final failure = Completer<Object>();
    final output = Directory('${temp.path}/out-of-order');
    final server = await TransferReceiver.start(
      identity: receiver,
      trust: TrustStore(receiver.directory),
      output: output,
      approveOffer: (_) async => true,
      expectedFingerprint: sender.fingerprint,
      bind: InternetAddress.loopbackIPv4,
      port: 0,
      discover: false,
      onError: failure.complete,
    );
    final wire = await connectAuthenticated(
      '127.0.0.1',
      server.port,
      sender,
      TrustStore(sender.directory),
      expectedFingerprint: receiver.fingerprint,
    );
    try {
      await wire.send(WireType.fileStart, {});
      await expectLater(wire.read(), throwsA(isA<NshareException>()));
      expect(await failure.future, isA<NshareException>());
      expect(await output.exists(), isFalse);
    } finally {
      await wire.close();
      await server.close();
    }
  });

  test(
    'closing receiver cancels an unresolved UI approval without waiting five minutes',
    () async {
      final source = File('${temp.path}/approval.txt')
        ..writeAsStringSync('approval');
      final offerSeen = Completer<void>();
      final server = await TransferReceiver.start(
        identity: receiver,
        trust: TrustStore(receiver.directory),
        output: Directory('${temp.path}/approval-out'),
        expectedFingerprint: sender.fingerprint,
        approveOffer: (_) {
          offerSeen.complete();
          return Completer<bool>().future;
        },
        bind: InternetAddress.loopbackIPv4,
        port: 0,
        discover: false,
      );
      final wire = await connectAuthenticated(
        '127.0.0.1',
        server.port,
        sender,
        TrustStore(sender.directory),
        expectedFingerprint: receiver.fingerprint,
      );
      try {
        await wire.send(
          WireType.offer,
          (await Manifest.collect(source.path)).toJson(),
        );
        await offerSeen.future;
        await server.close().timeout(const Duration(seconds: 2));
      } finally {
        await wire.close();
      }
    },
  );

  test(
    'pending first-time pairing does not hold trust storage after shutdown',
    () async {
      final source = File('${temp.path}/pairing.txt')
        ..writeAsStringSync('pairing');
      final isolatedTrust = Directory('${temp.path}/fresh-trust')..createSync();
      final approvalSeen = Completer<void>();
      final server = await TransferReceiver.start(
        identity: receiver,
        trust: TrustStore(isolatedTrust),
        output: Directory('${temp.path}/pairing-out'),
        approvePeer: (_) {
          approvalSeen.complete();
          return Completer<bool>().future;
        },
        approveOffer: (_) async => true,
        bind: InternetAddress.loopbackIPv4,
        port: 0,
        discover: false,
      );
      final sending = sendPath(
        source.path,
        '127.0.0.1',
        server.port,
        sender,
        TrustStore(sender.directory),
        expectedFingerprint: receiver.fingerprint,
      );
      final failed = expectLater(sending, throwsA(isA<NshareException>()));
      await approvalSeen.future;
      await server.close().timeout(const Duration(seconds: 2));
      await failed;
      await TrustStore(
        isolatedTrust,
      ).forget(sender.fingerprint).timeout(const Duration(seconds: 2));
    },
  );
  test(
    'missing final acknowledgment is an uncertain failure even after file acknowledgments',
    () async {
      final source = File('${temp.path}/uncertain.txt')
        ..writeAsStringSync('uncertain');
      final server = await SecureServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
        receiver.serverContext,
      );
      final incoming = server.first.then((socket) async {
        final wire = WireConnection(socket);
        try {
          await authenticateIncoming(
            wire,
            receiver,
            TrustStore(receiver.directory),
            expectedFingerprint: sender.fingerprint,
          );
          final manifest = Manifest.parse(await wire.expect(WireType.offer));
          await wire.send(WireType.accept, {'transfer': manifest.id});
          final start = await wire.expect(WireType.fileStart);
          await wire.send(WireType.fileAccept, {
            ...start,
            'offset': 0,
            'prefixHash':
                'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
          });
          expect((await wire.read()).type, WireType.data);
          final end = await wire.expect(WireType.fileEnd);
          await wire.send(WireType.fileAck, end);
          await wire.expect(WireType.complete);
          // Deliberately lose COMPLETE_ACK.
        } finally {
          await wire.close();
        }
      });
      try {
        await expectLater(
          sendPath(
            source.path,
            '127.0.0.1',
            server.port,
            sender,
            TrustStore(sender.directory),
            expectedFingerprint: receiver.fingerprint,
          ),
          throwsA(
            isA<NshareException>().having((e) => e.code, 'code', 'uncertain'),
          ),
        );
        await incoming;
      } finally {
        await server.close();
      }
    },
  );

  test(
    'cancellation interrupts data streaming without finalizing partial files',
    () async {
      final source = File('${temp.path}/cancel.bin')
        ..writeAsBytesSync(List.filled(1024 * 1024, 42));
      final output = Directory('${temp.path}/cancel-out');
      final server = await TransferReceiver.start(
        identity: receiver,
        trust: TrustStore(receiver.directory),
        output: output,
        expectedFingerprint: sender.fingerprint,
        approveOffer: (_) async => true,
        bind: InternetAddress.loopbackIPv4,
        port: 0,
        discover: false,
      );
      final token = CancellationToken();
      try {
        await expectLater(
          sendPath(
            source.path,
            '127.0.0.1',
            server.port,
            sender,
            TrustStore(sender.directory),
            expectedFingerprint: receiver.fingerprint,
            cancellation: token,
            onProgress: (event) {
              if (event.phase == TransferPhase.transferring) token.cancel();
            },
          ),
          throwsA(
            isA<NshareException>().having((e) => e.code, 'code', 'cancelled'),
          ),
        );
        expect(await File('${output.path}/cancel.bin').exists(), isFalse);
      } finally {
        await server.close();
      }
    },
  );

  test('network inactivity has a bounded deadline', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final incoming = server.first;
    final client = await Socket.connect('127.0.0.1', server.port);
    final peer = await incoming;
    final wire = WireConnection(
      client,
      timeout: const Duration(milliseconds: 30),
    );
    try {
      await expectLater(
        wire.read(),
        throwsA(
          isA<NshareException>().having((e) => e.code, 'code', 'timeout'),
        ),
      );
    } finally {
      await wire.close();
      peer.destroy();
      await server.close();
    }
  });
}
