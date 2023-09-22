import "dart:async";
import "dart:io";
import "dart:convert";
import "dart:typed_data";

import "Log.dart";
import "Hash.dart";

void readFileSyncInChunks(String filePath, int chunkSize)
{
  print(Directory.current);
  final file = File(filePath);
  if (!file.existsSync())
    Err("File doesn't exist: [$filePath]");

  final randomAccessFile = file.openSync(mode: FileMode.read);
  Uint8List buffer = Uint8List(chunkSize);
  int bytesRead;

  Sha256 s = Sha256();
  try {
    do {
      bytesRead = randomAccessFile.readIntoSync(buffer);
      s.UpdateBinary(buffer, bytesRead);
    } while (bytesRead > 0);
  } finally {
    randomAccessFile.closeSync();
  }
  s.Finalize();
  print(s.Hexdigest());
}


Future<void> Send(String path, String ip, int port) async
{
  Ver("Sender");
  try
  {
    Socket socket = await Socket.connect(ip, port);
    Ver("Connected");

    String s = "Hello";

    print(sha256(s));
    socket.add(ascii.encode("${s.length}a|Hello"));
    await socket.flush();
    socket.destroy();
  }
  on SocketException catch(e)
  {
    Err("Failed to connect to $ip on port $port reason: ${e.message} ${e.osError ?? ""}");
  }
  on ArgumentError catch(e)
  {
    Err(e.toString());
  }
  catch(e)
  {
    Err("Unhandled exception: $e");
  }
}