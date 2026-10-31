import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:nshare/nshare.dart';
import 'package:nshare/src/identity/identity.dart';
import 'package:nshare/src/protocol/protocol.dart';
import 'package:nshare/src/storage/storage.dart';
import 'package:test/test.dart';

Uint8List dataAt(int offset, List<int> bytes) {
  final payload = Uint8List(8 + bytes.length);
  ByteData.sublistView(payload).setUint64(0, offset, Endian.big);
  payload.setRange(8, payload.length, bytes);
  return payload;
}

void main() {
  late Directory temp;
  late DeviceIdentity sender, receiver;
  setUpAll(() async {
    temp = await Directory.systemTemp.createTemp('nshare_receiver_validation_');
    sender = await DeviceIdentity.load(Directory('${temp.path}/sender'));
    receiver = await DeviceIdentity.load(Directory('${temp.path}/receiver'));
  });
  tearDownAll(() => temp.delete(recursive: true));

  Future<void> rejectTransfer(
    String name,
    String expectedCode,
    Future<void> Function(WireConnection, Map<String, dynamic>) attack,
  ) async {
    final source = File('${temp.path}/$name.bin')
      ..writeAsBytesSync([1, 2, 3, 4]);
    final manifest = await Manifest.collect(source.path);
    final entry = manifest.entries.single;
    final output = Directory('${temp.path}/out-$name');
    final failure = Completer<Object>();
    var completed = false;
    final server = await TransferReceiver.start(
      identity: receiver,
      trust: TrustStore(receiver.directory),
      output: output,
      expectedFingerprint: sender.fingerprint,
      approveOffer: (_) async => true,
      bind: InternetAddress.loopbackIPv4,
      port: 0,
      discover: false,
      onResult: (_) => completed = true,
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
      await wire.send(WireType.offer, manifest.toJson());
      await wire.expect(WireType.accept);
      final metadata = {
        'transfer': manifest.id,
        'entry': entry.id,
        'sha256': entry.hash,
      };
      await wire.send(WireType.fileStart, {...metadata, 'resume': false});
      await wire.expect(WireType.fileAccept);
      await attack(wire, metadata);
      await expectLater(
        wire.read(),
        throwsA(isA<NshareException>().having((e) => e.code, 'code', 'remote')),
      );
      expect(
        await failure.future.timeout(const Duration(seconds: 5)),
        isA<NshareException>().having(
          (e) => e.code,
          'receiver code',
          expectedCode,
        ),
      );
      expect(completed, isFalse);
      expect(await File('${output.path}/$name.bin').exists(), isFalse);
    } finally {
      await wire.close();
      await server.close();
    }
  }

  test(
    'receiver rejects a noncontiguous first data offset',
    () => rejectTransfer(
      'offset',
      'protocol',
      (wire, _) => wire.sendBytes(WireType.data, dataAt(1, [1, 2, 3, 4])),
    ),
  );
  test(
    'receiver rejects more bytes than the declared file size',
    () => rejectTransfer(
      'excess',
      'protocol',
      (wire, _) => wire.sendBytes(WireType.data, dataAt(0, [1, 2, 3, 4, 5])),
    ),
  );
  test(
    'receiver rejects file-end before all offered bytes arrive',
    () => rejectTransfer(
      'early-end',
      'protocol',
      (wire, metadata) => wire.send(WireType.fileEnd, metadata),
    ),
  );
  test(
    'receiver rejects data whose digest differs despite matching length',
    () => rejectTransfer('corrupt', 'integrity', (wire, metadata) async {
      await wire.sendBytes(WireType.data, dataAt(0, [4, 3, 2, 1]));
      await wire.send(WireType.fileEnd, metadata);
    }),
  );
  test(
    'receiver rejects file-end naming a different transfer',
    () => rejectTransfer('wrong-transfer', 'protocol', (wire, metadata) async {
      await wire.sendBytes(WireType.data, dataAt(0, [1, 2, 3, 4]));
      await wire.send(WireType.fileEnd, {
        ...metadata,
        'transfer': 'another-transfer',
      });
    }),
  );
  test(
    'receiver rejects a second data frame instead of file-end',
    () => rejectTransfer('extra-frame', 'protocol', (wire, _) async {
      await wire.sendBytes(WireType.data, dataAt(0, [1, 2, 3, 4]));
      await wire.sendBytes(WireType.data, dataAt(4, [5]));
    }),
  );
}
