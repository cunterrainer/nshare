import "dart:async";
import "dart:io";
import "dart:convert";
import "dart:typed_data";

import "Log.dart";
import "Hash.dart";
import "FileIO.dart";


Future<void> SendFile(Socket socket, String path, FileIO file) async
{
    Sha256 s = Sha256();
    int bytes = file.Size();
    socket.add(ascii.encode("$path|$bytes|"));

    while (bytes > 0)
    {
      Uint8List buffer = file.ReadChunk(1024);
      s.Update(buffer);
      socket.add(buffer);
      bytes -= buffer.length;
    }

    s.Finalize();
    print(s.Hexdigest());
    socket.add(ascii.encode(s.Hexdigest()));
    await socket.flush();
    socket.destroy();
}


Future<Socket?> SetupSocketSender(String ip, int port) async
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