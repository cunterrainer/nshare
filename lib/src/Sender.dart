import "dart:async";
import "dart:io";
import "dart:convert";
import "dart:typed_data";

import "Log.dart";
import "Hash.dart";


Future<void> SendFile(Socket socket, String path) async
{
  final File file = File(path);
  if (!file.existsSync()) { Err("File doesn't exist: \"$path\""); return; }

  try
  {
    final RandomAccessFile fp = file.openSync(mode: FileMode.read);
    int bytes = fp.lengthSync();
    Sha256 s = Sha256();

    socket.add(ascii.encode("$bytes|"));

    while (bytes > 0)
    {
      Uint8List buffer = fp.readSync(1024);
      s.Update(buffer);
      socket.add(buffer);
      bytes -= buffer.length;
    }

    fp.closeSync();
    s.Finalize();
    print(s.Hexdigest());
    socket.add(ascii.encode(s.Hexdigest()));
    await socket.flush();
    socket.destroy();
  }
  on FileSystemException catch(e)
  {
    Err("${e.message} \"${e.path}\"");
    if (e.osError != null) VerErr("${e.osError}");
  }
}


Future<Socket?> SetupSocket(String path, String ip, int port) async
{
  Ver("Sender");
  try
  {
    Socket socket = await Socket.connect(ip, port);
    Ver("Connected");
    return socket;
  }
  on SocketException catch(e)
  {
    Err("Failed to connect to $ip on port $port reason: ${e.message}");
    if (e.osError != null) VerErr("${e.osError}");
  }
  on ArgumentError catch(e)
  {
    Err(e.toString());
  }
  catch(e)
  {
    Err("Unhandled exception: $e");
  }
  return null;
}