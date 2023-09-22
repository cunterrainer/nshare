import "dart:io";

import 'package:nshare/nshare.dart';

void main(List<String> args) async
{
  FileIO file = FileIO();
  int port = 5300;
  String ip = "127.0.0.1";

  if (args.isEmpty)
  {
    if (file.Open("a.txt", FileMode.write))
      await Receive(ip, port, file.WriteChunk);
  }
  else
  {
    Socket? socket = await SetupSocket(args[0], ip, port);
    if (socket != null)
    {
      await SendFile(socket, args[0]);
      socket.destroy();
    }
  }
  file.Close();
  Ver("==========================Done===========================");
}