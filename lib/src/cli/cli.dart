import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import '../identity/identity.dart';
import '../transfer/transfer.dart';
import '../discovery/discovery.dart';
import '../discovery/mdns.dart';
import 'package:args/args.dart';
import '../core/models.dart';
import '../application/state.dart';
import '../application/queue.dart';
import '../application/service.dart';
import '../application/paths.dart';
import '../application/pairing.dart';
import '../application/sharing.dart';
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
      ..addFlag('compress', help: 'Override the saved compression preference')
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
      ..addFlag(
        'allow-compression',
        help: 'Allow negotiated compressed transfers',
      )
      ..addFlag('once', negatable: false)
      ..addFlag(
        'accept-clipboard',
        negatable: false,
        help: 'Explicitly accept clipboard text and write it to stdout',
      )
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
      ..addFlag('json', negatable: false)
      ..addFlag('watch', negatable: false)
      ..addFlag('remembered', negatable: false)
      ..addOption('discovery-port', defaultsTo: '1970'),
  );
  parser.addCommand(
    'trust',
    ArgParser()
      ..addFlag('help', abbr: 'h', negatable: false)
      ..addOption('forget', help: 'Remove a stored peer fingerprint'),
  );
  parser.addCommand(
    'settings',
    ArgParser()
      ..addFlag('help', abbr: 'h', negatable: false)
      ..addOption('set')
      ..addOption('value', allowed: ['true', 'false']),
  );
  parser.addCommand(
    'pair',
    ArgParser()
      ..addFlag('help', abbr: 'h', negatable: false)
      ..addOption(
        'host',
        help: 'This device address reachable from the other device',
      )
      ..addOption('port', defaultsTo: '53317')
      ..addFlag('qr', negatable: false)
      ..addOption('svg', help: 'Export invitation QR to an SVG file')
      ..addOption(
        'join',
        help: 'Invitation copied from a trusted device screen',
      ),
  );
  parser.addCommand(
    'clipboard',
    ArgParser()
      ..addFlag('help', abbr: 'h', negatable: false)
      ..addOption('ip')
      ..addOption('port', defaultsTo: '53317')
      ..addOption('peer-fingerprint')
      ..addOption('text', help: 'Omit to read UTF-8 text from stdin'),
  );
  parser.addCommand(
    'queue',
    ArgParser()
      ..addFlag('help', abbr: 'h', negatable: false)
      ..addOption(
        'action',
        allowed: [
          'add',
          'list',
          'show',
          'run',
          'pause',
          'resume',
          'cancel',
          'retry',
          'move',
          'remove',
        ],
        defaultsTo: 'list',
      )
      ..addOption('path')
      ..addOption('ip')
      ..addOption('port', defaultsTo: '53317')
      ..addOption('peer-fingerprint')
      ..addOption('id')
      ..addOption('position')
      ..addFlag('compress')
      ..addFlag('watch', negatable: false)
      ..addFlag('json', negatable: false),
  );
  parser.addCommand(
    'service',
    ArgParser()
      ..addFlag('help', abbr: 'h', negatable: false)
      ..addOption(
        'action',
        allowed: ['run', 'start', 'status', 'stop'],
        defaultsTo: 'status',
      )
      ..addOption('output', defaultsTo: './downloads')
      ..addOption('port', defaultsTo: '53317')
      ..addOption('peer-fingerprint')
      ..addFlag('accept', negatable: false)
      ..addFlag('allow-compression'),
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
        'Usage: nshare [global options] <send|receive|devices|trust|settings|pair|clipboard|queue|service> [options]\n'
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
      if (addresses.isEmpty) {
        stderr.writeln('No local network addresses found.');
      }
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
      args['state-dir'] as String? ?? defaultStateDirectory().path,
    );
    final settingsStore = SettingsStore(directory);
    if (command.name == 'settings') {
      final key = command['set'] as String?;
      final value = command['value'] as String?;
      if ((key == null) != (value == null)) {
        throw const NshareException('usage', 'Supply both --set and --value');
      }
      if (key != null) await settingsStore.set(key, value == 'true');
      stdout.writeln(jsonEncode((await settingsStore.load()).toJson()));
      return 0;
    }
    if (command.name == 'service' &&
        ['status', 'stop', 'start'].contains(command['action'])) {
      final client = LocalServiceClient(directory);
      if (command['action'] == 'stop') {
        await client.stop();
        return 0;
      }
      if (command['action'] == 'status') {
        stdout.writeln(jsonEncode(await client.status()));
        return 0;
      }
      final executable = Platform.resolvedExecutable;
      final script = Platform.script.toFilePath();
      final childArgs = [
        if (script.endsWith('.dart')) script,
        '--state-dir',
        directory.absolute.path,
        'service',
        '--action',
        'run',
        '--output',
        Directory(command['output'] as String).absolute.path,
        '--port',
        command['port'] as String,
        if (command['accept'] as bool) '--accept',
        if (command.wasParsed('allow-compression'))
          (command['allow-compression'] as bool
              ? '--allow-compression'
              : '--no-allow-compression'),
        if (command['peer-fingerprint'] != null) ...[
          '--peer-fingerprint',
          command['peer-fingerprint'] as String,
        ],
      ];
      await Process.start(
        executable,
        childArgs,
        mode: ProcessStartMode.detached,
      );
      for (var attempt = 0; attempt < 40; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        try {
          final status = await client.status();
          if (status['receiverPort'] != null) {
            stdout.writeln(jsonEncode(status));
            return 0;
          }
        } catch (_) {}
      }
      throw const NshareException(
        'service',
        'Service failed to become ready; run service --action run for diagnostics',
      );
    }
    final settings = await settingsStore.load();
    final identity = await DeviceIdentity.load(directory);
    final trust = TrustStore(directory);
    if (command.name == 'queue') {
      final store = QueueStore(directory);
      final action = command['action'] as String;
      if (action == 'events' ||
          (action == 'list' && command['watch'] as bool)) {
        final cancelled = CancellationToken();
        final signal = ProcessSignal.sigint.watch().listen(
          (_) => cancelled.cancel(),
        );
        String? previous;
        try {
          while (!cancelled.isCancelled) {
            final json = jsonEncode({
              'event': 'queue',
              'jobs': (await store.list()).map((j) => j.toJson()).toList(),
            });
            if (json != previous) {
              stdout.writeln(json);
              previous = json;
            }
            await Future.any([
              Future<void>.delayed(const Duration(milliseconds: 250)),
              cancelled.whenCancelled,
            ]);
          }
        } finally {
          await signal.cancel();
        }
        return 130;
      }
      if (action == 'add') {
        final path = command['path'] as String?;
        final host = command['ip'] as String?;
        final pin = command['peer-fingerprint'] as String?;
        if (path == null || host == null || pin == null) {
          throw const NshareException(
            'usage',
            'Queue add requires --path, --ip and a verified --peer-fingerprint',
          );
        }
        final job = await store.add(
          path,
          host,
          parsePort(command['port'] as String),
          _fingerprint(pin),
          compression: command.wasParsed('compress')
              ? command['compress'] as bool
              : settings.compression,
        );
        stdout.writeln(jsonEncode(job.toJson()));
        return 0;
      }
      if (action == 'run') {
        final runner = QueueRunner(store, identity, trust);
        final signal = ProcessSignal.sigint.watch().listen(
          (_) => runner.stop(),
        );
        try {
          await runner.run(watch: command['watch'] as bool);
        } finally {
          await signal.cancel();
        }
        final failed = (await store.list()).any(
          (v) => v.status == JobStatus.failed,
        );
        return runner.stopped.isCancelled
            ? 130
            : failed
            ? 1
            : 0;
      }
      if (action != 'list' && action != 'show') {
        final id = command['id'] as String?;
        if (id == null) throw const NshareException('usage', 'Supply --id');
        await store.change(
          id,
          action,
          position: int.tryParse(command['position'] as String? ?? ''),
        );
      }
      final jobs = await store.list();
      final id = command['id'] as String?;
      if (action == 'show' && (id == null || !jobs.any((v) => v.id == id))) {
        throw const NshareException('usage', 'Supply an existing --id');
      }
      stdout.writeln(
        jsonEncode(
          jobs
              .where((v) => action != 'show' || v.id == id)
              .map((v) => v.toJson())
              .toList(),
        ),
      );
      return 0;
    }
    if (command.name == 'pair') {
      final join = command['join'] as String?;
      if (join != null) {
        await joinInvitation(
          PairingInvitation.parse(join),
          identity,
          trust,
          cancellation: cancellation,
        );
        stdout.writeln('Paired.');
      } else {
        final host = command['host'] as String?;
        if (host == null) {
          throw const NshareException('usage', 'Supply --host or --join');
        }
        final invite = await InvitationStore(directory).issue(
          host,
          parsePort(command['port'] as String),
          identity.fingerprint,
        );
        stdout.writeln(invite.uri);
        if (command['qr'] as bool) stdout.write(invite.terminalQr);
        final svg = command['svg'] as String?;
        if (svg != null) await File(svg).writeAsString(invite.svg);
        stderr.writeln(
          'Expires in five minutes. Start receive with the same state directory. Receiver must verify and approve the joining peer.',
        );
      }
      return 0;
    }
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
      do {
        final devices = await discoverNearby(
          port: parsePort(command['discovery-port'] as String),
          onDiagnostic: (message) => stderr.writeln(message),
        );
        final results = <Map<String, dynamic>>[
          for (final device in devices)
            {
              'name': device.name,
              'fingerprint': device.fingerprint,
              'address': device.address,
              'port': device.port,
              'source': 'discovery',
              'verified': false,
            },
        ];
        if (command['remembered'] as bool) {
          for (final peer in (await trust.list()).entries) {
            if (devices.any((d) => d.fingerprint == peer.key)) continue;
            final data = peer.value as Map;
            for (final endpoint in data['endpoints'] as List? ?? []) {
              final text = endpoint.toString();
              final split = text.lastIndexOf(':');
              if (split < 1) continue;
              final port = int.tryParse(text.substring(split + 1));
              if (port == null) continue;
              results.add({
                'name': data['name'],
                'fingerprint': peer.key,
                'address': text.substring(0, split),
                'port': port,
                'source': 'remembered',
                'verified': false,
              });
            }
          }
        }
        if (command['json'] as bool || command['watch'] as bool) {
          stdout.writeln(jsonEncode(results));
        } else {
          for (final device in results) {
            stdout.writeln(
              '${device['fingerprint']}\t${_safe(device['name'].toString())}\t${device['address']}:${device['port']}',
            );
          }
        }
        if (results.isEmpty) {
          stderr.writeln('No receivers found. Try a direct --ip address.');
        }
        if (!(command['watch'] as bool)) return 0;
        await Future.any([
          Future<void>.delayed(const Duration(seconds: 2)),
          cancellation.whenCancelled,
        ]);
      } while (!cancellation.isCancelled);
      return 130;
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

    if (command.name == 'service') {
      final service = await LocalService.start(directory, identity, trust);
      final signal = ProcessSignal.sigint.watch().listen(
        (_) => unawaited(service.close()),
      );
      try {
        await service.startReceiver(
          output: Directory(command['output'] as String),
          port: parsePort(command['port'] as String),
          expectedFingerprint: expected,
          approvePeer: stdin.hasTerminal ? approvePeer : null,
          approveOffer: (offer) async =>
              command['accept'] as bool ||
              await terminal.confirm(
                'Accept ${offer.fileCount} files (${offer.bytes} bytes)?',
              ),
          allowCompression: command.wasParsed('allow-compression')
              ? command['allow-compression'] as bool
              : settings.allowCompression,
        );
        stderr.writeln('Listening on 0.0.0.0:${service.receiver!.port}');
        await service.done;
        return 0;
      } finally {
        await signal.cancel();
        await service.close();
      }
    }
    if (command.name == 'clipboard') {
      var text = command['text'] as String?;
      if (text == null) {
        final bytes = BytesBuilder();
        await for (final chunk in stdin) {
          if (bytes.length + chunk.length > maxClipboardBytes) {
            throw const NshareException('limit', 'Clipboard exceeds 64 KiB');
          }
          bytes.add(chunk);
        }
        text = utf8.decode(bytes.takeBytes());
      }
      if (command['ip'] == null) {
        throw const NshareException('usage', 'Supply --ip');
      }
      await shareText(
        text,
        command['ip'] as String,
        parsePort(command['port'] as String),
        identity,
        trust,
        expectedFingerprint: command['peer-fingerprint'] as String?,
        approvePeer: stdin.hasTerminal ? approvePeer : null,
        cancellation: cancellation,
      );
      stderr.writeln('Clipboard text accepted.');
      return 0;
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
      String? targetFingerprint;
      var host = command['ip'] as String?;
      var port = parsePort(command['port'] as String);
      if (host == null) {
        final device = selectDevice(
          await discoverNearby(
            port: parsePort(command['discovery-port'] as String),
          ),
          command['to'] as String?,
        );
        host = device.address;
        targetFingerprint = device.fingerprint;
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
        targetFingerprint: targetFingerprint,
        cancellation: cancellation,
        onProgress: progress,
        resume: command['resume'] as bool,
        compression: command.wasParsed('compress')
            ? command['compress'] as bool
            : settings.compression,
      );
      stdout.writeln(
        'Complete: ${result.files} verified files, ${result.skipped} skipped, ${result.bytes} bytes sent; ${result.networkBytes} network payload bytes.',
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
      allowCompression: command.wasParsed('allow-compression')
          ? command['allow-compression'] as bool
          : settings.allowCompression,
      discoveryPort: parsePort(command['discovery-port'] as String),
      conflict: ConflictPolicy.values.byName(command['conflict'] as String),
      approvePeer: stdin.hasTerminal ? approvePeer : null,
      expectedFingerprint: expected?.toLowerCase(),
      approveClipboard: command['accept-clipboard'] as bool
          ? (offer) async {
              if (stdout.hasTerminal) {
                stdout.write(_safe(offer.text));
              } else {
                stdout.write(offer.text);
              }
              return true;
            }
          : null,
      approveOffer: (offer) async =>
          command['accept'] as bool ||
          await terminal.confirm(
            'Accept ${offer.fileCount} files (${offer.bytes} bytes) from ${_safe(offer.peer.name)}?',
          ),
      onProgress: progress,
      onResult: (result) {
        (command['accept-clipboard'] as bool ? stderr : stdout).writeln(
          'Complete: ${result.files} verified files, ${result.skipped} skipped.',
        );
        if (command['once'] as bool && !stopped.isCompleted) {
          stopped.complete(0);
        }
      },
      onError: (error) {
        stderr.writeln(_safe(error.toString()));
        if (command['once'] as bool && !stopped.isCompleted) {
          stopped.complete(1);
        }
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
    return e.code == 'usage'
        ? 64
        : e.code == 'cancelled'
        ? 130
        : 1;
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

class _Terminal {
  StreamIterator<String>? _lines;
  Future<bool> confirm(String message) async {
    if (!stdin.hasTerminal) return false;
    stderr.write('$message [yes/no]: ');
    _lines ??= StreamIterator(
      stdin.transform(utf8.decoder).transform(const LineSplitter()),
    );
    if (!await _lines!.moveNext().timeout(const Duration(minutes: 5))) {
      return false;
    }
    return _lines!.current.trim().toLowerCase() == 'yes';
  }

  Future<void> close() async {
    await _lines?.cancel();
  }
}
