import "dart:io";

import 'package:nshare/nshare.dart';

void main(List<String> args) async
{
  if (!Argv.Parse(args)) return;
  FileIO file = FileIO();

  if (Argv.mode == ProgramMode.Receiver)
  {
      await Receive(Argv.ipAddress, Argv.port, Argv.fileName);
  }
  else
  {
    await Send(Argv.ipAddress, Argv.port, Argv.fileName);
  }
  file.Close();
  Ver("==========================Done===========================");
}

enum ProgramMode { None, Sender, Receiver }

class Argv
{
  static const int defaultPort = 80;
  static const String defaultIp = "127.0.0.1";

  static int port = -1;
  static ProgramMode mode = ProgramMode.None;
  static String fileName = "";
  static String ipAddress = "";

  static bool Parse(List<String> args)
  {
    try
    {
      return ParseImpl(args);
    }
    catch (e)
    {
      Err(e.toString());
    }
    return false;
  }

  static bool ParseImpl(List<String> args)
  {
    for (String s in args)
    {
      List<String> l = s.toLowerCase().split("=");
      List<String> n = s.split("=");
      switch(l[0])
      {
        case "-h":
        case "--help":
          PrintHelp();
          return false;
        case "-v":
        case "--verbose":
          g_LoggerVerbose = true;
          break;
        case "-i":
        case "--input":
          fileName = ExtractArg(n, "a file name", "file");
          if (mode == ProgramMode.Sender) throw "You can't provide multiple input files, use a folder instead '${n[0]}=${n[1]}'";
          if (mode == ProgramMode.Receiver) throw "Can not be sender and receiver simultaneously '${n[0]}=${n[1]}'";
          mode = ProgramMode.Sender;
          break;
        case "-o":
        case "--output":
          fileName = ExtractArg(n, "a file name", "file");
          if (mode == ProgramMode.Receiver) throw "You can't provide multiple input files, use a folder instead '${n[0]}=${n[1]}'";
          if (mode == ProgramMode.Sender) throw "Can not be sender and receiver simultaneously '${n[0]}=${n[1]}'";
          mode = ProgramMode.Receiver;
          break;
        case "-ip":
        case "--ip":
          ipAddress = ExtractArg(l, "an ip address", "address");
          break;
        case "-p":
        case "--port":
          String p = ExtractArg(l, "a port", "port");
          try { port = int.parse(p); } catch(e) { throw "Port has to be a number '${n[0]}=${n[1]}'"; }
          break;
        default:
          throw "Unknown command-line option '${n[0]}'\n[ERROR] '${Platform.executable} --help' for more information";
      }
    }

    if (mode == ProgramMode.None)
    {
      mode = ProgramMode.Receiver;
      Hint("No file specified, using default config (mode: receiver, output file: '$fileName') ('--help' for more information)");
    }

    if (ipAddress.isEmpty)
    {
      ipAddress = defaultIp;
      Hint("No ip address specified, using default address: $ipAddress (localhost) ('--help' for more information)");
    }

    if (port == -1)
    {
      port = defaultPort;
      Hint("No port specified, using default port: $port ('--help' for more information)");
    }
    return true;
  }

  static String ExtractArg(List<String> l, String msg, String option)
  {
    if (l.length == 1 || l[1].isEmpty) throw "Incorrect format please provide $msg: ${l[0]}=<$option>";
    return l[1];
  }

  static void PrintHelp()
  {
    print("Usage: ${Platform.executable} [options]");
    print("Options:");
    print("  -h  | --help              Display this information");
    print("  -v  | --verbose           Print verbose output for additional information");
    print("  -i  | --input=<file>      Set the input file/folder name");
    print("  -o  | --output=<file>     Set the output file/folder name (default: 'a')");
    print("  -ip | --ip=<address>      Set the ip address (default: $defaultIp [localhost])");
    print("  -p  | --port=<port>       Set the port to listen/send to (default: $defaultPort [needs to be identical for sender / receiver])");
    print("\nIf neither an input nor an output file is specified, the default one 'a' will be used and the operating mode is receiver");
  }
}