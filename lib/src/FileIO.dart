library FileIO;
import "dart:io";
import "dart:typed_data";

import "package:path/path.dart" as path;

import "Log.dart";

class FileEntry
{
  FileEntry({
    required this.absolutePath,
    required this.relativePath,
    required this.isDirectory,
    required this.size,
  });

  final String absolutePath;
  final String relativePath;
  final bool isDirectory;
  final int size;
}

class FileWriter
{
  FileWriter._(this._file, this.path);

  final RandomAccessFile _file;
  final String path;
  int bytesWritten = 0;

  static Future<FileWriter> open(String path) async
  {
    final file = await File(path).open(mode: FileMode.write);
    Ver("Created file: $path");
    return FileWriter._(file, path);
  }

  Future<void> write(Uint8List data, int length) async
  {
    if (length <= 0) return;
    await _file.writeFrom(data, 0, length);
    bytesWritten += length;
  }

  Future<void> close() async
  {
    await _file.flush();
    await _file.close();
  }

  Future<void> delete() async
  {
    await _file.close();
    await File(path).delete();
    Ver("Deleted file: $path");
  }
}

class FileIO
{
  static const int chunkSize = 4096;

  static Future<List<FileEntry>> collectEntries(String rootPath, {String? basePath}) async
  {
    final absoluteRoot = File(rootPath).absolute.path;
    final rootType = FileSystemEntity.typeSync(absoluteRoot);
    final effectiveBase = basePath ?? path.dirname(absoluteRoot);
    final entries = <FileEntry>[];

    if (rootType == FileSystemEntityType.notFound)
    {
      throw "Path does not exist: $rootPath";
    }

    if (rootType == FileSystemEntityType.file)
    {
      final file = File(absoluteRoot);
      final size = await file.length();
      entries.add(FileEntry(
        absolutePath: absoluteRoot,
        relativePath: _relativePath(absoluteRoot, effectiveBase),
        isDirectory: false,
        size: size,
      ));
      return entries;
    }

    await _collectDir(Directory(absoluteRoot), effectiveBase, entries);
    return entries;
  }

  static Future<void> _collectDir(Directory dir, String basePath, List<FileEntry> entries) async
  {
    final items = await dir.list(followLinks: false).toList();
    if (items.isEmpty)
    {
      entries.add(FileEntry(
        absolutePath: dir.absolute.path,
        relativePath: _relativePath(dir.absolute.path, basePath),
        isDirectory: true,
        size: 0,
      ));
      return;
    }

    for (final entity in items)
    {
      if (entity is File)
      {
        final size = await entity.length();
        entries.add(FileEntry(
          absolutePath: entity.absolute.path,
          relativePath: _relativePath(entity.absolute.path, basePath),
          isDirectory: false,
          size: size,
        ));
      }
      else if (entity is Directory)
      {
        await _collectDir(entity, basePath, entries);
      }
    }
  }

  static String _relativePath(String absolutePath, String basePath)
  {
    final rel = path.relative(absolutePath, from: basePath);
    return toProtocolPath(rel);
  }

  static String toProtocolPath(String input)
  {
    return input.replaceAll("\\", "/");
  }

  static String sanitizeRelativePath(String input)
  {
    final normalized = path.normalize(input.replaceAll("\\", "/"));
    final trimmed = normalized.startsWith("/") ? normalized.substring(1) : normalized;
    final segments = trimmed.split("/").where((segment) => segment.isNotEmpty && segment != "..").toList();
    return path.joinAll(segments);
  }

  static Future<void> ensureParentDir(String filePath) async
  {
    final parent = Directory(filePath).parent;
    if (!await parent.exists())
    {
      await parent.create(recursive: true);
      Ver("Created directory: ${parent.path}");
    }
  }

  static Future<void> ensureDir(String dirPath) async
  {
    final dir = Directory(dirPath);
    if (!await dir.exists())
    {
      await dir.create(recursive: true);
      Ver("Created directory: ${dir.path}");
    }
  }

  static bool isDirectorySync(String path) => FileSystemEntity.isDirectorySync(path);
  static bool isEmptyDirSync(String path) => isDirectorySync(path) && Directory(path).listSync().isEmpty;
}