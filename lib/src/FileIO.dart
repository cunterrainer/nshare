import "dart:io";
import "dart:convert";
import "dart:typed_data";

import "Log.dart";

class FileIO
{
  File? _File;
  RandomAccessFile? _Fp;

  FileIO(String path)
  {
    _File = File(path);
    _Fp = _File?.openSync(mode: FileMode.write);
  }

  void WriteChunk(Uint8List chunk, int size)
  {
    try
    {
      _Fp?.writeFromSync(chunk, 0, size);
    }
    on FileSystemException catch(e)
    {
      Err("${e.message} \"${e.path}\"");
      if (e.osError != null) VerErr("${e.osError}");
    }
  }

  void Close()
  {
    _Fp?.flushSync();
    _Fp?.closeSync();
  }
}