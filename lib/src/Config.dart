import "dart:io";

import "Log.dart";

enum ProgramMode { none, sender, receiver }

enum KeepFilesMode { ask, keep, delete }

class NshareConfig
{
  NshareConfig({
    required this.mode,
    required this.port,
    required this.discoveryPort,
    required this.bindPort,
    required this.fileName,
    required this.ipAddress,
    required this.verifyWrittenFiles,
    required this.keepFilesMode,
    required this.skipLookup,
    required this.verbose,
    required this.timer,
  });

  ProgramMode mode;
  int port;
  int discoveryPort;
  int bindPort;
  String fileName;
  String ipAddress;
  bool verifyWrittenFiles;
  KeepFilesMode keepFilesMode;
  bool skipLookup;
  bool verbose;
  bool timer;

  static NshareConfig defaults()
  {
    return NshareConfig(
      mode: ProgramMode.none,
      port: 80,
      discoveryPort: 1970,
      bindPort: 1971,
      fileName: "",
      ipAddress: "",
      verifyWrittenFiles: false,
      keepFilesMode: KeepFilesMode.ask,
      skipLookup: false,
      verbose: false,
      timer: false,
    );
  }

  static NshareConfig? fromArgs(List<String> args)
  {
    final cfg = NshareConfig.defaults();

    for (final raw in args)
    {
      final lower = raw.toLowerCase();
      final parts = raw.split("=");
      final key = parts[0];

      switch (lower.split("=")[0])
      {
        case "-h":
        case "--help":
          printHelp(cfg);
          return null;
        case "-v":
        case "--verbose":
          cfg.verbose = true;
          break;
        case "-s":
        case "--skip":
          cfg.skipLookup = true;
          break;
        case "-t":
        case "--timer":
          cfg.timer = true;
          break;
        case "-ka":
        case "--keep-all":
          _ensureReceiverMode(cfg, key);
          cfg.keepFilesMode = KeepFilesMode.keep;
          break;
        case "-kn":
        case "--keep-none":
          _ensureReceiverMode(cfg, key);
          cfg.keepFilesMode = KeepFilesMode.delete;
          break;
        case "-c":
        case "--check":
          _ensureReceiverMode(cfg, key);
          cfg.verifyWrittenFiles = true;
          break;
        case "-i":
        case "--input":
          cfg.fileName = _extractArg(parts, "a file name", "file");
          if (cfg.mode == ProgramMode.receiver)
          {
            throw "Can not be sender and receiver simultaneously '${key}=${parts[1]}'";
          }
          cfg.mode = ProgramMode.sender;
          break;
        case "-o":
        case "--output":
          cfg.fileName = _extractArg(parts, "a file name", "file");
          if (cfg.mode == ProgramMode.sender)
          {
            throw "Can not be sender and receiver simultaneously '${key}=${parts[1]}'";
          }
          cfg.mode = ProgramMode.receiver;
          break;
        case "-ip":
        case "--ip":
          if (cfg.mode == ProgramMode.receiver)
          {
            Hint("Option '$raw' is only for sender, ignored");
          }
          else
          {
            cfg.ipAddress = _extractArg(parts, "an ip address", "address");
          }
          break;
        case "-p":
        case "--port":
          cfg.port = _parsePort(parts, "port", raw);
          break;
        case "-d":
        case "--discovery":
          cfg.discoveryPort = _parsePort(parts, "port", raw);
          break;
        case "-b":
        case "--bind":
          cfg.bindPort = _parsePort(parts, "port", raw);
          break;
        default:
          throw "Unknown command-line option '$key'\n[ERROR] '${Platform.executable} --help' for more information";
      }
    }

    if (cfg.mode == ProgramMode.none)
    {
      cfg.mode = ProgramMode.receiver;
    }

    return cfg;
  }

  static int _parsePort(List<String> parts, String label, String raw)
  {
    final value = _extractArg(parts, "a port", label);
    try
    {
      return int.parse(value);
    }
    catch (e)
    {
      throw "Port has to be a number '$raw'";
    }
  }

  static void _ensureReceiverMode(NshareConfig cfg, String key)
  {
    if (cfg.mode == ProgramMode.sender)
    {
      Hint("Option '$key' is only for receiver, ignored");
    }
  }

  static String _extractArg(List<String> parts, String msg, String option)
  {
    if (parts.length == 1 || parts[1].isEmpty)
    {
      throw "Incorrect format, please provide $msg: ${parts[0]}=<$option>";
    }
    return parts[1];
  }

  void printConfig()
  {
    Ver("=============Config=============");
    Ver("Mode: ${mode == ProgramMode.receiver ? "Receiver" : "Sender"}");
    Ver("Port: $port");
    Ver("Bind port: $bindPort");
    Ver("Discovery port: $discoveryPort");
    Ver("Timer: $timer");
    Ver("File name: ${fileName.isEmpty ? "Default" : fileName}");
    Ver("Skip search: $skipLookup");
    if (mode == ProgramMode.sender) Ver("Ip address: $ipAddress");
    if (mode == ProgramMode.receiver)
    {
      final keepLabel = keepFilesMode == KeepFilesMode.ask
          ? "ask"
          : keepFilesMode == KeepFilesMode.keep
              ? "keep"
              : "delete";
      Ver("Keep files: $keepLabel");
      Ver("Verify files: $verifyWrittenFiles");
    }
    Ver("================================\n");
  }

  static void printHelp(NshareConfig cfg)
  {
    print("Usage: ${Platform.executable} [options]");
    print("Options:");
    print("  -h  | --help              Display this information");
    print("  -v  | --verbose           Print verbose output for additional information");
    print("  -i  | --input=<file>      Set the input file/folder name");
    print("  -o  | --output=<file>     Set the output file/folder name (default: file name of sender)");
    print("  -ip | --ip=<address>      Set the ip address of the receiver (default: search in local network)");
    print("  -p  | --port=<port>       Set the port to listen/send to (default: ${cfg.port} [needs to be identical for sender / receiver])");
    print("  -d  | --discovery=<port>  Set the port auto detection, needs to be the same for sender/receiver (default: ${cfg.discoveryPort})");
    print("  -b  | --bind=<port>       Set the port auto detection, needs to be the same for sender/receiver (default: ${cfg.bindPort})");
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
