import 'dart:typed_data';
import 'dart:math';
import 'package:nshare/src/protocol/protocol.dart';
import 'package:nshare/core.dart';
import 'package:test/test.dart';

void main() {
  test('fixed header and fragmented/coalesced decoding', () {
    final bytes = encodeFrame(WireType.ready, Uint8List.fromList([123, 125]));
    expect(bytes.take(10), [78, 83, 72, 50, 2, 4, 0, 0, 0, 2]);
    final decoder = FrameDecoder();
    expect(decoder.add(bytes.sublist(0, 8)), isEmpty);
    expect(decoder.add([...bytes.sublist(8), ...bytes]).length, 2);
    decoder.finish();
  });
  test('oversized header rejected before payload buffering', () {
    final bytes = encodeFrame(WireType.ready, Uint8List(0));
    ByteData.sublistView(bytes).setUint32(6, maxFrameBytes + 1);
    expect(() => FrameDecoder().add(bytes), throwsA(isA<NshareException>()));
  });
  test('truncation, version mismatch and invalid metadata fail', () {
    final decoder = FrameDecoder()..add([78]);
    expect(decoder.finish, throwsA(isA<NshareException>()));
    final bytes = encodeFrame(WireType.ready, Uint8List(0))..[4] = 1;
    expect(() => FrameDecoder().add(bytes), throwsA(isA<NshareException>()));
    expect(
      () => Frame(WireType.ready, Uint8List(0)).json,
      throwsA(isA<NshareException>()),
    );
  });
  test('decoding is independent of every possible single split boundary', () {
    final expected = Uint8List.fromList(List.generate(97, (i) => i));
    final encoded = encodeFrame(WireType.data, expected);
    for (var split = 0; split <= encoded.length; split++) {
      final decoder = FrameDecoder();
      final frames = [
        ...decoder.add(encoded.sublist(0, split)),
        ...decoder.add(encoded.sublist(split)),
      ];
      expect(frames, hasLength(1), reason: 'split $split');
      expect(frames.single.payload, expected);
      decoder.finish();
    }
  });
  test('random fragmentation preserves ordering across many mixed frames', () {
    final frames = List.generate(
      40,
      (i) => encodeFrame(
        i.isEven ? WireType.data : WireType.ready,
        Uint8List.fromList(List.filled(i * 17, i)),
      ),
    );
    final stream = frames.expand((bytes) => bytes).toList();
    for (var seed = 0; seed < 20; seed++) {
      final random = Random(seed);
      final decoder = FrameDecoder();
      final decoded = <Frame>[];
      var offset = 0;
      while (offset < stream.length) {
        final end = min(stream.length, offset + 1 + random.nextInt(333));
        decoded.addAll(decoder.add(stream.sublist(offset, end)));
        offset = end;
      }
      expect(decoded, hasLength(frames.length));
      for (var i = 0; i < decoded.length; i++) {
        expect(decoded[i].type, i.isEven ? WireType.data : WireType.ready);
        expect(decoded[i].payload, List.filled(i * 17, i));
      }
      decoder.finish();
    }
  });
  test(
    'unknown message IDs fail without waiting for their declared payload',
    () {
      final header = encodeFrame(WireType.ready, Uint8List(0))..[5] = 255;
      ByteData.sublistView(header).setUint32(6, 1234, Endian.big);
      expect(() => FrameDecoder().add(header), throwsA(isA<NshareException>()));
    },
  );
  test(
    'exact payload limits work and oversize control and data frames fail',
    () {
      for (final type in [WireType.ready, WireType.data]) {
        final limit = type == WireType.data
            ? maxChunkBytes + 8
            : maxControlBytes;
        final encoded = encodeFrame(type, Uint8List(limit));
        expect(FrameDecoder().add(encoded).single.payload.length, limit);
        expect(
          () => encodeFrame(type, Uint8List(limit + 1)),
          throwsA(isA<NshareException>()),
        );
        final header = Uint8List.fromList(encoded.take(10).toList());
        ByteData.sublistView(header).setUint32(6, limit + 1, Endian.big);
        expect(
          () => FrameDecoder().add(header),
          throwsA(isA<NshareException>()),
        );
      }
    },
  );
}
