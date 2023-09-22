import "dart:io";

import 'package:nshare/nshare.dart';

void main(List<String> args) async
{
  String ip = "127.0.0.1";
  int port = 5300;

  if (args.isEmpty)
    await Receive(ip, port);
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