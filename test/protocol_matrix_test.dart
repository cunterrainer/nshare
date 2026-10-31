import 'dart:convert';
import 'dart:typed_data';
import 'package:nshare/nshare.dart';
import 'package:nshare/src/protocol/protocol.dart';
import 'package:test/test.dart';

void main() {
  final contract = <WireType, int>{
    WireType.hello: 1,
    WireType.challenge: 2,
    WireType.proof: 3,
    WireType.ready: 4,
    WireType.offer: 10,
    WireType.accept: 11,
    WireType.fileStart: 12,
    WireType.fileAccept: 13,
    WireType.data: 14,
    WireType.fileEnd: 15,
    WireType.fileAck: 16,
    WireType.complete: 17,
    WireType.completeAck: 18,
    WireType.cancel: 20,
    WireType.error: 21,
  };
  for (final entry in contract.entries) {
    test('wire contract ${entry.key.name} uses fixed ID ${entry.value}', () {
      final payload = Uint8List.fromList([123, 125]);
      final encoded = encodeFrame(entry.key, payload);
      expect(encoded, [78, 83, 72, 50, 2, entry.value, 0, 0, 0, 2, 123, 125]);
      final decoder = FrameDecoder();
      final frames = [
        ...decoder.add(encoded.sublist(0, 9)),
        ...decoder.add(encoded.sublist(9)),
      ];
      expect(frames.single.type, entry.key);
      expect(frames.single.payload, payload);
      decoder.finish();
    });
  }
  final invalidJson = <String, List<int>>{
    'empty': [],
    'malformed UTF8': [255],
    'null': utf8.encode('null'),
    'array': utf8.encode('[]'),
    'string': utf8.encode('"object"'),
    'integer': utf8.encode('1'),
    'boolean true': utf8.encode('true'),
    'boolean false': utf8.encode('false'),
    'unterminated': utf8.encode('{"a":'),
    'NaN': utf8.encode('{"a":NaN}'),
    'trailing data': utf8.encode('{}x'),
    'invalid key': utf8.encode('{1:2}'),
  };
  for (final entry in invalidJson.entries) {
    test(
      'control metadata rejects ${entry.key}',
      () => expect(
        () => Frame(WireType.offer, Uint8List.fromList(entry.value)).json,
        throwsA(
          isA<NshareException>().having((e) => e.code, 'code', 'protocol'),
        ),
      ),
    );
  }
  final badStrings = <String, dynamic>{
    'missing': null,
    'number': 1,
    'boolean': false,
    'empty': '',
    'over limit': 'abcdef',
    'list': ['a'],
  };
  for (final entry in badStrings.entries) {
    test(
      'required string rejects ${entry.key}',
      () => expect(
        () => requiredString({'field': entry.value}, 'field', max: 5),
        throwsA(isA<NshareException>()),
      ),
    );
  }
  for (final value in ['abcde', '文件', 'hello']) {
    test(
      'required string preserves valid $value',
      () => expect(requiredString({'field': value}, 'field', max: 5), value),
    );
  }
  final badInts = <String, dynamic>{
    'missing': null,
    'fraction': 1.5,
    'string': '1',
    'boolean': true,
    'negative': -1,
    'above limit': 11,
  };
  for (final entry in badInts.entries) {
    test(
      'required integer rejects ${entry.key}',
      () => expect(
        () => requiredInt({'field': entry.value}, 'field', max: 10),
        throwsA(isA<NshareException>()),
      ),
    );
  }
  for (final value in [0, 1, 10]) {
    test(
      'required integer accepts boundary/interior $value',
      () => expect(requiredInt({'field': value}, 'field', max: 10), value),
    );
  }
  for (var index = 0; index < 4; index++) {
    test('decoder rejects corrupted magic byte $index', () {
      final bytes = encodeFrame(WireType.ready, Uint8List(0))..[index] = 0;
      expect(
        () => FrameDecoder().add(bytes),
        throwsA(
          isA<NshareException>().having((e) => e.code, 'code', 'version'),
        ),
      );
    });
  }
  for (final version in [0, 1, 3, 255]) {
    test('decoder rejects unsupported version $version', () {
      final bytes = encodeFrame(WireType.ready, Uint8List(0))..[4] = version;
      expect(
        () => FrameDecoder().add(bytes),
        throwsA(
          isA<NshareException>().having((e) => e.code, 'code', 'version'),
        ),
      );
    });
  }
  for (final id in [0, 5, 9, 19, 255]) {
    test('decoder rejects undefined message ID $id', () {
      final bytes = encodeFrame(WireType.ready, Uint8List(0))..[5] = id;
      expect(
        () => FrameDecoder().add(bytes),
        throwsA(
          isA<NshareException>().having((e) => e.code, 'code', 'protocol'),
        ),
      );
    });
  }
  for (final type in [WireType.data, WireType.offer]) {
    test(
      'decoder rejects uint32 maximum length for ${type.name} immediately',
      () {
        final bytes = encodeFrame(type, Uint8List(0));
        ByteData.sublistView(bytes).setUint32(6, 0xffffffff, Endian.big);
        expect(
          () => FrameDecoder().add(bytes),
          throwsA(isA<NshareException>()),
        );
      },
    );
  }
}
