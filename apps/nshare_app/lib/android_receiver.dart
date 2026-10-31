import 'dart:async';
import 'dart:io';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:nshare/nshare.dart';

@pragma('vm:entry-point')
void receiverTaskCallback() {
  FlutterForegroundTask.setTaskHandler(ReceiverTask());
}

class AndroidReceiver {
  static Future<void> start(Directory state, Directory output, int port) async {
    final permission =
        await FlutterForegroundTask.checkNotificationPermission();
    if (permission != NotificationPermission.granted &&
        await FlutterForegroundTask.requestNotificationPermission() !=
            NotificationPermission.granted) {
      throw const NshareException(
        'permission',
        'Notification permission is required for visible background receiving',
      );
    }
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'nshare_receiver',
        channelName: 'nshare receiver',
        channelDescription: 'Visible while LAN receiving is enabled',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(1000),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
    await FlutterForegroundTask.saveData(key: 'state', value: state.path);
    await FlutterForegroundTask.saveData(key: 'output', value: output.path);
    await FlutterForegroundTask.saveData(key: 'port', value: port);
    final result = await FlutterForegroundTask.startService(
      serviceId: 53317,
      serviceTypes: [ForegroundServiceTypes.connectedDevice],
      notificationTitle: 'nshare receiver active',
      notificationText: 'Tap to open nshare. Incoming offers require approval.',
      notificationButtons: [const NotificationButton(id: 'stop', text: 'Stop')],
      callback: receiverTaskCallback,
    );
    if (result is ServiceRequestFailure) {
      throw NshareException(
        'service',
        'Cannot start background receiver: ${result.error}',
      );
    }
  }

  static Future<void> stop() async {
    final result = await FlutterForegroundTask.stopService();
    if (result is ServiceRequestFailure) {
      throw const NshareException(
        'service',
        'Could not stop background receiver',
      );
    }
  }
}

class ReceiverTask extends TaskHandler {
  LocalService? service;
  final pending = <String, Map<String, dynamic>>{};
  final replies = <String, Completer<bool>>{};
  Future<bool> ask(String title, String details, {String? clipboard}) async {
    final id = '${DateTime.now().microsecondsSinceEpoch}:${pending.length}';
    final request = {
      'id': id,
      'title': title,
      'details': details,
      'clipboard': ?clipboard,
    };
    pending[id] = request;
    final reply = Completer<bool>();
    replies[id] = reply;
    FlutterForegroundTask.sendDataToMain(request);
    await FlutterForegroundTask.updateService(
      notificationText: 'An incoming request needs approval. Open nshare.',
    );
    try {
      return await reply.future.timeout(
        const Duration(minutes: 4),
        onTimeout: () => false,
      );
    } finally {
      pending.remove(id);
      replies.remove(id);
      await FlutterForegroundTask.updateService(
        notificationText: 'Receiver active. Tap to open nshare.',
      );
    }
  }

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    try {
      final state = Directory(
        (await FlutterForegroundTask.getData<String>(key: 'state'))!,
      );
      final output = Directory(
        (await FlutterForegroundTask.getData<String>(key: 'output'))!,
      );
      final port = (await FlutterForegroundTask.getData<int>(key: 'port'))!;
      final identity = await DeviceIdentity.load(state);
      final settings = await SettingsStore(state).load();
      service = await LocalService.start(state, identity, TrustStore(state));
      await service!.startReceiver(
        output: output,
        port: port,
        allowCompression: settings.allowCompression,
        approvePeer: (peer) => ask(
          'Verify peer fingerprint',
          'Compare the full peer fingerprint on its screen:\n${peer.fingerprint}\n\nThis device:\n${identity.fingerprint}',
        ),
        approveOffer: (offer) => ask(
          'Incoming files',
          '${offer.fileCount} files, ${offer.bytes} bytes from ${offer.peer.name}',
        ),
        approveClipboard: (offer) => ask(
          'Incoming clipboard',
          'Copy text from ${offer.peer.name}?',
          clipboard: offer.text,
        ),
        onError: (_) {
          FlutterForegroundTask.sendDataToMain({
            'error':
                'Incoming operation failed; no success acknowledgment was sent.',
          });
        },
      );
    } catch (error) {
      FlutterForegroundTask.sendDataToMain({'error': error.toString()});
      await service?.close();
      await FlutterForegroundTask.stopService();
    }
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    for (final request in pending.values) {
      FlutterForegroundTask.sendDataToMain(request);
    }
  }

  @override
  void onReceiveData(Object data) {
    if (data is Map && data['id'] is String && data['approved'] is bool) {
      final reply = replies[data['id']];
      if (reply != null && !reply.isCompleted) {
        reply.complete(data['approved'] as bool);
      }
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    for (final reply in replies.values) {
      if (!reply.isCompleted) reply.complete(false);
    }
    await service?.close();
  }

  @override
  void onNotificationButtonPressed(String id) {
    if (id == 'stop') unawaited(FlutterForegroundTask.stopService());
  }

  @override
  void onNotificationPressed() {
    FlutterForegroundTask.launchApp();
  }
}
