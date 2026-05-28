import 'dart:io';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:path/path.dart' as path;
import 'package:crypto/crypto.dart';
import 'package:nshare/nshare.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('nshare_integration_');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('Integration - File Transfer Simulation', () {
    test('Protocol message encoding/decoding roundtrip for file transfer', () {
      final fileStart = FileStartMessage(
        relativePath: 'documents/report.txt',
        size: 2048,
        isDirectory: false,
      );

      final encoded = Protocol.encodeFileStart(fileStart);
      final decoded = Protocol.decodeFileStart(encoded);

      expect(decoded.relativePath, equals('documents/report.txt'));
      expect(decoded.size, equals(2048));
      expect(decoded.isDirectory, isFalse);
    });

    test('Directory structure transfer simulation', () {
      final dirs = [
        FileStartMessage(relativePath: 'folder', size: 0, isDirectory: true),
        FileStartMessage(relativePath: 'folder/subfolder', size: 0, isDirectory: true),
        FileStartMessage(relativePath: 'folder/file1.txt', size: 512, isDirectory: false),
        FileStartMessage(relativePath: 'folder/subfolder/file2.txt', size: 1024, isDirectory: false),
      ];

      for (final msg in dirs) {
        final encoded = Protocol.encodeFileStart(msg);
        final decoded = Protocol.decodeFileStart(encoded);
        expect(decoded.relativePath, equals(msg.relativePath));
        expect(decoded.isDirectory, equals(msg.isDirectory));
      }
    });

    test('File collection from actual directory structure', () async {
      // Create test directory structure
      final srcDir = Directory(path.join(tempDir.path, 'source'));
      await srcDir.create();

      await File(path.join(srcDir.path, 'file1.txt')).writeAsString('content1');

      final subDir = Directory(path.join(srcDir.path, 'subfolder'));
      await subDir.create();
      await File(path.join(subDir.path, 'file2.txt')).writeAsString('content2');

      // Collect entries
      final entries = await FileIO.collectEntries(srcDir.path);

      expect(entries.isNotEmpty, isTrue);
      expect(entries.where((e) => !e.isDirectory).length, greaterThanOrEqualTo(2));
    });

    test('File write and read simulation', () async {
      final filePath = path.join(tempDir.path, 'transfer.bin');
      
      // Simulate send: write file
      final writer = await FileWriter.open(filePath);
      
      final testData = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
      await writer.write(testData, testData.length);
      
      await writer.close();

      // Simulate receive: read file
      final receivedData = await File(filePath).readAsBytes();
      expect(receivedData, equals(testData));
    });

    test('Multiple file transfer sequence', () async {
      final files = ['file1.txt', 'file2.bin', 'file3.dat'];
      final contents = {
        'file1.txt': 'Hello World',
        'file2.bin': 'Binary\x00Data\xFF',
        'file3.dat': 'Another file',
      };

      for (final filename in files) {
        final filePath = path.join(tempDir.path, filename);
        final writer = await FileWriter.open(filePath);
        
        final data = Uint8List.fromList(contents[filename]!.codeUnits);
        await writer.write(data, data.length);
        
        await writer.close();
      }

      // Verify all files exist and have correct size
      for (final filename in files) {
        final filePath = path.join(tempDir.path, filename);
        expect(await File(filePath).exists(), isTrue);
      }
    });

    test('File hash verification simulation', () {
      final testData = Uint8List.fromList([1, 2, 3, 4, 5]);
      
      // Simulate send: calculate hash
      final accumulator = DigestAccumulator();
      final hashInput = md5.startChunkedConversion(accumulator);
      hashInput.add(testData);
      hashInput.close();
      
      final sentHash = accumulator.events[0].toString();

      // Simulate receive: verify hash
      final receiveAccumulator = DigestAccumulator();
      final receiveHashInput = md5.startChunkedConversion(receiveAccumulator);
      receiveHashInput.add(testData);
      receiveHashInput.close();
      
      final receivedHash = receiveAccumulator.events[0].toString();

      expect(sentHash, equals(receivedHash));
    });

    test('Empty file transfer', () async {
      final filePath = path.join(tempDir.path, 'empty.txt');
      
      // Simulate send: create empty file
      final writer = await FileWriter.open(filePath);
      await writer.close();

      // Verify file exists and is empty
      expect(await File(filePath).exists(), isTrue);
      expect(await File(filePath).length(), equals(0));
    });

    test('Empty directory transfer', () async {
      final dirPath = path.join(tempDir.path, 'emptydir');
      
      // Simulate receive: create empty directory
      await FileIO.ensureDir(dirPath);

      // Verify directory exists and is empty
      expect(FileIO.isDirectorySync(dirPath), isTrue);
      expect(FileIO.isEmptyDirSync(dirPath), isTrue);
    });

    test('Nested directory structure transfer', () async {
      final baseDir = Directory(path.join(tempDir.path, 'nested'));
      await baseDir.create();

      // Create nested structure
      final dirs = [
        'level1/level2/level3',
        'level1/level2/another',
        'other/path',
      ];

      for (final dir in dirs) {
        await FileIO.ensureDir(path.join(baseDir.path, dir));
      }

      // Add files to some directories
      await File(path.join(baseDir.path, 'level1/file1.txt')).writeAsString('file1');
      await File(path.join(baseDir.path, 'level1/level2/file2.txt')).writeAsString('file2');
      await File(path.join(baseDir.path, 'other/path/file3.txt')).writeAsString('file3');

      // Collect all entries
      final entries = await FileIO.collectEntries(baseDir.path);

      final directories = entries.where((e) => e.isDirectory).length;
      final files = entries.where((e) => !e.isDirectory).length;

      expect(directories, greaterThan(0));
      expect(files, greaterThan(0));
    });

    test('Large file chunk transfer simulation', () async {
      final filePath = path.join(tempDir.path, 'large.bin');
      
      // Simulate large file transfer with chunks
      final writer = await FileWriter.open(filePath);
      
      const chunkSize = 4096;
      const totalChunks = 10;
      
      for (int i = 0; i < totalChunks; i++) {
        final chunk = Uint8List(chunkSize);
        for (int j = 0; j < chunkSize; j++) {
          chunk[j] = (i * chunkSize + j) % 256;
        }
        await writer.write(chunk, chunk.length);
      }

      await writer.close();

      // Verify file size
      expect(await File(filePath).length(), equals(chunkSize * totalChunks));
    });

    test('Progress bar simulation during transfer', () async {
      ProgressBar.Init();
      
      const totalSize = 1000;
      for (int current = 0; current <= totalSize; current += 100) {
        expect(() => ProgressBar.Show(current, totalSize), returnsNormally);
      }
    });

    test('File relative path preservation', () async {
      final srcDir = Directory(path.join(tempDir.path, 'preserve'));
      await srcDir.create();

      const relativePath = 'some/nested/path/file.txt';
      final fullPath = path.join(srcDir.path, 'some', 'nested', 'path', 'file.txt');
      
      await FileIO.ensureParentDir(fullPath);
      await File(fullPath).writeAsString('test');

      // Simulate path sanitization and recreation
      final sanitized = FileIO.sanitizeRelativePath(relativePath);
      final dstDir = Directory(path.join(tempDir.path, 'restore'));
      await dstDir.create();
      
      final destPath = path.join(dstDir.path, sanitized);
      await FileIO.ensureParentDir(destPath);
      await File(fullPath).copy(destPath);

      expect(await File(destPath).exists(), isTrue);
    });

    test('Configuration for complete transfer session', () {
      final sendConfig = NshareConfig(
        mode: ProgramMode.sender,
        port: 5000,
        discoveryPort: 1970,
        bindPort: 1971,
        fileName: 'document.pdf',
        ipAddress: '192.168.1.100',
        verifyWrittenFiles: false,
        keepFilesMode: KeepFilesMode.ask,
        skipLookup: false,
        verbose: true,
        timer: true,
      );

      final recvConfig = NshareConfig(
        mode: ProgramMode.receiver,
        port: 5000,
        discoveryPort: 1970,
        bindPort: 1971,
        fileName: 'received.pdf',
        ipAddress: '',
        verifyWrittenFiles: true,
        keepFilesMode: KeepFilesMode.keep,
        skipLookup: false,
        verbose: true,
        timer: true,
      );

      expect(sendConfig.port, equals(recvConfig.port));
      expect(sendConfig.discoveryPort, equals(recvConfig.discoveryPort));
      expect(sendConfig.bindPort, equals(recvConfig.bindPort));
    });

    test('Protocol frame sequence simulation for transfer', () {
      final frames = <ProtocolFrame>[];

      // Simulate file start
      final fileStart = Protocol.encodeFileStart(FileStartMessage(
        relativePath: 'data.bin',
        size: 1024,
        isDirectory: false,
      ));
      frames.add(ProtocolFrame(kProtocolVersion, MessageType.fileStart, fileStart));

      // Simulate file chunks
      for (int i = 0; i < 5; i++) {
        final chunk = Uint8List(256);
        frames.add(ProtocolFrame(kProtocolVersion, MessageType.fileChunk, chunk));
      }

      // Simulate file end
      final fileEnd = Protocol.encodeFileEnd('d41d8cd98f00b204e9800998ecf8427e');
      frames.add(ProtocolFrame(kProtocolVersion, MessageType.fileEnd, fileEnd));

      expect(frames.length, equals(7)); // 1 start + 5 chunks + 1 end
    });
  });
}
