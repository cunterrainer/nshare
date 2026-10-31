import 'dart:async';
import 'dart:io';
import 'package:nshare/core.dart';
import 'package:nshare/src/storage/storage.dart';
import 'package:nshare/src/protocol/protocol.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late DeviceIdentity sender, receiver;
  setUpAll(() async {
    temp = await Directory.systemTemp.createTemp('nshare_resume_');
    sender = await DeviceIdentity.load(Directory('${temp.path}/sender'));
    receiver = await DeviceIdentity.load(Directory('${temp.path}/receiver'));
  });
  tearDownAll(() => temp.delete(recursive: true));
  test(
    'verified partial survives restart and completed files retry idempotently',
    () async {
      final source = File('${temp.path}/resume.bin');
      final data = List.generate(maxChunkBytes * 3 + 12, (i) => i % 251);
      await source.writeAsBytes(data);
      final manifest = await Manifest.collect(source.path);
      final output = Directory('${temp.path}/out');
      final store = await DestinationStore.open(
        output,
        manifest,
        sender.fingerprint,
        ConflictPolicy.refuse,
      );
      // Includes an incomplete last chunk, which must be discarded on reconnect.
      await store
          .partial(manifest.entries.single)
          .writeAsBytes(data.sublist(0, maxChunkBytes + 5));
      Future<TransferResult> attempt() async {
        final done = Completer<TransferResult>();
        final server = await TransferReceiver.start(
          identity: receiver,
          trust: TrustStore(receiver.directory),
          output: output,
          approveOffer: (_) async => true,
          expectedFingerprint: sender.fingerprint,
          bind: InternetAddress.loopbackIPv4,
          port: 0,
          discover: false,
          onResult: done.complete,
          onError: done.completeError,
        );
        try {
          final result = await sendPath(
            source.path,
            '127.0.0.1',
            server.port,
            sender,
            TrustStore(sender.directory),
            expectedFingerprint: receiver.fingerprint,
          );
          await done.future;
          return result;
        } finally {
          await server.close();
        }
      }

      expect((await attempt()).bytes, data.length - maxChunkBytes);
      expect(await File('${output.path}/resume.bin').readAsBytes(), data);
      // A fresh receiver revalidates the finalized file; no DATA needs resending.
      expect((await attempt()).bytes, 0);
    },
  );
  test(
    'corrupt retained prefix fails and explicit restart discards it',
    () async {
      final source = File('${temp.path}/corrupt.bin');
      await source.writeAsBytes(List.filled(maxChunkBytes * 2, 42));
      final manifest = await Manifest.collect(source.path);
      final output = Directory('${temp.path}/corrupt-out');
      final store = await DestinationStore.open(
        output,
        manifest,
        sender.fingerprint,
        ConflictPolicy.refuse,
      );
      await store
          .partial(manifest.entries.single)
          .writeAsBytes(List.filled(maxChunkBytes, 1));
      final errors = <Object>[];
      var server = await TransferReceiver.start(
        identity: receiver,
        trust: TrustStore(receiver.directory),
        output: output,
        approveOffer: (_) async => true,
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
            expectedFingerprint: receiver.fingerprint,
          ),
          throwsA(
            isA<NshareException>().having((e) => e.code, 'code', 'resume'),
          ),
        );
      } finally {
        await server.close();
      }
      server = await TransferReceiver.start(
        identity: receiver,
        trust: TrustStore(receiver.directory),
        output: output,
        approveOffer: (_) async => true,
        expectedFingerprint: sender.fingerprint,
        bind: InternetAddress.loopbackIPv4,
        port: 0,
        discover: false,
        onError: errors.add,
      );
      try {
        expect(
          (await sendPath(
            source.path,
            '127.0.0.1',
            server.port,
            sender,
            TrustStore(sender.directory),
            expectedFingerprint: receiver.fingerprint,
            resume: false,
          )).bytes,
          maxChunkBytes * 2,
        );
      } finally {
        await server.close();
      }
    },
  );
}
