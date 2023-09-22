import 'package:nshare/nshare.dart';

void main(List<String> args) async
{
  if (args.isEmpty)
    await Receive();
  else
    await Send(args[0]);
}