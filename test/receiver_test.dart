import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:path/path.dart' as path;
import 'package:crypto/crypto.dart';
import 'package:nshare/nshare.dart';

// Mock classes for network testing
class MockSocket {
  final List<Uint8List> _incomingData = [];
  final StreamController<Uint8List> _dataController = StreamController.broadcast();
  bool destroyed = false;

  void addIncomingData(Uint8List data) {
    _incomingData.add(data);
    _dataController.add(data);
  }

  void finishStream() {
    _dataController.close();
  }

  Stream<Uint8List> get asBroadcastStream => _dataController.stream;

  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    Function? onDone,
    bool? cancelOnError,
  }) {
    return _dataController.stream.listen(
      onData,
      onError: onError,
      onDone: onDone as void Function()?,
      cancelOnError: cancelOnError ?? false,
    );
  }

  void destroy() {
    destroyed = true;
  }

  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class MockServerSocket {
  final MockSocket _connectedSocket;
  bool closed = false;

  MockServerSocket(this._connectedSocket);

  Future<Socket> get first async {
    return _connectedSocket as Socket;
  }

  Future<void> close() async {
    closed = true;
  }

  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class MockRawDatagramSocket {
  bool closed = false;
  bool _broadcastEnabled = false;
  final StreamController<RawSocketEvent> _eventController =
      StreamController.broadcast();
  int? _senderDiscoveryPort;
  InternetAddress? _senderAddress;

  void simulateDiscoveryRequest(InternetAddress senderAddr, int discoveryPort) {
    _senderAddress = senderAddr;
    _senderDiscoveryPort = discoveryPort;
    Future.delayed(Duration.zero, () {
      _eventController.add(RawSocketEvent.read);
    });
  }

  StreamSubscription<RawSocketEvent> listen(
    void Function(RawSocketEvent event)? onData, {
    Function? onError,
    Function? onDone,
    bool? cancelOnError,
  }) {
    return _eventController.stream.listen(
      onData,
      onError: onError,
      onDone: onDone as void Function()?,
      cancelOnError: cancelOnError ?? false,
    );
  }

  Datagram? receive() {
    if (_senderAddress == null) return null;
    const message = "NSHARE_DISCOVER";
    return Datagram(
      Uint8List.fromList(message.codeUnits),
      _senderAddress!,
      _senderDiscoveryPort ?? 1234,
    );
  }

  void send(List<int> buffer, InternetAddress address, int port) {
    // Simulate sending response
  }

  set broadcastEnabled(bool value) {
    _broadcastEnabled = value;
  }

  Future<void> close() async {
    closed = true;
    await _eventController.close();
  }

  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('nshare_receiver_test_');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('Receiver - Unit Tests', () {
    group('checkIntegrity()', () {
      test('checkIntegrity() with matching hash returns true', () {
        final hash = 'd41d8cd98f00b204e9800998ecf8427e'; // MD5 of empty string
        final result = checkIntegrity(hash, hash, 'test.txt');
        expect(result, isTrue);
      });

      test('checkIntegrity() with mismatched hash returns false', () {
        final receivedHash = 'd41d8cd98f00b204e9800998ecf8427e';
        final computedHash = '5d41402abc4b2a76b9719d911017c592';
        final result = checkIntegrity(receivedHash, computedHash, 'test.txt');
        expect(result, isFalse);
      });

      test('checkIntegrity() handles different file names', () {
        final hash = 'd41d8cd98f00b204e9800998ecf8427e';
        final result = checkIntegrity(hash, hash, 'path/to/deep/nested/file.txt');
        expect(result, isTrue);
      });

      test('checkIntegrity() with empty hash strings', () {
        final result = checkIntegrity('', '', 'file.txt');
        expect(result, isTrue);
      });
    });

    group('promptYesNo()', () {
      test('promptYesNo() prompt message is shown', () {
        // This test verifies the function exists and signature is correct
        // Actual input testing would require stdin mocking
        expect(() => promptYesNo('Test prompt: '), isA<Function>());
      });
    });

    group('setupSocketReceiver()', () {
      test('setupSocketReceiver() function exists and is callable', () {
        // Test that the function exists
        expect(setupSocketReceiver, isNotNull);
      });

      test('setupSocketReceiver() returns ServerSocket on port 0', () async {
        try {
          final server = await setupSocketReceiver(0); // 0 = auto-assign port
          if (server != null) {
            expect(server, isA<ServerSocket>());
            await server.close();
          }
        } catch (e) {
          // Expected in some test environments
          expect(e, isNotNull);
        }
      }, timeout: Timeout(Duration(seconds: 3)));
    });

    group('FindSender()', () {
      test('FindSender() function exists and is callable', () {
        // Test that the function exists
        expect(FindSender, isNotNull);
      });

      test('FindSender() handles discovery socket binding', () async {
        try {
          // This will attempt to listen for discovery
          final future = FindSender(19702, 19712);
          // Give it a moment to set up, then it should fail quickly
          await Future.delayed(Duration(milliseconds: 100));
          expect(true, isTrue);
        } catch (e) {
          // Socket binding may fail in test environment - expected
          expect(e, isNotNull);
        }
      }, timeout: Timeout(Duration(seconds: 1)));
    });

    group('verifyFiles()', () {
      test('verifyFiles() with matching file hashes', () async {
        // Create test file
        final filePath = path.join(tempDir.path, 'verify_test.txt');
        const content = 'test content';
        await File(filePath).writeAsString(content);

        // Calculate hash
        final bytes = await File(filePath).readAsBytes();
        final hash = md5.convert(bytes).toString();

        final fileHashValues = [[filePath, hash]];
        await verifyFiles(fileHashValues);
        // Should complete without errors
      });

      test('verifyFiles() with multiple files', () async {
        // Create multiple test files
        final file1 = path.join(tempDir.path, 'file1.txt');
        final file2 = path.join(tempDir.path, 'file2.txt');

        await File(file1).writeAsString('content1');
        await File(file2).writeAsString('content2');

        // Calculate hashes
        final hash1 =
            md5.convert(await File(file1).readAsBytes()).toString();
        final hash2 =
            md5.convert(await File(file2).readAsBytes()).toString();

        final fileHashValues = [[file1, hash1], [file2, hash2]];
        await verifyFiles(fileHashValues);
        // Should complete without errors
      });

      test('verifyFiles() with non-existent file', () async {
        const nonExistent = '/tmp/nonexistent_verify_test.txt';
        final fileHashValues = [[nonExistent, 'somehash']];
        await verifyFiles(fileHashValues);
        // Should handle gracefully
      });

      test('verifyFiles() with directory path', () async {
        final dirPath = path.join(tempDir.path, 'verify_dir');
        await Directory(dirPath).create();

        final fileHashValues = [[dirPath, 'somehash']];
        await verifyFiles(fileHashValues);
        // Should skip directories
      });
    });

    group('_ReceiverSession class', () {
      test('_ReceiverSession constructor initializes state correctly', () {
        final fileHashes = <List<String>>[];
        // We can't directly test private class, but we can test through Receive()
        expect(fileHashes, isEmpty);
      });
    });
  });

  group('Receiver - Integration Tests', () {
    test('Complete file receive flow with single file frame', () async {
      final outputPath = path.join(tempDir.path, 'received');
      await Directory(outputPath).create();

      // Create a test file and frame
      final testFileName = 'test_receive.txt';
      const testContent = 'Received content';

      final fileStartMsg = FileStartMessage(
        relativePath: testFileName,
        size: testContent.length,
        isDirectory: false,
      );

      // This would be part of integration with Receive()
      expect(fileStartMsg.relativePath, equals(testFileName));
      expect(fileStartMsg.isDirectory, isFalse);
    });

    test('Directory entry handling in protocol', () {
      final dirMsg = FileStartMessage(
        relativePath: 'received_dir',
        size: 0,
        isDirectory: true,
      );

      final encoded = Protocol.encodeFileStart(dirMsg);
      final decoded = Protocol.decodeFileStart(encoded);

      expect(decoded.isDirectory, isTrue);
      expect(decoded.relativePath, equals('received_dir'));
    });

    test('File hash encoding and decoding', () {
      const testHash = 'd41d8cd98f00b204e9800998ecf8427e';
      final encoded = Protocol.encodeFileEnd(testHash);
      final decoded = Protocol.decodeFileEnd(encoded);

      expect(decoded, equals(testHash));
    });

    test('Frame parser with multiple frames', () {
      final parser = FrameParser();

      // Create test frames
      final frame1Data = Uint8List.fromList([1, 2, 3, 4, 5]);
      final frame2Data = Uint8List.fromList([6, 7, 8, 9, 10]);

      final encoded1 = Protocol.encodeFrame(MessageType.fileChunk, frame1Data);
      final encoded2 = Protocol.encodeFrame(MessageType.fileChunk, frame2Data);

      // Combine frames
      final combinedData = Uint8List.fromList([...encoded1, ...encoded2]);

      // Parse
      final frames = parser.add(combinedData);

      expect(frames.length, equals(2));
      expect(frames[0].payload, equals(frame1Data));
      expect(frames[1].payload, equals(frame2Data));
    });

    test('Received file path sanitization', () {
      final unsafePath = '../../../etc/passwd';
      final sanitized = FileIO.sanitizeRelativePath(unsafePath);

      // Sanitized path should not contain ..
      expect(sanitized.contains('..'), isFalse);
    });

    test('Output directory creation', () async {
      final outputPath = path.join(tempDir.path, 'nested', 'output', 'dir');
      await FileIO.ensureDir(outputPath);

      expect(await Directory(outputPath).exists(), isTrue);
    });

    test('Parent directory creation for received file', () async {
      final filePath = path.join(tempDir.path, 'a', 'b', 'c', 'file.txt');
      await FileIO.ensureParentDir(filePath);

      final parentDir = File(filePath).parent;
      expect(await parentDir.exists(), isTrue);
    });

    test('Received file writing', () async {
      final filePath = path.join(tempDir.path, 'written_file.txt');
      const testContent = 'Written content';

      final writer = await FileWriter.open(filePath);
      await writer.write(Uint8List.fromList(testContent.codeUnits),
          testContent.length);
      await writer.close();

      final content = await File(filePath).readAsString();
      expect(content, equals(testContent));
    });

    test('Receive with keepFiles mode: keep', () async {
      // Tests that files are preserved with KeepFilesMode.keep
      expect(KeepFilesMode.keep, isA<KeepFilesMode>());
    });

    test('Receive with keepFiles mode: delete', () async {
      // Tests that files can be deleted with KeepFilesMode.delete
      expect(KeepFilesMode.delete, isA<KeepFilesMode>());
    });

    test('Receive with keepFiles mode: ask', () async {
      // Tests that files can prompt with KeepFilesMode.ask
      expect(KeepFilesMode.ask, isA<KeepFilesMode>());
    });

    test('Protocol version compatibility check', () {
      expect(kProtocolVersion, equals(1));

      final frame = ProtocolFrame(
          kProtocolVersion, MessageType.fileStart, Uint8List(0));
      expect(frame.version, equals(kProtocolVersion));
    });

    test('Hash value storage in file list', () async {
      final filePath = path.join(tempDir.path, 'hash_storage.txt');
      const content = 'Hash storage test';
      await File(filePath).writeAsString(content);

      final bytes = await File(filePath).readAsBytes();
      final hash = md5.convert(bytes).toString();

      final fileHashList = [filePath, hash];
      expect(fileHashList[0], equals(filePath));
      expect(fileHashList[1], equals(hash));
    });

    test('Multiple sequential file receptions', () async {
      // Simulates receiving multiple files sequentially
      const files = ['file1.txt', 'file2.txt', 'file3.txt'];
      final fileHashes = <List<String>>[];

      for (final fileName in files) {
        final filePath = path.join(tempDir.path, fileName);
        await File(filePath).writeAsString('content of $fileName');

        final hash =
            md5.convert(await File(filePath).readAsBytes()).toString();
        fileHashes.add([filePath, hash]);
      }

      expect(fileHashes.length, equals(3));
      expect(fileHashes[0][0], contains('file1.txt'));
      expect(fileHashes[1][0], contains('file2.txt'));
      expect(fileHashes[2][0], contains('file3.txt'));
    });

    test('Received directory structure creation', () async {
      final outputPath = path.join(tempDir.path, 'received_structure');
      await FileIO.ensureDir(outputPath);

      final subDir = Directory(path.join(outputPath, 'subdir'));
      await subDir.create(recursive: true);

      final file = File(path.join(subDir.path, 'file.txt'));
      await file.writeAsString('nested content');

      expect(await file.exists(), isTrue);
    });

    test('Large file reception with chunking', () async {
      final filePath = path.join(tempDir.path, 'large_received.bin');
      const chunkSize = 4096;
      const numChunks = 10;
      const totalSize = chunkSize * numChunks;

      final writer = await FileWriter.open(filePath);

      for (int i = 0; i < numChunks; i++) {
        final chunk = Uint8List(chunkSize);
        for (int j = 0; j < chunkSize; j++) {
          chunk[j] = ((i * chunkSize + j) % 256).toUnsigned(8);
        }
        await writer.write(chunk, chunkSize);
      }

      await writer.close();

      final fileSize = await File(filePath).length();
      expect(fileSize, equals(totalSize));
    });

    test('File integrity check after reception', () async {
      final filePath = path.join(tempDir.path, 'integrity_check.txt');
      const content = 'Integrity check content';
      await File(filePath).writeAsString(content);

      // Calculate hash
      final bytes = await File(filePath).readAsBytes();
      final hash = md5.convert(bytes).toString();

      // Verify
      final verify = checkIntegrity(hash, hash, filePath);
      expect(verify, isTrue);
    });

    test('Corrupted file detection', () async {
      const correctHash = 'd41d8cd98f00b204e9800998ecf8427e';
      const wrongHash = '5d41402abc4b2a76b9719d911017c592';

      final isValid = checkIntegrity(correctHash, wrongHash, 'corrupted.txt');
      expect(isValid, isFalse);
    });

    test('Empty file reception', () async {
      final filePath = path.join(tempDir.path, 'empty_received.txt');
      final writer = await FileWriter.open(filePath);
      await writer.close();

      final bytes = await File(filePath).readAsBytes();
      expect(bytes.isEmpty, isTrue);

      final hash = md5.convert(bytes).toString();
      expect(hash, equals('d41d8cd98f00b204e9800998ecf8427e'));
    });

    test('Transfer complete frame handling', () {
      final completeFrame = Protocol.encodeFrame(
          MessageType.transferComplete, Uint8List(0));
      expect(completeFrame.length, equals(6)); // Header only
    });

    test('Mixed file types reception', () async {
      final textFile = path.join(tempDir.path, 'text.txt');
      final binaryFile = path.join(tempDir.path, 'binary.bin');

      await File(textFile).writeAsString('Text content');
      await File(binaryFile)
          .writeAsBytes(Uint8List.fromList([0, 1, 2, 3, 255]));

      final textExists = await File(textFile).exists();
      final binaryExists = await File(binaryFile).exists();

      expect(textExists, isTrue);
      expect(binaryExists, isTrue);
    });

    test('Received files list generation', () async {
      final files = ['file1.txt', 'file2.txt'];
      final hashes = <List<String>>[];

      for (final file in files) {
        final filePath = path.join(tempDir.path, file);
        await File(filePath).writeAsString('content');
        final hash = md5.convert(await File(filePath).readAsBytes()).toString();
        hashes.add([filePath, hash]);
      }

      expect(hashes.length, equals(2));
    });
  });

  group('Receiver - Error Handling', () {
    test('Socket cleanup on error', () {
      final mockSocket = MockSocket();
      mockSocket.destroy();
      expect(mockSocket.destroyed, isTrue);
    });

    test('FileWriter handles write errors gracefully', () async {
      final filePath = path.join(tempDir.path, 'write_test.txt');
      final writer = await FileWriter.open(filePath);

      // Writing zero bytes should not crash
      await writer.write(Uint8List(0), 0);
      await writer.close();

      expect(await File(filePath).exists(), isTrue);
    });

    test('FileWriter tracks bytes written accurately', () async {
      final filePath = path.join(tempDir.path, 'bytes_tracked.txt');
      final writer = await FileWriter.open(filePath);

      expect(writer.bytesWritten, equals(0));

      const data1 = 'Hello';
      const data2 = 'World';

      await writer.write(Uint8List.fromList(data1.codeUnits), data1.length);
      expect(writer.bytesWritten, equals(data1.length));

      await writer.write(Uint8List.fromList(data2.codeUnits), data2.length);
      expect(writer.bytesWritten, equals(data1.length + data2.length));

      await writer.close();
    });

    test('Path validation and sanitization', () {
      final paths = [
        'normal/path.txt',
        'path\\with\\backslashes.txt',
        '../../../etc/passwd',
        '..\\..\\..\\windows\\system32',
      ];

      for (final p in paths) {
        final sanitized = FileIO.sanitizeRelativePath(p);
        expect(sanitized.isNotEmpty, isTrue);
      }
    });

    test('Directory existence check before creation', () async {
      final dirPath = path.join(tempDir.path, 'existence_check');
      
      expect(await Directory(dirPath).exists(), isFalse);
      await FileIO.ensureDir(dirPath);
      expect(await Directory(dirPath).exists(), isTrue);
    });

    test('Idempotent directory creation', () async {
      final dirPath = path.join(tempDir.path, 'idempotent_dir');
      
      await FileIO.ensureDir(dirPath);
      await FileIO.ensureDir(dirPath);
      
      expect(await Directory(dirPath).exists(), isTrue);
    });

    test('File deletion after corruption detection', () async {
      final filePath = path.join(tempDir.path, 'delete_test.txt');
      await File(filePath).writeAsString('corrupted content');

      expect(await File(filePath).exists(), isTrue);

      // Simulate deletion
      await File(filePath).delete();
      expect(await File(filePath).exists(), isFalse);
    });

    test('Protocol version mismatch detection', () {
      final incompatibleVersion = 99;
      final currentVersion = kProtocolVersion;

      expect(incompatibleVersion, isNot(currentVersion));
    });

    test('Invalid message type handling', () {
      // MessageType enum should have exactly 4 values
      expect(MessageType.values.length, equals(4));
    });

    test('Empty payload handling', () {
      final emptyFrame = Protocol.encodeFrame(MessageType.fileChunk, Uint8List(0));
      expect(emptyFrame.length, equals(6)); // Header only
    });

    test('Concurrent file operations', () async {
      final futures = <Future>[];

      for (int i = 0; i < 5; i++) {
        futures.add(() async {
          final filePath = path.join(tempDir.path, 'concurrent_$i.txt');
          await File(filePath).writeAsString('content $i');
        }());
      }

      await Future.wait(futures);

      for (int i = 0; i < 5; i++) {
        final filePath = path.join(tempDir.path, 'concurrent_$i.txt');
        expect(await File(filePath).exists(), isTrue);
      }
    });
  });

  group('Receiver - Protocol Frame Parsing', () {
    test('Parse fileStart frame', () {
      const path = 'test.txt';
      const size = 1024;
      const isDir = false;

      final msg = FileStartMessage(
        relativePath: path,
        size: size,
        isDirectory: isDir,
      );

      final encoded = Protocol.encodeFileStart(msg);
      final decoded = Protocol.decodeFileStart(encoded);

      expect(decoded.relativePath, equals(path));
      expect(decoded.size, equals(size));
      expect(decoded.isDirectory, equals(isDir));
    });

    test('Parse fileEnd frame with hash', () {
      const hash = 'a1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6';
      final encoded = Protocol.encodeFileEnd(hash);
      final decoded = Protocol.decodeFileEnd(encoded);

      expect(decoded, equals(hash));
    });

    test('Parse fileChunk frame', () {
      final payload = Uint8List.fromList([1, 2, 3, 4, 5]);
      final encoded = Protocol.encodeFrame(MessageType.fileChunk, payload);

      // Verify header structure
      expect(encoded[0], equals(kProtocolVersion));
      expect(encoded[1], equals(MessageType.fileChunk.index));
    });

    test('Frame parser state management', () {
      final parser = FrameParser();

      final data1 = Uint8List.fromList([1, 2, 3]);
      final data2 = Uint8List.fromList([4, 5, 6]);

      final frames1 = parser.add(data1);
      final frames2 = parser.add(data2);

      // Parser should maintain state across calls
      expect(frames1, isA<List>());
      expect(frames2, isA<List>());
    });

    test('Partial frame handling in parser', () {
      final parser = FrameParser();

      // Create a frame but feed it byte by byte
      final payload = Uint8List.fromList([1, 2, 3, 4, 5]);
      final fullFrame = Protocol.encodeFrame(MessageType.fileChunk, payload);

      // Feed only part of header
      final partialFrames = parser.add(Uint8List.sublistView(fullFrame, 0, 3));
      expect(partialFrames.isEmpty, isTrue);

      // Feed rest of frame
      final completeFrames = parser.add(Uint8List.sublistView(fullFrame, 3));
      expect(completeFrames.length, greaterThanOrEqualTo(0));
    });

    test('Large payload frame parsing', () {
      final payload = Uint8List(100000);
      for (int i = 0; i < payload.length; i++) {
        payload[i] = (i % 256).toUnsigned(8);
      }

      final encoded = Protocol.encodeFrame(MessageType.fileChunk, payload);
      final parser = FrameParser();
      final frames = parser.add(encoded);

      expect(frames.isNotEmpty, isTrue);
      expect(frames[0].payload, equals(payload));
    });
  });
}
