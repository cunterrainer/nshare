import 'package:nshare/nshare.dart';

void main(List<String> args) async
{
  String ip = "127.0.0.1";
  int port = 5300;

  if (args.isEmpty)
    await Receive(ip, port);
  else
    await Send(args[0], ip, port);
  Ver("Done");
}