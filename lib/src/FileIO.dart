library FileIO;
import "dart:io";
import "dart:typed_data";

import "Log.dart";

class FileIO
{
  late File _File;
  late FileMode _Mode;
  late RandomAccessFile _Fp;
  bool _Initialized = false;
  bool _Exists = false;
  static const int Threshold = 4096; // 4kb
  final Uint8List _Buffer = Uint8List(Threshold);
  int _BufferIdx = 0;

  void _Flush()
  {
    if (_BufferIdx == 0) return;
    try
    {
      _Fp.writeFromSync(_Buffer, 0, _BufferIdx);
      _BufferIdx = 0;
    }
    on FileSystemException catch(e)
    {
      Err("Failed to write bytes into file \"${e.path}\", reason: ${e.message}");
      if (e.osError != null) VerErr("${e.osError}");
    }
  }

  bool Open(String path, FileMode m)
  {
    try
    {
      _Mode = m;
      _File = File(path);
      if (m == FileMode.read && !_File.existsSync()) throw "File doesn't exist \"$path\"";
      _Fp = _File.openSync(mode: m);
      _Initialized = true;
      _Exists = true;
      Ver("${m == FileMode.write ? "Created" : "Opened"} file: $path");
      return true;
    }
    on FileSystemException catch(e)
    {
      Err("${e.message} \"${e.path}\"");
      if (e.osError != null) VerErr("${e.osError}");
    }
    catch (e)
    {
      Err(e.toString());
    }
    return false;
  }

  Uint8List ReadChunk(int size)
  {
    assert(_Initialized, "FileIO isn't initialized call Open() beforehand");
    try
    {
      return _Fp.readSync(size);
    }
    on FileSystemException catch(e)
    {
      Err("Failed to read bytes from file \"${e.path}\", reason: ${e.message}");
      if (e.osError != null) VerErr("${e.osError}");
    }
    return Uint8List(0);
  }

  void WriteChunk(Uint8List chunk, int size)
  {
    if (size <= 0) return;
    assert(_Initialized, "FileIO isn't initialized call Open() beforehand");

    int remaining = size;
    int sourceIdx = 0;

    while (remaining > 0)
    {
      int toCopy = Threshold - _BufferIdx;
      toCopy = toCopy > remaining ? remaining : toCopy;

      _Buffer.setAll(_BufferIdx, chunk.sublist(sourceIdx, sourceIdx + toCopy));
      _BufferIdx += toCopy;
      sourceIdx += toCopy;
      remaining -= toCopy;

      if (_BufferIdx >= Threshold)
      {
        _Flush();
      }
    }
  }

  void Close()
  {
    if (_Initialized)
    {
      if (_Mode == FileMode.write)
      {
        _Flush();
        final Future<RandomAccessFile> f = _Fp.flush();
        f.then((value) => value.close());
      }
      else _Fp.close();
      _Initialized = false;
    }
  }

  void CloseSync()
  {
    if (_Initialized)
    {
      if (_Mode == FileMode.write)
      {
        _Flush();
        _Fp.flushSync();
      }
      _Fp.closeSync();
      _Initialized = false;
    }
  }

  void Delete()
  {
    String path = _File.path;
    try
    {
      CloseSync();
      _File.deleteSync();
      _Exists = false;
      Ver("Deleted file: $path");
    }
    on FileSystemException catch(e)
    {
      Err("Failed to delete file '$path', reason: ${e.message}");
      if (e.osError != null) VerErr(e.osError.toString());
    }
  }

  static List<List<dynamic>> GetDirectoryContent(String path)
  {
    final List<List<dynamic>> list = []; // first is string second bool (true if dir false if file)
    final List<Directory> stack = <Directory>[];
    final Set<Directory> visited = <Directory>{};

    final Directory rootDirectory = Directory(path);
    stack.add(rootDirectory);

    while (stack.isNotEmpty)
    {
      final currentDirectory = stack.removeLast();
      visited.add(currentDirectory);

      final contents = currentDirectory.listSync();
      if (contents.isEmpty)
        list.add([currentDirectory.path, true]);

      for (final entity in contents)
      {
        if (entity is File)
        {
          list.add([entity.path, false]);
        }
        else if (entity is Directory && !visited.contains(entity))
        {
          stack.add(entity);
        }
      }
    }
    return list;
  }

  static String ReplaceRootDir(String path, String root, bool cond)
  {
    if (!cond) return path;
    int idx = path.indexOf("/") == -1 ? path.indexOf("\\") : path.indexOf("/");
    return path.replaceRange(0, idx, root);
  }

  static void CreateDirs(String path)
  {
    try
    {
      final parentDirectory = Directory(path);
      if (!parentDirectory.existsSync())
      {
        parentDirectory.createSync(recursive: true);
        Ver("Created directory: $parentDirectory");
      }
    }
    catch (e)
    {
      Err("Failed to create directory $path");
    }
  }

  static void CreateParentDirs(String path)
  {
    try
    {
      final parentDirectory = Directory(path).parent;
      if (!parentDirectory.existsSync())
      {
        parentDirectory.createSync(recursive: true);
        Ver("Created directory: $parentDirectory");
      }
    }
    catch (e)
    {
      Err("Failed to create directory $path");
    }
  }

  int Size() => _Fp.lengthSync();
  bool Exists() => _Exists;
  static bool IsDirectory(String path) => File(path).statSync().type == FileSystemEntityType.directory;
  static bool IsEmptyDir(String path) => IsDirectory(path) && Directory(path).listSync().isEmpty;
}