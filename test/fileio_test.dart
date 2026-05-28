import 'dart:io';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:path/path.dart' as path;
import 'package:nshare/nshare.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('nshare_test_');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('FileEntry', () {
    test('FileEntry constructor creates instance with correct fields', () {
      final entry = FileEntry(
        absolutePath: '/home/user/file.txt',
        relativePath: 'file.txt',
        isDirectory: false,
        size: 1024,
      );

      expect(entry.absolutePath, equals('/home/user/file.txt'));
      expect(entry.relativePath, equals('file.txt'));
      expect(entry.isDirectory, isFalse);
      expect(entry.size, equals(1024));
    });

    test('FileEntry for directory', () {
      final entry = FileEntry(
        absolutePath: '/home/user/folder',
        relativePath: 'folder',
        isDirectory: true,
        size: 0,
      );

      expect(entry.isDirectory, isTrue);
      expect(entry.size, equals(0));
    });

    test('FileEntry with nested path', () {
      final entry = FileEntry(
        absolutePath: '/home/user/nested/folder/file.txt',
        relativePath: 'nested/folder/file.txt',
        isDirectory: false,
        size: 512,
      );

      expect(entry.relativePath, equals('nested/folder/file.txt'));
    });
  });

  group('FileWriter', () {
    test('FileWriter.open() creates file', () async {
      final filePath = path.join(tempDir.path, 'test.txt');
      final writer = await FileWriter.open(filePath);

      expect(await File(filePath).exists(), isTrue);
      await writer.close();
    });

    test('FileWriter.write() writes data', () async {
      final filePath = path.join(tempDir.path, 'test.txt');
      final writer = await FileWriter.open(filePath);

      final data = Uint8List.fromList([72, 101, 108, 108, 111]); // "Hello"
      await writer.write(data, 5);

      await writer.close();

      final file = File(filePath);
      final content = await file.readAsBytes();
      expect(content, equals(data));
    });

    test('FileWriter.write() with zero length does nothing', () async {
      final filePath = path.join(tempDir.path, 'test.txt');
      final writer = await FileWriter.open(filePath);

      final data = Uint8List.fromList([1, 2, 3]);
      await writer.write(data, 0);

      await writer.close();

      final file = File(filePath);
      final size = await file.length();
      expect(size, equals(0));
    });

    test('FileWriter.bytesWritten tracks written bytes', () async {
      final filePath = path.join(tempDir.path, 'test.txt');
      final writer = await FileWriter.open(filePath);

      expect(writer.bytesWritten, equals(0));

      final data = Uint8List.fromList([1, 2, 3, 4, 5]);
      await writer.write(data, 5);

      expect(writer.bytesWritten, equals(5));

      await writer.write(data, 3);
      expect(writer.bytesWritten, equals(8));

      await writer.close();
    });

    test('FileWriter.write() multiple times accumulates data', () async {
      final filePath = path.join(tempDir.path, 'test.txt');
      final writer = await FileWriter.open(filePath);

      await writer.write(Uint8List.fromList([1, 2, 3]), 3);
      await writer.write(Uint8List.fromList([4, 5, 6]), 3);
      await writer.write(Uint8List.fromList([7, 8, 9]), 3);

      await writer.close();

      final file = File(filePath);
      final content = await file.readAsBytes();
      expect(content, equals(Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8, 9])));
    });

    test('FileWriter.delete() removes file', () async {
      final filePath = path.join(tempDir.path, 'test.txt');
      final writer = await FileWriter.open(filePath);

      await writer.write(Uint8List.fromList([1, 2, 3]), 3);
      await writer.delete();

      expect(await File(filePath).exists(), isFalse);
    });

    test('FileWriter.path stores file path', () async {
      final filePath = path.join(tempDir.path, 'myfile.bin');
      final writer = await FileWriter.open(filePath);

      expect(writer.path, contains('myfile.bin'));

      await writer.close();
    });
  });

  group('FileIO.toProtocolPath()', () {
    test('toProtocolPath replaces backslashes with forward slashes', () {
      expect(FileIO.toProtocolPath('folder\\file.txt'), equals('folder/file.txt'));
      expect(FileIO.toProtocolPath('a\\b\\c\\d.txt'), equals('a/b/c/d.txt'));
    });

    test('toProtocolPath leaves forward slashes unchanged', () {
      expect(FileIO.toProtocolPath('folder/file.txt'), equals('folder/file.txt'));
    });

    test('toProtocolPath with empty string', () {
      expect(FileIO.toProtocolPath(''), isEmpty);
    });
  });

  group('FileIO.sanitizeRelativePath()', () {
    test('sanitizeRelativePath removes leading slashes', () {
      expect(FileIO.sanitizeRelativePath('/file.txt'), equals('file.txt'));
      expect(FileIO.sanitizeRelativePath('/folder/file.txt'), equals('folder/file.txt'));
    });

    test('sanitizeRelativePath removes .. references', () {
      expect(FileIO.sanitizeRelativePath('../file.txt'), equals('file.txt'));
      expect(FileIO.sanitizeRelativePath('folder/../file.txt'), equals('file.txt'));
    });

    test('sanitizeRelativePath converts backslashes', () {
      expect(FileIO.sanitizeRelativePath('folder\\file.txt'), equals('folder/file.txt'));
    });

    test('sanitizeRelativePath normalizes paths', () {
      final result = FileIO.sanitizeRelativePath('folder//subfolder///file.txt');
      expect(result.contains('//'), isFalse);
    });

    test('sanitizeRelativePath with empty segments', () {
      expect(FileIO.sanitizeRelativePath('folder//file.txt'), equals('folder/file.txt'));
    });
  });

  group('FileIO.collectEntries() - Files', () {
    test('collectEntries with single file', () async {
      final filePath = path.join(tempDir.path, 'test.txt');
      await File(filePath).writeAsString('test content');

      final entries = await FileIO.collectEntries(filePath);

      expect(entries.length, equals(1));
      expect(entries[0].absolutePath, equals(File(filePath).absolute.path));
      expect(entries[0].isDirectory, isFalse);
      expect(entries[0].size, greaterThan(0));
    });

    test('collectEntries with empty file', () async {
      final filePath = path.join(tempDir.path, 'empty.txt');
      await File(filePath).create();

      final entries = await FileIO.collectEntries(filePath);

      expect(entries.length, equals(1));
      expect(entries[0].size, equals(0));
    });

    test('collectEntries with large file', () async {
      final filePath = path.join(tempDir.path, 'large.bin');
      final file = File(filePath);
      await file.writeAsBytes(List<int>.generate(1024 * 1024, (i) => i % 256));

      final entries = await FileIO.collectEntries(filePath);

      expect(entries.length, equals(1));
      expect(entries[0].size, equals(1024 * 1024));
    });

    test('collectEntries with non-existent path throws', () async {
      final filePath = path.join(tempDir.path, 'nonexistent.txt');

      expect(
        () => FileIO.collectEntries(filePath),
        throwsA(anything),
      );
    });
  });

  group('FileIO.collectEntries() - Directories', () {
    test('collectEntries with single file in directory', () async {
      final subDir = Directory(path.join(tempDir.path, 'subdir'));
      await subDir.create();
      final filePath = path.join(subDir.path, 'file.txt');
      await File(filePath).writeAsString('content');

      final entries = await FileIO.collectEntries(subDir.path);

      expect(entries.length, equals(1));
      expect(entries[0].isDirectory, isFalse);
      expect(entries[0].relativePath, contains('file.txt'));
    });

    test('collectEntries with empty directory', () async {
      final emptyDir = Directory(path.join(tempDir.path, 'empty'));
      await emptyDir.create();

      final entries = await FileIO.collectEntries(emptyDir.path);

      expect(entries.length, equals(1));
      expect(entries[0].isDirectory, isTrue);
    });

    test('collectEntries with multiple files', () async {
      final subDir = Directory(path.join(tempDir.path, 'multi'));
      await subDir.create();

      for (int i = 0; i < 5; i++) {
        await File(path.join(subDir.path, 'file$i.txt')).writeAsString('content$i');
      }

      final entries = await FileIO.collectEntries(subDir.path);

      expect(entries.length, equals(5));
      for (final entry in entries) {
        expect(entry.isDirectory, isFalse);
      }
    });

    test('collectEntries with nested directories', () async {
      final dir1 = Directory(path.join(tempDir.path, 'level1'));
      final dir2 = Directory(path.join(dir1.path, 'level2'));
      await dir1.create();
      await dir2.create();

      await File(path.join(dir1.path, 'file1.txt')).writeAsString('content1');
      await File(path.join(dir2.path, 'file2.txt')).writeAsString('content2');

      final entries = await FileIO.collectEntries(dir1.path);

      expect(entries.length, greaterThanOrEqualTo(2));
      // Directory entries are only included if they are empty
      expect(entries.where((e) => !e.isDirectory).length, equals(2));
    });

    test('collectEntries with mixed files and directories', () async {
      final baseDir = Directory(path.join(tempDir.path, 'mixed'));
      await baseDir.create();

      await File(path.join(baseDir.path, 'file.txt')).writeAsString('content');
      await Directory(path.join(baseDir.path, 'subdir')).create();
      await File(path.join(baseDir.path, 'subdir', 'nested.txt')).writeAsString('nested');

      final entries = await FileIO.collectEntries(baseDir.path);

      final files = entries.where((e) => !e.isDirectory).toList();
      final dirs = entries.where((e) => e.isDirectory).toList();

      expect(files.length, equals(2));
      // Only empty directories are included in entries
      expect(dirs.length, equals(0));
    });

    test('collectEntries relative paths are correct', () async {
      final baseDir = Directory(path.join(tempDir.path, 'relative'));
      await baseDir.create();

      await File(path.join(baseDir.path, 'file.txt')).writeAsString('content');

      final entries = await FileIO.collectEntries(baseDir.path);

      // When no basePath is provided, relative paths are calculated from parent directory
      expect(entries[0].relativePath, equals('relative/file.txt'));
    });
  });

  group('FileIO.ensureParentDir()', () {
    test('ensureParentDir creates parent directories', () async {
      final filePath = path.join(tempDir.path, 'a', 'b', 'c', 'file.txt');

      await FileIO.ensureParentDir(filePath);

      expect(await Directory(path.dirname(filePath)).exists(), isTrue);
    });

    test('ensureParentDir with existing parent does nothing', () async {
      final filePath = path.join(tempDir.path, 'file.txt');

      expect(() => FileIO.ensureParentDir(filePath), returnsNormally);
    });
  });

  group('FileIO.ensureDir()', () {
    test('ensureDir creates directory', () async {
      final dirPath = path.join(tempDir.path, 'newdir');

      await FileIO.ensureDir(dirPath);

      expect(await Directory(dirPath).exists(), isTrue);
    });

    test('ensureDir creates nested directories', () async {
      final dirPath = path.join(tempDir.path, 'a', 'b', 'c', 'd');

      await FileIO.ensureDir(dirPath);

      expect(await Directory(dirPath).exists(), isTrue);
    });

    test('ensureDir with existing directory does nothing', () async {
      final dirPath = path.join(tempDir.path, 'existing');
      await Directory(dirPath).create();

      await FileIO.ensureDir(dirPath);

      expect(await Directory(dirPath).exists(), isTrue);
    });
  });

  group('FileIO.isDirectorySync()', () {
    test('isDirectorySync returns true for directory', () async {
      final dirPath = path.join(tempDir.path, 'testdir');
      await Directory(dirPath).create();

      expect(FileIO.isDirectorySync(dirPath), isTrue);
    });

    test('isDirectorySync returns false for file', () async {
      final filePath = path.join(tempDir.path, 'testfile.txt');
      await File(filePath).create();

      expect(FileIO.isDirectorySync(filePath), isFalse);
    });

    test('isDirectorySync returns false for non-existent path', () {
      final fakePath = path.join(tempDir.path, 'nonexistent');

      expect(FileIO.isDirectorySync(fakePath), isFalse);
    });
  });

  group('FileIO.isEmptyDirSync()', () {
    test('isEmptyDirSync returns true for empty directory', () async {
      final dirPath = path.join(tempDir.path, 'empty');
      await Directory(dirPath).create();

      expect(FileIO.isEmptyDirSync(dirPath), isTrue);
    });

    test('isEmptyDirSync returns false for non-empty directory', () async {
      final dirPath = path.join(tempDir.path, 'nonempty');
      await Directory(dirPath).create();
      await File(path.join(dirPath, 'file.txt')).create();

      expect(FileIO.isEmptyDirSync(dirPath), isFalse);
    });

    test('isEmptyDirSync returns false for file', () async {
      final filePath = path.join(tempDir.path, 'file.txt');
      await File(filePath).create();

      expect(FileIO.isEmptyDirSync(filePath), isFalse);
    });
  });

  group('FileIO.chunkSize', () {
    test('chunkSize constant is defined', () {
      expect(FileIO.chunkSize, equals(4096));
    });
  });
}
