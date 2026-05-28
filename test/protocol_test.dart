import 'dart:typed_data';
import 'dart:convert';
import 'package:test/test.dart';
import 'package:nshare/nshare.dart';

void main() {
  group('Protocol - FileStartMessage', () {
    test('FileStartMessage constructor creates instance with correct fields', () {
      final msg = FileStartMessage(
        relativePath: 'test/file.txt',
        size: 1024,
        isDirectory: false,
      );
      expect(msg.relativePath, equals('test/file.txt'));
      expect(msg.size, equals(1024));
      expect(msg.isDirectory, isFalse);
    });

    test('FileStartMessage can be created for directory', () {
      final msg = FileStartMessage(
        relativePath: 'test/dir',
        size: 0,
        isDirectory: true,
      );
      expect(msg.isDirectory, isTrue);
    });
  });

  group('Protocol - MessageType', () {
    test('MessageType enum has all required values', () {
      expect(MessageType.values.length, equals(4));
      expect(MessageType.values, contains(MessageType.fileStart));
      expect(MessageType.values, contains(MessageType.fileChunk));
      expect(MessageType.values, contains(MessageType.fileEnd));
      expect(MessageType.values, contains(MessageType.transferComplete));
    });
  });

  group('Protocol - encodeFrame and ProtocolFrame', () {
    test('encodeFrame creates valid frame with header and payload', () {
      final payload = Uint8List.fromList([1, 2, 3, 4, 5]);
      final encoded = Protocol.encodeFrame(MessageType.fileChunk, payload);
      
      expect(encoded.length, equals(6 + 5)); // 6 byte header + 5 byte payload
      expect(encoded[0], equals(kProtocolVersion)); // Version
      expect(encoded[1], equals(MessageType.fileChunk.index)); // Type
    });

    test('encodeFrame with empty payload', () {
      final payload = Uint8List(0);
      final encoded = Protocol.encodeFrame(MessageType.transferComplete, payload);
      
      expect(encoded.length, equals(6)); // Just header
    });

    test('encodeFrame with large payload', () {
      final payload = Uint8List(10000);
      for (int i = 0; i < payload.length; i++) {
        payload[i] = (i % 256).toUnsigned(8);
      }
      final encoded = Protocol.encodeFrame(MessageType.fileChunk, payload);
      
      expect(encoded.length, equals(6 + 10000));
      // Verify payload is preserved
      for (int i = 0; i < payload.length; i++) {
        expect(encoded[6 + i], equals(payload[i]));
      }
    });

    test('ProtocolFrame stores version, type, and payload', () {
      final payload = Uint8List.fromList([10, 20, 30]);
      final frame = ProtocolFrame(1, MessageType.fileStart, payload);
      
      expect(frame.version, equals(1));
      expect(frame.type, equals(MessageType.fileStart));
      expect(frame.payload, equals(payload));
    });
  });

  group('Protocol - encodeFileStart and decodeFileStart', () {
    test('encodeFileStart creates correct byte sequence', () {
      final msg = FileStartMessage(
        relativePath: 'test.txt',
        size: 512,
        isDirectory: false,
      );
      final encoded = Protocol.encodeFileStart(msg);
      
      expect(encoded.length, greaterThan(13)); // At least 13 bytes + path
      expect(encoded[0], equals(0)); // Not a directory
    });

    test('encodeFileStart with directory flag', () {
      final msg = FileStartMessage(
        relativePath: 'testdir',
        size: 0,
        isDirectory: true,
      );
      final encoded = Protocol.encodeFileStart(msg);
      
      expect(encoded[0], equals(1)); // Is a directory
    });

    test('encodeFileStart and decodeFileStart round-trip for file', () {
      final original = FileStartMessage(
        relativePath: 'folder/myfile.bin',
        size: 8192,
        isDirectory: false,
      );
      
      final encoded = Protocol.encodeFileStart(original);
      final decoded = Protocol.decodeFileStart(encoded);
      
      expect(decoded.relativePath, equals(original.relativePath));
      expect(decoded.size, equals(original.size));
      expect(decoded.isDirectory, equals(original.isDirectory));
    });

    test('encodeFileStart and decodeFileStart round-trip for directory', () {
      final original = FileStartMessage(
        relativePath: 'nested/folder/structure',
        size: 0,
        isDirectory: true,
      );
      
      final encoded = Protocol.encodeFileStart(original);
      final decoded = Protocol.decodeFileStart(encoded);
      
      expect(decoded.relativePath, equals(original.relativePath));
      expect(decoded.size, equals(original.size));
      expect(decoded.isDirectory, equals(original.isDirectory));
    });

    test('decodeFileStart with unicode path', () {
      final original = FileStartMessage(
        relativePath: 'файл/文件.txt',
        size: 256,
        isDirectory: false,
      );
      
      final encoded = Protocol.encodeFileStart(original);
      final decoded = Protocol.decodeFileStart(encoded);
      
      expect(decoded.relativePath, equals(original.relativePath));
    });

    test('encodeFileStart and decodeFileStart with large file size', () {
      final original = FileStartMessage(
        relativePath: 'largefile.iso',
        size: 4294967296, // 4GB
        isDirectory: false,
      );
      
      final encoded = Protocol.encodeFileStart(original);
      final decoded = Protocol.decodeFileStart(encoded);
      
      expect(decoded.size, equals(original.size));
    });
  });

  group('Protocol - encodeFileEnd and decodeFileEnd', () {
    test('encodeFileEnd creates byte sequence from hex string', () {
      final hash = 'd41d8cd98f00b204e9800998ecf8427e';
      final encoded = Protocol.encodeFileEnd(hash);
      
      expect(encoded.length, equals(32)); // MD5 hex length
      expect(ascii.decode(encoded), equals(hash));
    });

    test('encodeFileEnd and decodeFileEnd round-trip', () {
      final original = 'e99a18c428cb38d5f260853678922e03';
      
      final encoded = Protocol.encodeFileEnd(original);
      final decoded = Protocol.decodeFileEnd(encoded);
      
      expect(decoded, equals(original));
    });

    test('decodeFileEnd handles empty hash', () {
      final encoded = Protocol.encodeFileEnd('');
      final decoded = Protocol.decodeFileEnd(encoded);
      
      expect(decoded, isEmpty);
    });
  });

  group('Protocol - FrameParser', () {
    test('FrameParser.add with single complete frame', () {
      final payload = Uint8List.fromList([1, 2, 3, 4, 5]);
      final frame = Protocol.encodeFrame(MessageType.fileChunk, payload);
      
      final parser = FrameParser();
      final frames = parser.add(frame);
      
      expect(frames.length, equals(1));
      expect(frames[0].type, equals(MessageType.fileChunk));
      expect(frames[0].payload, equals(payload));
    });

    test('FrameParser.add with multiple frames in one packet', () {
      final payload1 = Uint8List.fromList([1, 2, 3]);
      final payload2 = Uint8List.fromList([4, 5, 6]);
      
      final frame1 = Protocol.encodeFrame(MessageType.fileChunk, payload1);
      final frame2 = Protocol.encodeFrame(MessageType.fileChunk, payload2);
      
      final combined = Uint8List.fromList([...frame1, ...frame2]);
      
      final parser = FrameParser();
      final frames = parser.add(combined);
      
      expect(frames.length, equals(2));
      expect(frames[0].payload, equals(payload1));
      expect(frames[1].payload, equals(payload2));
    });

    test('FrameParser.add with incomplete frame', () {
      final payload = Uint8List.fromList([1, 2, 3, 4, 5]);
      final frame = Protocol.encodeFrame(MessageType.fileChunk, payload);
      
      final parser = FrameParser();
      // Add only partial frame
      final partial = Uint8List.sublistView(frame, 0, 3);
      final frames = parser.add(partial);
      
      expect(frames.length, equals(0));
    });

    test('FrameParser.add with frame split across multiple calls', () {
      final payload = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
      final frame = Protocol.encodeFrame(MessageType.fileChunk, payload);
      
      final parser = FrameParser();
      
      // Add first half
      final part1 = Uint8List.sublistView(frame, 0, frame.length ~/ 2);
      var frames = parser.add(part1);
      expect(frames.length, equals(0));
      
      // Add second half
      final part2 = Uint8List.sublistView(frame, frame.length ~/ 2);
      frames = parser.add(part2);
      
      expect(frames.length, equals(1));
      expect(frames[0].payload, equals(payload));
    });

    test('FrameParser.add with multiple frames split across calls', () {
      final payload1 = Uint8List.fromList([1, 2, 3]);
      final payload2 = Uint8List.fromList([4, 5, 6]);
      
      final frame1 = Protocol.encodeFrame(MessageType.fileChunk, payload1);
      final frame2 = Protocol.encodeFrame(MessageType.fileChunk, payload2);
      
      final parser = FrameParser();
      
      // Add most of first frame
      final partial = Uint8List.sublistView(frame1, 0, frame1.length - 2);
      var frames = parser.add(partial);
      expect(frames.length, equals(0));
      
      // Add rest of first + most of second
      final partial2 = Uint8List.sublistView(frame1, frame1.length - 2, frame1.length);
      final partial3 = Uint8List.sublistView(frame2, 0, frame2.length - 1);
      final combined = Uint8List.fromList([...partial2, ...partial3]);
      frames = parser.add(combined);
      
      expect(frames.length, equals(1));
      expect(frames[0].type, equals(MessageType.fileChunk));
    });

    test('FrameParser throws on unknown message type', () {
      final parser = FrameParser();
      
      // Manually create a frame with invalid type
      final header = ByteData(6);
      header.setUint8(0, kProtocolVersion);
      header.setUint8(1, 99); // Invalid type
      header.setUint32(2, 0, Endian.big);
      
      final frameBytes = Uint8List.fromList(header.buffer.asUint8List());
      
      expect(() => parser.add(frameBytes), throwsStateError);
    });

    test('FrameParser handles empty frame payload', () {
      final frame = Protocol.encodeFrame(MessageType.transferComplete, Uint8List(0));
      
      final parser = FrameParser();
      final frames = parser.add(frame);
      
      expect(frames.length, equals(1));
      expect(frames[0].payload.length, equals(0));
    });
  });

  group('Protocol - Constants', () {
    test('kProtocolVersion is set', () {
      expect(kProtocolVersion, equals(1));
    });
  });
}
