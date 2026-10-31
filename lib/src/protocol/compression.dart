import 'dart:io';
import 'dart:typed_data';
import '../core/models.dart';
import 'protocol.dart';

/// Independent blocks retain original byte offsets for verified resume.
Uint8List? compressBlock(int offset, List<int> bytes) {
  if (offset < 0 || bytes.isEmpty || bytes.length > maxChunkBytes) {
    throw const NshareException('protocol', 'Invalid compression block');
  }
  final compressed = gzip.encode(bytes);
  if (compressed.length + 4 >= bytes.length) return null;
  final payload = Uint8List(12 + compressed.length);
  final header = ByteData.sublistView(payload);
  header.setUint64(0, offset, Endian.big);
  header.setUint32(8, bytes.length, Endian.big);
  payload.setAll(12, compressed);
  return payload;
}

Uint8List decompressBlock(Uint8List payload) {
  if (payload.length <= 12 || payload.length > maxChunkBytes + 12) {
    throw const NshareException('protocol', 'Invalid compressed block length');
  }
  final length = ByteData.sublistView(payload).getUint32(8, Endian.big);
  if (length == 0 || length > maxChunkBytes) {
    throw const NshareException('protocol', 'Invalid decompressed length');
  }
  final output = _BoundedBytes(length);
  try {
    final decoder = gzip.decoder.startChunkedConversion(output);
    decoder.add(Uint8List.sublistView(payload, 12));
    decoder.close();
  } on NshareException {
    rethrow;
  } catch (_) {
    throw const NshareException('integrity', 'Invalid gzip block');
  }
  if (output.bytes.length != length) {
    throw const NshareException('integrity', 'Decompressed length mismatch');
  }
  return output.bytes.takeBytes();
}

class _BoundedBytes implements Sink<List<int>> {
  _BoundedBytes(this.limit);
  final int limit;
  final bytes = BytesBuilder(copy: false);
  @override
  void add(List<int> data) {
    if (bytes.length + data.length > limit) {
      throw const NshareException(
        'limit',
        'Decompression exceeds declared length',
      );
    }
    bytes.add(data);
  }

  @override
  void close() {}
}
