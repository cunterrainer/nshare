import "dart:io";

import 'package:nshare/nshare.dart';

void main(List<String> args) async
{
  String ip = "127.0.0.1";
  int port = 5300;

  if (args.isEmpty)
  {
    FileIO? file;
    try
    {
      file = FileIO("a.txt");
    }
    on FileSystemException catch(e)
    {
      Err("${e.message} \"${e.path}\"");
      if (e.osError != null) VerErr("${e.osError}");
      return;
    }
    await Receive(ip, port, file.WriteChunk);
    file.Close();
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
  Ver("==========================Done===========================");
}