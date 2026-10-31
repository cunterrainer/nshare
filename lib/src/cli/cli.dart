import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:path/path.dart' as p;
import '../identity/identity.dart';
import '../transfer/transfer.dart';
import '../discovery/discovery.dart';
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
  final terminal = _Terminal();
  final cancellation = CancellationToken();
  StreamSubscription<ProcessSignal>? interrupt;
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
    if (command.name != 'send' && command.rest.isNotEmpty ||
        command.name == 'send' && command.rest.length != 1) {
      throw const NshareException(
        'usage',
        'send requires one path; other commands take no positional arguments',
      );
    }
    final directory = Directory(
      args['state-dir'] as String? ?? _defaultStateDirectory(),
    );
    final identity = await DeviceIdentity.load(directory);
    final trust = TrustStore(directory);
    if (command.name == 'trust') {
      final forget = command['forget'] as String?;
      if (forget != null) await trust.forget(_fingerprint(forget));
      stdout.writeln('This device: ${identity.fingerprint}');
      for (final entry in (await trust.list()).entries) {
        stdout.writeln(
          '${entry.key}\t${_safe((entry.value as Map)['name'].toString())}',
        );
      }
      return 0;
    }
    interrupt = ProcessSignal.sigint.watch().listen(
      (_) => cancellation.cancel(),
    );
    if (command.name == 'devices') {
      final devices = await discoverDevices(
        port: parsePort(command['discovery-port'] as String),
      );
      for (final device in devices) {
        stdout.writeln(
          '${device.fingerprint}\t${_safe(device.name)}\t${device.address}:${device.port}',
        );
      }
      if (devices.isEmpty)
        stderr.writeln('No receivers found. Try a direct --ip address.');
      return 0;
    }
    final expected = command['peer-fingerprint'] as String?;
    if (expected != null) _fingerprint(expected);
    Future<bool> approvePeer(PeerIdentity peer) async {
      stderr.writeln(
        'Your fingerprint: ${identity.fingerprint}\nPeer fingerprint: ${peer.fingerprint}',
      );
      return terminal.confirm(
        'Verify the full peer fingerprint on the other device. Trust this peer?',
      );
    }

    var previousProgress = DateTime.fromMillisecondsSinceEpoch(0);
    void progress(TransferProgress event) {
      final now = DateTime.now();
      if (event.phase == TransferPhase.complete ||
          now.difference(previousProgress).inMilliseconds >= 500) {
        stderr.writeln(
          '${event.phase.name}: ${_safe(event.path)} ${event.bytes}/${event.total} bytes; '
          '${event.verifiedFiles} verified; ${(event.bytesPerSecond / 1048576).toStringAsFixed(1)} MiB/s',
        );
        previousProgress = now;
      }
    }

    if (command.name == 'send') {
      if (command['ip'] != null && command['to'] != null) {
        throw const NshareException('usage', 'Choose either --ip or --to');
      }
      var host = command['ip'] as String?;
      var port = parsePort(command['port'] as String);
      if (host == null) {
        final device = selectDevice(
          await discoverDevices(
            port: parsePort(command['discovery-port'] as String),
          ),
          command['to'] as String?,
        );
        host = device.address;
        port = device.port;
      }
      final result = await sendPath(
        command.rest.single,
        host,
        port,
        identity,
        trust,
        approvePeer: stdin.hasTerminal ? approvePeer : null,
        expectedFingerprint: expected?.toLowerCase(),
        cancellation: cancellation,
        onProgress: progress,
        resume: command['resume'] as bool,
      );
      stdout.writeln(
        'Complete: ${result.files} verified files, ${result.skipped} skipped, ${result.bytes} bytes sent.',
      );
      return 0;
    }
    final stopped = Completer<int>();
    final receiver = await TransferReceiver.start(
      identity: identity,
      trust: trust,
      output: Directory(command['output'] as String),
      bind: InternetAddress(command['bind'] as String),
      port: parsePort(command['port'] as String),
      discover: command['discover'] as bool,
      discoveryPort: parsePort(command['discovery-port'] as String),
      conflict: ConflictPolicy.values.byName(command['conflict'] as String),
      approvePeer: stdin.hasTerminal ? approvePeer : null,
      expectedFingerprint: expected?.toLowerCase(),
      approveOffer: (offer) async =>
          command['accept'] as bool ||
          await terminal.confirm(
            'Accept ${offer.fileCount} files (${offer.bytes} bytes) from ${_safe(offer.peer.name)}?',
          ),
      onProgress: progress,
      onResult: (result) {
        stdout.writeln(
          'Complete: ${result.files} verified files, ${result.skipped} skipped.',
        );
        if (command['once'] as bool && !stopped.isCompleted)
          stopped.complete(0);
      },
      onError: (error) {
        stderr.writeln(_safe(error.toString()));
        if (command['once'] as bool && !stopped.isCompleted)
          stopped.complete(1);
      },
    );
    stderr.writeln(
      'Listening on ${command['bind']}:${receiver.port}\nThis device: ${identity.fingerprint}',
    );
    try {
      return await Future.any([
        stopped.future,
        cancellation.whenCancelled.then((_) => 130),
      ]);
    } finally {
      await receiver.close();
    }
  } on FormatException catch (e) {
    stderr.writeln('usage: ${e.message}');
    return 64;
  } on NshareException catch (e) {
    stderr.writeln(e);
    return e.code == 'usage' ? 64 : 1;
  } on FileSystemException catch (e) {
    stderr.writeln('filesystem: ${e.message}');
    return 1;
  } on TimeoutException {
    stderr.writeln('timeout: Operation exceeded its deadline');
    return 1;
  } on SocketException catch (e) {
    stderr.writeln('network: ${e.message}');
    return 1;
  } catch (error) {
    stderr.writeln(_safe(error.toString()));
    return 1;
  } finally {
    await interrupt?.cancel();
    await terminal.close();
  }
}

String _safe(String value) =>
    value.replaceAll(RegExp(r'[\x00-\x1f\x7f-\x9f]'), '?');
String _fingerprint(String value) {
  if (!RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(value)) {
    throw const NshareException(
      'usage',
      'Fingerprint must be 64 hexadecimal SHA-256 characters',
    );
  }
  return value.toLowerCase();
}

String _defaultStateDirectory() {
  final environment = Platform.environment;
  final base = Platform.isWindows
      ? environment['APPDATA']
      : environment['XDG_CONFIG_HOME'];
  if (base != null && base.isNotEmpty) return p.join(base, 'nshare');
  final home = environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'];
  if (home == null)
    throw const NshareException(
      'usage',
      'Set --state-dir when no home directory is available',
    );
  return p.join(home, '.config', 'nshare');
}

class _Terminal {
  StreamIterator<String>? _lines;
  Future<bool> confirm(String message) async {
    if (!stdin.hasTerminal) return false;
    stderr.write('$message [yes/no]: ');
    _lines ??= StreamIterator(
      stdin.transform(utf8.decoder).transform(const LineSplitter()),
    );
    if (!await _lines!.moveNext().timeout(const Duration(minutes: 5)))
      return false;
    return _lines!.current.trim().toLowerCase() == 'yes';
  }

  Future<void> close() async {
    await _lines?.cancel();
  }
}
