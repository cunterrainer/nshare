library FileIO;
import "dart:io";
import "dart:typed_data";

import "Log.dart";

class FileIO
{
  late File _File;
  late RandomAccessFile _Fp;
  bool _Initialized = false;

  bool Open(String path, FileMode m)
  {
    try
    {
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

  void ReadChunk()
  {
    assert(_Initialized, "FileIO isn't initialized call Open() beforehand");
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
      Err("${e.message} \"${e.path}\"");
      if (e.osError != null) VerErr("${e.osError}");
    }
  }

  void Close()
  {
    if (_Initialized)
    {
      _Fp.flushSync();
      _Fp.closeSync();
      _Initialized = false;
    }
  }

  void Delete()
  {
    Close();
    _File.deleteSync();
  }
}