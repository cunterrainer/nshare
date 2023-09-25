import "dart:io";

import 'package:nshare/nshare.dart';

void main(List<String> args) async
{
  if (!Argv.Parse(args)) return;

  if (Argv.mode == ProgramMode.Receiver)
  {
      await Receive(Argv.port, Argv.fileName, Argv.keepFiles, Argv.verifyWrittenFiles, Argv.skipLookup, Argv.portBind, Argv.portDiscovery);
  }
  else
  {
    await Send(Argv.ipAddress, Argv.port, Argv.fileName, Argv.skipLookup, Argv.portDiscovery, Argv.portBind);
  }
  Ver("==========================Done===========================");
  Argv.PrintElapsedTime();
}

enum ProgramMode { None, Sender, Receiver }

class Argv
{
  static const int defaultPort = 80;
  static const int defaultDiscovery = 1970;
  static const int defaultBind = 1971;

  static int port = -1;
  static int portDiscovery = 1970;
  static int portBind = 1971;
  static ProgramMode mode = ProgramMode.None;
  static String fileName = "";
  static String ipAddress = "";
  static Stopwatch clock = Stopwatch();
  static bool verifyWrittenFiles = false;
  static int keepFiles = 0; // 0 ask, 1 keep, 2 delete
  static bool skipLookup = false;

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
        case "-s":
        case "--skip":
          skipLookup = true;
          break;
        case "-t":
        case "--timer":
          clock.start();
          break;
        case "-ka":
        case "--keep-all":
          if (mode == ProgramMode.Sender) Hint("Option '${n[0]}' is only for receiver, ignored");
          keepFiles = 1;
          break;
        case "-kn":
        case "--keep-none":
          if (mode == ProgramMode.Sender) Hint("Option '${n[0]}' is only for receiver, ignored");
          keepFiles = 2;
          break;
        case "-c":
        case "--check":
          if (mode == ProgramMode.Sender) Hint("Option '${n[0]}' is only for receiver, ignored");
          verifyWrittenFiles = true;
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
          if (mode == ProgramMode.Receiver) Hint("Option '$s' is only for sender, ignored");
          else ipAddress = ExtractArg(l, "an ip address", "address");
          break;
        case "-p":
        case "--port":
          String p = ExtractArg(l, "a port", "port");
          try { port = int.parse(p); } catch(e) { throw "Port has to be a number '${n[0]}=${n[1]}'"; }
          break;
        case "-d":
        case "--discovery":
          String p = ExtractArg(l, "a port", "port");
          try { portDiscovery = int.parse(p); } catch(e) { throw "Port has to be a number '${n[0]}=${n[1]}'"; }
          break;
        case "-b":
        case "--bind":
          String p = ExtractArg(l, "a port", "port");
          try { portBind = int.parse(p); } catch(e) { throw "Port has to be a number '${n[0]}=${n[1]}'"; }
          break;
        default:
          throw "Unknown command-line option '${n[0]}'\n[ERROR] '${Platform.executable} --help' for more information";
      }
    }

    if (mode == ProgramMode.None)
    {
      mode = ProgramMode.Receiver;
      Hint("No file specified, using default config (mode: receiver, output file: file name) ('--help' for more information)");
    }

    if (ipAddress.isEmpty && mode == ProgramMode.Sender)
    {
      //ipAddress = defaultIp;
      Hint("No ip address specified, using default address: $ipAddress (localhost) ('--help' for more information)");
    }

    if (port == -1)
    {
      port = defaultPort;
      Hint("No port specified, using default port: $port ('--help' for more information)");
    }
    PrintConfig();
    return true;
  }

  static String ExtractArg(List<String> l, String msg, String option)
  {
    if (l.length == 1 || l[1].isEmpty) throw "Incorrect format, please provide $msg: ${l[0]}=<$option>";
    return l[1];
  }

  static void PrintElapsedTime()
  {
    if (!clock.isRunning) return;
    Log("Elapsed time: ${(clock.elapsed.inMilliseconds / 1000.0).toStringAsFixed(3)} sec(s)");
  }

  static void PrintConfig()
  {
    // clock, written files, keepfiles
    Ver("=============Config=============");
    Ver("Mode: ${mode == ProgramMode.Receiver ? "Receiver" : "Sender"}");
    Ver("Port: $port");
    Ver("Timer: ${clock.isRunning}");
    Ver("File name: ${fileName.isEmpty ? "Default" : fileName}");
    Ver("Skip search: $skipLookup");
    if (mode == ProgramMode.Sender) Ver("Ip address: $ipAddress");
    if (mode == ProgramMode.Receiver)
    {
      Ver("Keep files: ${keepFiles == 0 ? "ask" : keepFiles == 1}");
      Ver("Verify files: $verifyWrittenFiles");
    }
    Ver("================================\n");
  }

  static void PrintHelp()
  {
    print("Usage: ${Platform.executable} [options]");
    print("Options:");
    print("  -h  | --help              Display this information");
    print("  -v  | --verbose           Print verbose output for additional information");
    print("  -i  | --input=<file>      Set the input file/folder name");
    print("  -o  | --output=<file>     Set the output file/folder name (default: file name of sender)");
    print("  -ip | --ip=<address>      Set the ip address of the receiver (default: search in local network)");
    print("  -p  | --port=<port>       Set the port to listen/send to (default: $defaultPort [needs to be identical for sender / receiver])");
    print("  -d  | --discovery=<port>  Set the port auto detection, needs to be the same for sender/receiver (default: $defaultDiscovery)");
    print("  -b  | --bind=<port>       Set the port auto detection, needs to be the same for sender/receiver (default: $defaultBind)");
    print("  -t  | --timer             Measure execution time");
    print("  -ka | --keep-all          Keep files if the checksum doesn't match (default: ask every time)");
    print("  -kn | --keep-none         Delete files if the checksum doesn't match (default: ask every time)");
    print("  -c  | --check             After receiving and writing the files check them again for integrity corruption");
    print("  -s  | --skip              Skip search for devices in local network (needs to be set for sender and receiver)");
    print("\nIf neither an input nor an output file is specified, the default one will be used and the operating mode is receiver");
    print("In case you encounter problems related to the ports while looking for the receiver in you local network");
    print("try to set the discovery (--discovery) and the bind (--bind) port manually");
  }
}