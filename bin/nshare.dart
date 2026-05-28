import "dart:io";

import "package:nshare/nshare.dart";

void main(List<String> args) async
{
  final cfg = NshareConfig.fromArgs(args);
  if (cfg == null) return;

  g_LoggerVerbose = cfg.verbose;
  final stopwatch = Stopwatch();
  if (cfg.timer) stopwatch.start();

  cfg.printConfig();

  if (cfg.mode == ProgramMode.receiver)
  {
    await Receive(
      cfg.port,
      cfg.fileName,
      cfg.keepFilesMode,
      cfg.verifyWrittenFiles,
      cfg.skipLookup,
      cfg.discoveryPort,
      cfg.bindPort,
    );
  }
  else
  {
    await Send(
      cfg.ipAddress,
      cfg.port,
      cfg.fileName,
      cfg.skipLookup,
      cfg.discoveryPort,
      cfg.bindPort,
    );
  }

  Ver("==========================Done===========================");
  if (stopwatch.isRunning)
  {
    Log("Elapsed time: ${(stopwatch.elapsed.inMilliseconds / 1000.0).toStringAsFixed(3)} sec(s)");
  }
}