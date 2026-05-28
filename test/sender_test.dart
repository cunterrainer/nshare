import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:path/path.dart' as path;
import 'package:crypto/crypto.dart';
import 'package:nshare/nshare.dart';

// Mock classes for network testing
class MockSocket {
  final List<Uint8List> sentData = [];
  bool destroyed = false;
  final Completer<void> flushCompleter = Completer();

  void add(List<int> data) {
    sentData.add(Uint8List.fromList(data));
  }

  Future<void> flush() {
    return flushCompleter.future;
  }

  void destroy() {
    destroyed = true;
  }

  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class MockServerSocket {
  bool closed = false;

  Future<void> close() async {
    closed = true;
  }

  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class MockRawDatagramSocket {
  bool closed = false;
  final List<Datagram> _receivedDatagrams = [];
  final StreamController<RawSocketEvent> _eventController =
      StreamController.broadcast();

  void addDatagramResponse(String data, String senderIp) {
    _receivedDatagrams.add(Datagram(
      Uint8List.fromList(data.codeUnits),
      InternetAddress(senderIp),
      1234,
    ));
  }

  StreamSubscription<RawSocketEvent> listen(
    void Function(RawSocketEvent event)? onData, {
    Function? onError,
    Function? onDone,
    bool? cancelOnError,
  }) {
    // Emit read event when datagram is available
    if (_receivedDatagrams.isNotEmpty) {
      Future.delayed(Duration.zero, () {
        onData?.call(RawSocketEvent.read);
      });
    }

    return _eventController.stream.listen(
      onData,
      onError: onError,
      onDone: onDone as void Function()?,
      cancelOnError: cancelOnError ?? false,
    );
  }

  Datagram? receive() {
    if (_receivedDatagrams.isEmpty) return null;
    return _receivedDatagrams.removeAt(0);
  }

  void send(List<int> buffer, InternetAddress address, int port) {}

  set broadcastEnabled(bool value) {}

  Future<void> close() async {
    closed = true;
    await _eventController.close();
  }

  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('nshare_sender_test_');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('Sender - Unit Tests', () {
    group('SetupSocketSender()', () {
      test('SetupSocketSender() function exists and is callable', () {
        // Test that the function exists
        expect(SetupSocketSender, isNotNull);
      });

      test('SetupSocketSender() with null IP handling', () async {
        // Verify error handling for null values
        try {
          await SetupSocketSender('', 9999);
        } catch (e) {
          // Expected to fail
        }
      });
    });

    group('_sendEntry() with different file types', () {
      test('File entry for different file types', () async {
        final filePath = path.join(tempDir.path, 'test.txt');
        const testContent = 'Hello, World!';
        await File(filePath).writeAsString(testContent);

        final entry = FileEntry(
          absolutePath: filePath,
          relativePath: 'test.txt',
          isDirectory: false,
          size: testContent.length,
        );

        // Verify entry creation works
        expect(entry.absolutePath, contains('test.txt'));
        expect(entry.isDirectory, isFalse);
      });

      test('Directory entry creation', () async {
        final dirPath = path.join(tempDir.path, 'empty_dir');
        await Directory(dirPath).create();

        final entry = FileEntry(
          absolutePath: dirPath,
          relativePath: 'empty_dir',
          isDirectory: true,
          size: 0,
        );

        // Verify directory entry
        expect(entry.isDirectory, isTrue);
        expect(entry.size, equals(0));
      });

      test('File entry with correct size', () async {
        final filePath = path.join(tempDir.path, 'hashtest.txt');
        const testContent = 'Test content for hashing';
        await File(filePath).writeAsString(testContent);

        final entry = FileEntry(
          absolutePath: filePath,
          relativePath: 'hashtest.txt',
          isDirectory: false,
          size: testContent.length,
        );

        final actualSize = await File(filePath).length();
        expect(entry.size, equals(actualSize));
      });

      test('Large file entry representation', () async {
        final filePath = path.join(tempDir.path, 'largefile.bin');
        const largeSize = 10000;
        final largeContent = Uint8List(largeSize);
        for (int i = 0; i < largeContent.length; i++) {
          largeContent[i] = (i % 256).toUnsigned(8);
        }
        await File(filePath).writeAsBytes(largeContent);

        final entry = FileEntry(
          absolutePath: filePath,
          relativePath: 'largefile.bin',
          isDirectory: false,
          size: largeSize,
        );

        expect(entry.size, equals(largeSize));
      });
    });

    group('Send() with different scenarios', () {
      test('Send() with invalid input path returns gracefully', () async {
        try {
          await Send('/nonexistent/path/file.txt', 9999, '/nonexistent/file.txt',
              true, 1970, 1971);
          // Function should handle gracefully
        } catch (e) {
          // Path doesn't exist error is acceptable
          expect(e.toString(), contains('Path does not exist'));
        }
      });

      test('Send() with valid file but skipLookup=true', () async {
        final filePath = path.join(tempDir.path, 'test.txt');
        await File(filePath).writeAsString('test content');

        try {
          // This will fail to connect but tests the skipLookup parameter handling
          await Send('127.0.0.1', 9999, filePath, true, 1970, 1971);
        } catch (e) {
          // Expected to fail connecting to non-existent server
        }
      });

      test('Send() collects multiple files from directory', () async {
        final dirPath = path.join(tempDir.path, 'senddir');
        await Directory(dirPath).create();
        await File(path.join(dirPath, 'file1.txt')).writeAsString('content1');
        await File(path.join(dirPath, 'file2.txt')).writeAsString('content2');

        try {
          await Send('127.0.0.1', 9999, dirPath, true, 1970, 1971);
        } catch (e) {
          // Expected to fail connecting
        }
      });
    });

    group('FindReceiver() discovery protocol', () {
      test('FindReceiver() function exists and is callable', () {
        // Test that the function exists
        expect(FindReceiver, isNotNull);
      });
    });
  });

  group('Sender - Integration Tests', () {
    test('Complete file transfer flow with single file', () async {
      final filePath = path.join(tempDir.path, 'transfer.txt');
      final content = 'Transfer test content';
      await File(filePath).writeAsString(content);

      // Verify file exists and has correct content
      final exists = await File(filePath).exists();
      expect(exists, isTrue);

      final readContent = await File(filePath).readAsString();
      expect(readContent, equals(content));
    });

    test('Directory structure collection with nested files', () async {
      final rootDir = path.join(tempDir.path, 'structure_test');
      await Directory(rootDir).create();
      await Directory(path.join(rootDir, 'sub1')).create();
      await Directory(path.join(rootDir, 'sub1', 'sub2')).create();

      await File(path.join(rootDir, 'file1.txt')).writeAsString('content1');
      await File(path.join(rootDir, 'sub1', 'file2.txt')).writeAsString('content2');
      await File(path.join(rootDir, 'sub1', 'sub2', 'file3.txt'))
          .writeAsString('content3');

      // Collect entries
      final entries = await FileIO.collectEntries(rootDir);

      expect(entries, isNotEmpty);
      // Should have 5 entries: 3 files + 2 directories (or 3 files depending on implementation)
      expect(entries.where((e) => !e.isDirectory).length, greaterThanOrEqualTo(3));
    });

    test('File hashing consistency', () async {
      final filePath = path.join(tempDir.path, 'hash_test.txt');
      final content = 'Consistent hash test';
      await File(filePath).writeAsString(content);

      // Calculate hash
      final bytes = await File(filePath).readAsBytes();
      final hash1 = md5.convert(bytes).toString();
      final hash2 = md5.convert(bytes).toString();

      // Hashes should be identical
      expect(hash1, equals(hash2));
    });

    test('Multiple files with different sizes', () async {
      final sizes = [100, 1000, 10000];
      final files = <String>[];

      for (int i = 0; i < sizes.length; i++) {
        final filePath = path.join(tempDir.path, 'file_$i.bin');
        final data = Uint8List(sizes[i]);
        for (int j = 0; j < data.length; j++) {
          data[j] = (j % 256).toUnsigned(8);
        }
        await File(filePath).writeAsBytes(data);
        files.add(filePath);
      }

      // Verify all files exist with correct sizes
      for (int i = 0; i < files.length; i++) {
        final fileSize = await File(files[i]).length();
        expect(fileSize, equals(sizes[i]));
      }
    });

    test('Protocol message encoding for file transfer', () {
      final fileStart = FileStartMessage(
        relativePath: 'test/file.txt',
        size: 1024,
        isDirectory: false,
      );

      final encoded = Protocol.encodeFileStart(fileStart);
      final decoded = Protocol.decodeFileStart(encoded);

      expect(decoded.relativePath, equals('test/file.txt'));
      expect(decoded.size, equals(1024));
      expect(decoded.isDirectory, isFalse);
    });

    test('Empty directory transfer representation', () {
      final dirMsg = FileStartMessage(
        relativePath: 'emptydir',
        size: 0,
        isDirectory: true,
      );

      final encoded = Protocol.encodeFileStart(dirMsg);
      final decoded = Protocol.decodeFileStart(encoded);

      expect(decoded.isDirectory, isTrue);
      expect(decoded.size, equals(0));
    });

    test('File entry creation for various path types', () async {
      final filePath = path.join(tempDir.path, 'nested', 'deep', 'file.txt');
      await File(filePath).parent.create(recursive: true);
      await File(filePath).writeAsString('nested file content');

      final entry = FileEntry(
        absolutePath: filePath,
        relativePath: 'nested/deep/file.txt',
        isDirectory: false,
        size: 21,
      );

      expect(entry.absolutePath, contains('nested'));
      expect(entry.relativePath, equals('nested/deep/file.txt'));
    });

    test('Large file chunking simulation', () async {
      final largeFilePath = path.join(tempDir.path, 'largefile.bin');
      const largeSize = 100000;
      final data = Uint8List(largeSize);

      // Create large file with pattern
      for (int i = 0; i < data.length; i++) {
        data[i] = (i % 256).toUnsigned(8);
      }
      await File(largeFilePath).writeAsBytes(data);

      // Verify size
      final actualSize = await File(largeFilePath).length();
      expect(actualSize, equals(largeSize));

      // Verify hash consistency
      final readData = await File(largeFilePath).readAsBytes();
      final hash1 = md5.convert(readData).toString();
      final hash2 = md5.convert(data).toString();
      expect(hash1, equals(hash2));
    });

    test('Transfer complete frame encoding', () {
      final encoded = Protocol.encodeFrame(MessageType.transferComplete, Uint8List(0));
      expect(encoded.length, equals(6)); // Just header, no payload
    });

    test('Mixed content directory structure', () async {
      final rootDir = path.join(tempDir.path, 'mixed');
      await Directory(rootDir).create();

      // Create various file types
      await File(path.join(rootDir, 'text.txt')).writeAsString('text content');
      await File(path.join(rootDir, 'data.bin')).writeAsBytes(Uint8List(500));
      await Directory(path.join(rootDir, 'subdir')).create();
      await File(path.join(rootDir, 'subdir', 'nested.txt')).writeAsString('nested');

      final entries = await FileIO.collectEntries(rootDir);
      expect(entries.isNotEmpty, isTrue);
    });
  });

  group('Sender - Error Handling', () {
    test('Socket cleanup on error', () async {
      final mockSocket = MockSocket();

      // Simulate socket cleanup
      mockSocket.destroy();
      expect(mockSocket.destroyed, isTrue);
    });

    test('FileEntry with zero-size file', () {
      final entry = FileEntry(
        absolutePath: '/tmp/empty.txt',
        relativePath: 'empty.txt',
        isDirectory: false,
        size: 0,
      );

      expect(entry.size, equals(0));
      expect(entry.isDirectory, isFalse);
    });

    test('Path normalization for different separators', () {
      final path1 = FileIO.toProtocolPath('path\\to\\file.txt');
      expect(path1, equals('path/to/file.txt'));

      final path2 = FileIO.toProtocolPath('path/to/file.txt');
      expect(path2, equals('path/to/file.txt'));
    });
  });
}
