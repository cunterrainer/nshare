import 'dart:io';
import 'package:nshare/src/cli/cli.dart';

Future<void> main(List<String> args) async {
  exitCode = await runCli(args);
}
