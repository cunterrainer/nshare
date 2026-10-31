import 'dart:typed_data';
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
}
