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

  bool Open(String path, FileMode m)
  {
    try
    {
      _Mode = m;
      _File = File(path);
      if (m == FileMode.read && !_File.existsSync()) throw "File doesn't exist \"$path\"";
      _Fp = _File.openSync(mode: m);
      _Initialized = true;
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
      Err("Failed to read bytes from file \"${e.path}\" reason: ${e.message}");
      if (e.osError != null) VerErr("${e.osError}");
    }
    return Uint8List(0);
  }

  void WriteChunk(Uint8List chunk, int size)
  {
    assert(_Initialized, "FileIO isn't initialized call Open() beforehand");
    try
    {
      _Fp.writeFromSync(chunk, 0, size);
    }
    on FileSystemException catch(e)
    {
      Err("Failed to write bytes into file \"${e.path}\" reason: ${e.message}");
      if (e.osError != null) VerErr("${e.osError}");
    }
  }

  void Close()
  {
    if (_Initialized)
    {
      if (_Mode == FileMode.write) _Fp.flushSync();
      _Fp.closeSync();
      _Initialized = false;
    }
  }

  void Delete()
  {
    Close();
    _File.deleteSync();
  }

  int Size() => _Fp.lengthSync();
}