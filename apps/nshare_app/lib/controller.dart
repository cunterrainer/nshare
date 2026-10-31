import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'android_receiver.dart';
import 'package:nshare/nshare.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class NshareController extends ChangeNotifier {
  NshareController({this.stateDirectory, this.receiveDirectory});
  Directory? stateDirectory, receiveDirectory;
  DeviceIdentity? identity;
  AppSettings settings = const AppSettings();
  ConflictPolicy conflictPolicy = ConflictPolicy.refuse;
  List<DiscoveredDevice> devices = [];
  List<TransferJob> jobs = [];
  LocalService? service;
  Map<String, dynamic>? externalStatus;
  String? error;
  bool busy = false, ready = false, searching = false;
  TransferProgress? progress;
  PairingInvitation? invitation;
  Future<bool> Function(String title, String details)? confirm;
  Future<bool> Function(ClipboardOffer offer)? confirmClipboard;
  Timer? _refresh, _discoveryRefresh;
  bool foreground = true;
  bool _disposed = false;
  bool _handoff = false;
  final _dialogs = <String>{};
  Future<void> Function(bool)? changeStartup;
  Future<void> _taskMessage(Object data) async {
    if (data is! Map) return;
    if (data['error'] is String) {
      error = data['error'] as String;
      notify();
      return;
    }
    final id = data['id'];
    if (id is! String || !_dialogs.add(id)) return;
    var accepted = false;
    try {
      if (data['clipboard'] is String) {
        accepted =
            await confirmClipboard?.call(
              ClipboardOffer(
                const PeerIdentity('paired device', ''),
                data['clipboard'] as String,
                id,
              ),
            ) ??
            false;
      } else {
        accepted =
            await confirm?.call(
              data['title'].toString(),
              data['details'].toString(),
            ) ??
            false;
      }
      FlutterForegroundTask.sendDataToTask({'id': id, 'approved': accepted});
    } finally {
      Future<void>.delayed(
        const Duration(minutes: 5),
        () => _dialogs.remove(id),
      );
    }
  }

  bool get mobile => !kIsWeb && (Platform.isAndroid || Platform.isIOS);
  bool get receiving =>
      service?.receiver != null || externalStatus?['receiverPort'] != null;
  String get receiverDescription => receiving
      ? 'Listening on port ${service?.receiver?.port ?? externalStatus?['receiverPort']}'
      : 'Receiver stopped';
  Future<void> initialize() async {
    try {
      if (Platform.isAndroid) {
        FlutterForegroundTask.addTaskDataCallback(_taskMessage);
      }
      stateDirectory ??= mobile
          ? Directory(
              p.join((await getApplicationSupportDirectory()).path, 'nshare'),
            )
          : defaultStateDirectory();
      receiveDirectory ??= Directory(
        p.join(
          (await getApplicationDocumentsDirectory()).path,
          'nshare-received',
        ),
      );
      final uiState = await StateStore(stateDirectory!, 'ui').read();
      conflictPolicy = ConflictPolicy.values.byName(
        uiState['conflict'] as String? ?? 'refuse',
      );
      identity = await DeviceIdentity.load(stateDirectory!);
      settings = await SettingsStore(stateDirectory!).load();
      await _ownOrAttach();
      ready = true;
      _refresh = Timer.periodic(
        const Duration(seconds: 1),
        (_) => unawaited(refresh()),
      );
      _discoveryRefresh = Timer.periodic(const Duration(seconds: 15), (_) {
        if (foreground && !searching) unawaited(search());
      });
      await refresh();
    } catch (e) {
      error = e.toString();
    }
    notify();
  }

  Future<void> _ownOrAttach() async {
    try {
      service = await LocalService.start(
        stateDirectory!,
        identity!,
        TrustStore(stateDirectory!),
        onProgress: (value) {
          progress = value;
          notify();
        },
      );
      externalStatus = null;
    } on NshareException catch (e) {
      if (e.code != 'busy') rethrow;
      externalStatus = await LocalServiceClient(stateDirectory!).status();
    }
  }

  void notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> refresh() async {
    if (!ready || _disposed || _handoff) return;
    try {
      jobs = await QueueStore(stateDirectory!).list();
      if (service?.isClosed == true) service = null;
      if (service == null) {
        try {
          externalStatus = await LocalServiceClient(stateDirectory!).status();
        } catch (_) {
          externalStatus = null;
          await _ownOrAttach();
        }
      }
    } catch (e) {
      error = e.toString();
    }
    notify();
  }

  Future<void> perform(Future<void> Function() action) async {
    if (busy) return;
    busy = true;
    error = null;
    notify();
    try {
      await action();
    } catch (e) {
      error = e.toString();
    } finally {
      busy = false;
      notify();
    }
  }

  Future<void> search() async {
    if (searching) return;
    searching = true;
    notify();
    try {
      devices = (await discoverNearby(
        onDiagnostic: (message) {
          error = message;
        },
      )).where((d) => d.fingerprint != identity?.fingerprint).toList();
      final known = await TrustStore(stateDirectory!).list();
      for (final peer in known.entries) {
        if (devices.any((d) => d.fingerprint == peer.key) ||
            peer.key == identity?.fingerprint) {
          continue;
        }
        final data = peer.value as Map;
        for (final endpoint in data['endpoints'] as List? ?? []) {
          final text = endpoint.toString();
          final split = text.lastIndexOf(':');
          if (split < 1) {
            continue;
          }
          final port = int.tryParse(text.substring(split + 1));
          if (port == null) continue;
          devices.add(
            DiscoveredDevice(
              data['name'].toString(),
              peer.key,
              text.substring(0, split),
              port,
              remembered: true,
            ),
          );
          break;
        }
      }
    } catch (e) {
      error = e.toString();
    } finally {
      searching = false;
      notify();
    }
  }

  Future<bool> _approve(PeerIdentity peer) async =>
      await confirm?.call(
        'Verify peer identity',
        'Compare the complete fingerprint on the other device before approving.\n\nPeer: ${peer.fingerprint}\n\nThis device: ${identity!.fingerprint}',
      ) ??
      false;
  Future<void> startReceiver({int port = 53317}) async {
    if (Platform.isAndroid && settings.receiveInBackground) {
      _handoff = true;
      try {
        await service?.close();
        service = null;
        await AndroidReceiver.start(stateDirectory!, receiveDirectory!, port);
        for (var i = 0; i < 60; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          try {
            final status = await LocalServiceClient(stateDirectory!).status();
            if (status['receiverPort'] != null) {
              externalStatus = status;
              notify();
              return;
            }
          } catch (_) {}
        }
        throw const NshareException(
          'service',
          'Background receiver did not become reachable',
        );
      } catch (_) {
        if (await FlutterForegroundTask.isRunningService) {
          await AndroidReceiver.stop();
        }
        await _ownOrAttach();
        rethrow;
      } finally {
        _handoff = false;
      }
    }

    if (service == null) {
      throw const NshareException(
        'busy',
        'The receiver is owned by another application. Stop that service first.',
      );
    }
    await service!.startReceiver(
      output: receiveDirectory!,
      port: port,
      approvePeer: _approve,
      allowCompression: settings.allowCompression,
      conflict: conflictPolicy,
      approveOffer: (offer) async =>
          await confirm?.call(
            'Incoming transfer',
            '${offer.fileCount} files, ${offer.bytes} bytes from ${offer.peer.name}.\nDestination: ${receiveDirectory!.path}',
          ) ??
          false,
      approveClipboard: (offer) async =>
          await confirmClipboard?.call(offer) ?? false,
      onProgress: (value) {
        progress = value;
        notify();
      },
      onResult: (_) {
        unawaited(refresh());
      },
      onError: (e) {
        error = e.toString();
        notify();
      },
    );
    notify();
  }

  Future<void> stopReceiver() async {
    if (Platform.isAndroid && await FlutterForegroundTask.isRunningService) {
      _handoff = true;
      try {
        await AndroidReceiver.stop();
        externalStatus = null;
        for (var i = 0; i < 30; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          try {
            await LocalServiceClient(stateDirectory!).status();
          } catch (_) {
            break;
          }
        }
        await _ownOrAttach();
      } finally {
        _handoff = false;
      }
      notify();
      return;
    }
    if (service != null) {
      await service!.stopReceiver();
    } else {
      await LocalServiceClient(stateDirectory!).stop();
      externalStatus = null;
    }
    notify();
  }

  Future<void> setConflictPolicy(ConflictPolicy value) async {
    if (receiving) {
      throw const NshareException(
        'busy',
        'Stop receiving before changing file policy',
      );
    }
    await StateStore(stateDirectory!, 'ui').update((data) {
      data['conflict'] = value.name;
    });
    conflictPolicy = value;
    notify();
  }

  Future<void> setReceiveDirectory(Directory directory) async {
    if (receiving) {
      throw const NshareException(
        'busy',
        'Stop receiving before changing destination',
      );
    }
    final path = p.normalize(p.absolute(directory.path));
    await StateStore(stateDirectory!, 'ui').update((data) {
      data['output'] = path;
    });
    receiveDirectory = Directory(path);
    notify();
  }

  Future<String> persistPickerFile(String path) async {
    final imports = Directory(
      p.join((await getApplicationSupportDirectory()).path, 'nshare-imports'),
    );
    return (await stageSourceFile(File(path), imports)).path;
  }

  Future<void> enqueue(
    String source,
    String host,
    int port,
    String fingerprint,
  ) async {
    await QueueStore(
      stateDirectory!,
    ).add(source, host, port, fingerprint, compression: settings.compression);
    await refresh();
  }

  Future<void> queueAction(String id, String action, {int? position}) async {
    await QueueStore(stateDirectory!).change(id, action, position: position);
    await refresh();
  }

  Future<void> makeInvitation(String host, {int? port}) async {
    if (!receiving) {
      throw const NshareException('pairing', 'Start the receiver first');
    }
    invitation = await InvitationStore(stateDirectory!).issue(
      host,
      port ?? service?.receiver?.port ?? externalStatus!['receiverPort'] as int,
      identity!.fingerprint,
    );
    notify();
  }

  Future<void> join(String text) async {
    await joinInvitation(
      PairingInvitation.parse(text),
      identity!,
      TrustStore(stateDirectory!),
    );
    await refresh();
  }

  Future<void> sendClipboard(String host, int port, String fingerprint) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text == null) {
      throw const NshareException('clipboard', 'No text on clipboard');
    }
    await shareText(
      data!.text!,
      host,
      port,
      identity!,
      TrustStore(stateDirectory!),
      expectedFingerprint: fingerprint,
    );
  }

  Future<void> setSetting(String key, bool value) async {
    if (key == 'startAtLogin') {
      if (changeStartup == null) {
        throw const NshareException(
          'unsupported',
          'Startup control is desktop-only',
        );
      }
      await changeStartup!(value);
    }
    await SettingsStore(stateDirectory!).set(key, value);
    settings = await SettingsStore(stateDirectory!).load();
    notify();
  }

  Future<Map<String, dynamic>> trustedPeers() =>
      TrustStore(stateDirectory!).list();
  Future<void> forget(String fingerprint) =>
      TrustStore(stateDirectory!).forget(fingerprint);
  Future<void> shutdown() async {
    _refresh?.cancel();
    _discoveryRefresh?.cancel();
    await service?.close();
    service = null;
  }

  @override
  void dispose() {
    _disposed = true;
    if (Platform.isAndroid) {
      FlutterForegroundTask.removeTaskDataCallback(_taskMessage);
    }
    _refresh?.cancel();
    _discoveryRefresh?.cancel();
    unawaited(service?.close());
    super.dispose();
  }
}
