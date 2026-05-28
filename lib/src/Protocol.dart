import "dart:typed_data";
import "dart:convert";

const int kProtocolVersion = 1;

enum MessageType
{
  fileStart,
  fileChunk,
  fileEnd,
  transferComplete,
}

class ProtocolFrame
{
  ProtocolFrame(this.version, this.type, this.payload);

  final int version;
  final MessageType type;
  final Uint8List payload;
}

class FileStartMessage
{
  FileStartMessage({
    required this.relativePath,
    required this.size,
    required this.isDirectory,
  });

  final String relativePath;
  final int size;
  final bool isDirectory;
}

class Protocol
{
  static Uint8List encodeFrame(MessageType type, Uint8List payload)
  {
    final header = ByteData(6);
    header.setUint8(0, kProtocolVersion);
    header.setUint8(1, type.index);
    header.setUint32(2, payload.length, Endian.big);
    return Uint8List.fromList(header.buffer.asUint8List() + payload);
  }

  static Uint8List encodeFileStart(FileStartMessage msg)
  {
    final pathBytes = utf8.encode(msg.relativePath);
    final payload = ByteData(1 + 8 + 4 + pathBytes.length);
    payload.setUint8(0, msg.isDirectory ? 1 : 0);
    payload.setUint64(1, msg.size, Endian.big);
    payload.setUint32(9, pathBytes.length, Endian.big);
    final payloadBytes = payload.buffer.asUint8List();
    payloadBytes.setRange(13, 13 + pathBytes.length, pathBytes);
    return payloadBytes;
  }

  static FileStartMessage decodeFileStart(Uint8List payload)
  {
    final data = ByteData.sublistView(payload);
    final isDir = data.getUint8(0) == 1;
    final size = data.getUint64(1, Endian.big);
    final pathLength = data.getUint32(9, Endian.big);
    final pathStart = 13;
    final pathBytes = payload.sublist(pathStart, pathStart + pathLength);
    return FileStartMessage(
      relativePath: utf8.decode(pathBytes),
      size: size,
      isDirectory: isDir,
    );
  }

  static Uint8List encodeFileEnd(String md5Hex)
  {
    return Uint8List.fromList(ascii.encode(md5Hex));
  }

  static String decodeFileEnd(Uint8List payload)
  {
    return ascii.decode(payload);
  }
}

class FrameParser
{
  Uint8List _buffer = Uint8List(0);
  int _offset = 0;

  List<ProtocolFrame> add(Uint8List data)
  {
    _append(data);
    final frames = <ProtocolFrame>[];

    while (true)
    {
      if (_buffer.length - _offset < 6) break;
      final header = ByteData.sublistView(_buffer, _offset, _offset + 6);
      final version = header.getUint8(0);
      final typeId = header.getUint8(1);
      final length = header.getUint32(2, Endian.big);

      if (_buffer.length - _offset < 6 + length) break;
      if (typeId < 0 || typeId >= MessageType.values.length)
      {
        throw StateError("Unknown message type: $typeId");
      }

      final payloadStart = _offset + 6;
      final payloadEnd = payloadStart + length;
      final payload = Uint8List.sublistView(_buffer, payloadStart, payloadEnd);
      frames.add(ProtocolFrame(version, MessageType.values[typeId], payload));
      _offset = payloadEnd;
    }

    _compactBuffer();
    return frames;
  }

  void _append(Uint8List data)
  {
    if (_offset == 0 && _buffer.isEmpty)
    {
      _buffer = data;
      return;
    }

    final remaining = _buffer.length - _offset;
    final next = Uint8List(remaining + data.length);
    next.setRange(0, remaining, _buffer.sublist(_offset));
    next.setRange(remaining, remaining + data.length, data);
    _buffer = next;
    _offset = 0;
  }

  void _compactBuffer()
  {
    if (_offset == 0) return;
    if (_offset >= _buffer.length)
    {
      _buffer = Uint8List(0);
      _offset = 0;
      return;
    }

    final remaining = _buffer.length - _offset;
    final next = Uint8List(remaining);
    next.setRange(0, remaining, _buffer.sublist(_offset));
    _buffer = next;
    _offset = 0;
  }
}
