import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import '../core/models.dart';

const protocolVersion = 2;
const maxControlBytes = 256 * 1024;
const maxChunkBytes = 64 * 1024;
const maxFrameBytes = maxControlBytes;

/// IDs are part of the wire contract, never derived from enum indexes.
enum WireType {
  hello(1),
  challenge(2),
  proof(3),
  ready(4),
  offer(10),
  accept(11),
  fileStart(12),
  fileAccept(13),
  data(14),
  fileEnd(15),
  fileAck(16),
  complete(17),
  completeAck(18),
  cancel(20),
  error(21);

  const WireType(this.id);
  final int id;
}

class Frame {
  const Frame(this.type, this.payload);
  final WireType type;
  final Uint8List payload;
  Map<String, dynamic> get json {
    try {
      final value = jsonDecode(utf8.decode(payload));
      if (value is! Map<String, dynamic>) throw const FormatException();
      return value;
    } catch (_) {
      throw const NshareException('protocol', 'Invalid control metadata');
    }
  }
}

Uint8List encodeFrame(WireType type, Uint8List payload) {
  final limit = type == WireType.data ? maxChunkBytes + 8 : maxControlBytes;
  if (payload.length > limit) {
    throw const NshareException('protocol', 'Frame exceeds size limit');
  }
  final bytes = Uint8List(10 + payload.length);
  bytes.setRange(0, 4, [0x4e, 0x53, 0x48, 0x32]); // NSH2
  bytes[4] = protocolVersion;
  bytes[5] = type.id;
  ByteData.sublistView(bytes).setUint32(6, payload.length, Endian.big);
  bytes.setRange(10, bytes.length, payload);
  return bytes;
}

class FrameDecoder {
  Uint8List _pending = Uint8List(0);
  List<Frame> add(List<int> bytes) {
    final buffer = Uint8List(_pending.length + bytes.length)
      ..setAll(0, _pending)
      ..setAll(_pending.length, bytes);
    var offset = 0;
    final frames = <Frame>[];
    while (buffer.length - offset >= 10) {
      if (buffer[offset] != 0x4e ||
          buffer[offset + 1] != 0x53 ||
          buffer[offset + 2] != 0x48 ||
          buffer[offset + 3] != 0x32 ||
          buffer[offset + 4] != protocolVersion) {
        throw const NshareException(
          'version',
          'Expected nshare protocol v2; no legacy fallback',
        );
      }
      final types = WireType.values.where((t) => t.id == buffer[offset + 5]);
      if (types.isEmpty)
        throw const NshareException('protocol', 'Unknown message type');
      final type = types.single;
      final length = ByteData.sublistView(
        buffer,
      ).getUint32(offset + 6, Endian.big);
      final limit = type == WireType.data ? maxChunkBytes + 8 : maxControlBytes;
      if (length > limit)
        throw const NshareException('protocol', 'Frame exceeds size limit');
      if (buffer.length - offset < 10 + length) break;
      frames.add(
        Frame(
          type,
          Uint8List.fromList(buffer.sublist(offset + 10, offset + 10 + length)),
        ),
      );
      offset += 10 + length;
    }
    _pending = Uint8List.fromList(buffer.sublist(offset));
    return frames;
  }

  void finish() {
    if (_pending.isNotEmpty)
      throw const NshareException('protocol', 'Truncated frame');
  }
}

class WireConnection {
  WireConnection(
    this.socket, {
    this.timeout = const Duration(seconds: 60),
    CancellationToken? cancellation,
  }) {
    final decoder = FrameDecoder();
    _frames = StreamIterator(_decode(socket, decoder));
    cancellation?.whenCancelled.then((_) => socket.destroy());
    _cancellation = cancellation;
  }
  final Socket socket;
  final Duration timeout;
  late final StreamIterator<Frame> _frames;
  CancellationToken? _cancellation;

  static Stream<Frame> _decode(Socket socket, FrameDecoder decoder) async* {
    await for (final bytes in socket) {
      for (final frame in decoder.add(bytes)) {
        yield frame;
      }
    }
    decoder.finish();
  }

  Future<Frame> read({Duration? wait}) async {
    _cancellation?.check();
    bool available;
    try {
      available = await _frames.moveNext().timeout(wait ?? timeout);
    } on TimeoutException {
      throw const NshareException(
        'timeout',
        'Peer did not respond before the deadline',
      );
    }
    _cancellation?.check();
    if (!available)
      throw const NshareException(
        'disconnected',
        'Peer disconnected before acknowledgment',
      );
    final frame = _frames.current;
    if (frame.type == WireType.cancel)
      throw const NshareException('cancelled', 'Peer cancelled');
    if (frame.type == WireType.error) {
      final error = frame.json;
      throw NshareException('remote', '${error['code']}: ${error['message']}');
    }
    return frame;
  }

  Future<Map<String, dynamic>> expect(WireType type, {Duration? wait}) async {
    final frame = await read(wait: wait);
    if (frame.type != type)
      throw NshareException(
        'protocol',
        'Expected ${type.name}, received ${frame.type.name}',
      );
    return frame.json;
  }

  Future<void> send(WireType type, Map<String, dynamic> metadata) =>
      sendBytes(type, Uint8List.fromList(utf8.encode(jsonEncode(metadata))));
  Future<void> sendBytes(WireType type, Uint8List payload) async {
    _cancellation?.check();
    socket.add(encodeFrame(type, payload));
    await socket.flush().timeout(timeout);
  }

  Future<void> close() async {
    socket.destroy();
    await _frames.cancel();
  }
}

String requiredString(
  Map<String, dynamic> json,
  String field, {
  int max = 4096,
}) {
  final value = json[field];
  if (value is! String || value.isEmpty || value.length > max) {
    throw NshareException('protocol', 'Invalid $field');
  }
  return value;
}

int requiredInt(
  Map<String, dynamic> json,
  String field, {
  int max = 0x7fffffffffffffff,
}) {
  final value = json[field];
  if (value is! int || value < 0 || value > max)
    throw NshareException('protocol', 'Invalid $field');
  return value;
}
