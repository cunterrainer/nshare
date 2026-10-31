import 'dart:io';
import 'package:args/args.dart';
import '../core/models.dart';
import '../discovery/interfaces.dart';

ArgParser createParser() {
  final parser = ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false)
    ..addFlag('show-ip', negatable: false)
    ..addFlag('include-loopback', negatable: false)
    ..addOption('state-dir', help: 'Identity, trust and local state directory');
  parser.addCommand(
    'send',
    ArgParser()
      ..addFlag('help', abbr: 'h', negatable: false)
      ..addOption('ip', help: 'Receiver IP (bypasses discovery)')
      ..addOption('to', help: 'Discovered receiver fingerprint')
      ..addOption('port', defaultsTo: '53317')
      ..addOption('discovery-port', defaultsTo: '1970')
      ..addFlag('resume', defaultsTo: true)
      ..addOption(
        'peer-fingerprint',
        help: 'Previously verified peer SHA-256 fingerprint',
      ),
  );
  parser.addCommand(
    'receive',
    ArgParser()
      ..addFlag('help', abbr: 'h', negatable: false)
      ..addOption('output', abbr: 'o', defaultsTo: './downloads')
      ..addOption('bind', defaultsTo: '0.0.0.0')
      ..addOption('port', defaultsTo: '53317')
      ..addOption('discovery-port', defaultsTo: '1970')
      ..addOption(
        'conflict',
        allowed: ['refuse', 'overwrite', 'skip'],
        defaultsTo: 'refuse',
      )
      ..addFlag('discover', defaultsTo: true)
      ..addFlag('once', negatable: false)
      ..addFlag(
        'accept',
        negatable: false,
        help: 'Accept offers from authenticated peers',
      )
      ..addOption(
        'peer-fingerprint',
        help: 'Previously verified peer SHA-256 fingerprint',
      ),
  );
  parser.addCommand(
    'devices',
    ArgParser()
      ..addFlag('help', abbr: 'h', negatable: false)
      ..addOption('discovery-port', defaultsTo: '1970'),
  );
  parser.addCommand(
    'trust',
    ArgParser()
      ..addFlag('help', abbr: 'h', negatable: false)
      ..addOption('forget', help: 'Remove a stored peer fingerprint'),
  );
  return parser;
}

int parsePort(String value) {
  final port = int.tryParse(value);
  if (port == null || port < 1 || port > 65535) {
    throw const NshareException('usage', 'Port must be between 1 and 65535');
  }
  return port;
}

Future<int> runCli(List<String> arguments) async {
  final parser = createParser();
  try {
    final args = parser.parse(arguments);
    if (args['help'] as bool || arguments.isEmpty) {
      stdout.writeln(
        'nshare v2 — local network file transfer\n'
        'Usage: nshare [global options] <send|receive|devices|trust> [options]\n'
        '${parser.usage}',
      );
      return 0;
    }
    if (args['show-ip'] as bool) {
      if (args.command != null || args.rest.isNotEmpty) {
        throw const NshareException(
          'usage',
          '--show-ip is a standalone option',
        );
      }
      final addresses = await localAddresses(
        includeLoopback: args['include-loopback'] as bool,
      );
      for (final address in addresses) {
        stdout.writeln(
          '${address.interfaceName}\t${address.family}\t${address.address}',
        );
      }
      if (addresses.isEmpty)
        stderr.writeln('No local network addresses found.');
      return 0;
    }
    final command = args.command;
    if (command == null || args.rest.isNotEmpty) {
      throw const NshareException(
        'usage',
        'Choose send, receive, devices or trust',
      );
    }
    if (command['help'] as bool) {
      stdout.writeln(
        'Usage: nshare ${command.name} [options]${command.name == 'send' ? ' <path>' : ''}\n'
        '${parser.commands[command.name]!.usage}',
      );
      return 0;
    }
    // Transfer commands are wired after the v2 engine is ready.
    throw const NshareException(
      'unavailable',
      'v2 transfer engine is being installed',
    );
  } on FormatException catch (e) {
    stderr.writeln('usage: ${e.message}');
    return 64;
  } on NshareException catch (e) {
    stderr.writeln(e);
    return e.code == 'usage' ? 64 : 1;
  } on FileSystemException catch (e) {
    stderr.writeln('filesystem: ${e.message}');
    return 1;
  } on SocketException catch (e) {
    stderr.writeln('network: ${e.message}');
    return 1;
  }
}
