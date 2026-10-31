import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:nshare/src/protocol/protocol.dart';
import 'package:nshare/src/protocol/compression.dart';
import 'package:nshare/nshare.dart';
import 'package:test/test.dart';

void main() {
  test(
    'missing extensions preserve v2 behavior',
    () => expect(parseExtensions(null), isEmpty),
  );
  test(
    'unknown extensions are ignored',
    () => expect(parseExtensions(['future-v9']), isEmpty),
  );
  for (final capability in supportedExtensions) {
    test(
      'negotiates $capability',
      () => expect(parseExtensions([capability, 'unknown']), {capability}),
    );
  }
  for (final bad in [
    true,
    3,
    'gzip',
    {},
    [''],
    [null],
    [3],
    ['a', 'a'],
    List.filled(17, 'a'),
    ['x' * 65],
  ]) {
    test(
      'rejects malformed capabilities $bad',
      () => expect(() => parseExtensions(bad), throwsA(isA<NshareException>())),
    );
  }
  for (final type in WireType.values.where((t) => t.id >= 30)) {
    test('${type.name} explicit id round trip', () {
      final bytes = encodeFrame(type, Uint8List.fromList([1, 2, 3]));
      expect(bytes[5], type.id);
      final frame = FrameDecoder().add(bytes).single;
      expect(frame.type, type);
      expect(frame.payload, [1, 2, 3]);
    });
    test(
      '${type.name} rejects excessive advertised payload before allocation',
      () {
        final bytes = encodeFrame(type, Uint8List(0));
        ByteData.sublistView(
          bytes,
        ).setUint32(6, frameLimit(type) + 1, Endian.big);
        expect(
          () => FrameDecoder().add(bytes),
          throwsA(isA<NshareException>()),
        );
      },
    );
  }
  for (final size in [
    1,
    2,
    8,
    16,
    31,
    64,
    127,
    256,
    1024,
    4096,
    32768,
    65535,
    65536,
  ]) {
    for (final compressible in [false, true]) {
      test(
        'compression size $size compressible $compressible preserves original bytes',
        () {
          final random = Random(size);
          final data = List.generate(
            size,
            (_) => compressible ? 65 : random.nextInt(256),
          );
          final block = compressBlock(65536, data);
          if (block != null) {
            expect(block.length - 12, lessThan(data.length));
            expect(ByteData.sublistView(block).getUint64(0, Endian.big), 65536);
            expect(decompressBlock(block), data);
          } else {
            expect(
              gzip.encode(data).length + 4,
              greaterThanOrEqualTo(data.length),
            );
          }
        },
      );
    }
  }
  for (final size in [0, 1, 4, 8, 12, 65549]) {
    test(
      'reject malformed compressed payload size $size',
      () => expect(
        () => decompressBlock(Uint8List(size)),
        throwsA(isA<NshareException>()),
      ),
    );
  }
  for (final declared in [0, 1, 65537, 0xffffffff]) {
    test('decompression enforces declared size $declared', () {
      final payload = compressBlock(0, List.filled(65536, 65))!;
      ByteData.sublistView(payload).setUint32(8, declared, Endian.big);
      expect(() => decompressBlock(payload), throwsA(isA<NshareException>()));
    });
  }
  test('corrupt compressed bytes fail integrity', () {
    final payload = compressBlock(0, List.filled(4096, 65))!;
    payload[payload.length - 1] ^= 255;
    expect(() => decompressBlock(payload), throwsA(isA<NshareException>()));
  });
  for (final size in [0, 65537]) {
    test(
      'compress rejects source size $size',
      () => expect(
        () => compressBlock(0, List.filled(size, 65)),
        throwsA(isA<NshareException>()),
      ),
    );
  }
}
