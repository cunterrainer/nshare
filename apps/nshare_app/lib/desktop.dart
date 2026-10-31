import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import 'controller.dart';

class DesktopIntegration with WindowListener, TrayListener {
  DesktopIntegration(this.controller, {this.arguments = const []});
  final List<String> arguments;
  final NshareController controller;
  bool _quitting = false;
  Future<void> initialize() async {
    await windowManager.ensureInitialized();
    await windowManager.setPreventClose(true);
    windowManager.addListener(this);
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(title: 'nshare', minimumSize: Size(600, 500)),
      () async {
        await windowManager.show();
        await windowManager.focus();
      },
    );
    launchAtStartup.setup(
      appName: 'nshare',
      appPath: Platform.resolvedExecutable,
      args: arguments,
    );
    controller.changeStartup = (enabled) async {
      final success = enabled
          ? await launchAtStartup.enable()
          : await launchAtStartup.disable();
      if (!success) {
        throw StateError(
          'The operating system did not accept the startup preference',
        );
      }
    };
    try {
      final icon = Platform.isWindows ? 'tray.ico' : 'tray.png';
      final bytes = await rootBundle.load('assets/$icon');
      final file = File(
        p.join((await getApplicationSupportDirectory()).path, icon),
      );
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes.buffer.asUint8List());
      await trayManager.setIcon(file.path);
      trayManager.addListener(this);
      await trayManager.setContextMenu(
        Menu(
          items: [
            MenuItem(key: 'show', label: 'Open nshare'),
            MenuItem(key: 'stop', label: 'Stop receiving'),
            MenuItem.separator(),
            MenuItem(key: 'quit', label: 'Quit nshare'),
          ],
        ),
      );
    } catch (error) {
      // Do not hide a window if the host cannot provide a way to restore it.
      controller.error = 'System tray unavailable: $error';
      _trayReady = false;
      return;
    }
    _trayReady = true;
  }

  bool _trayReady = false;
  @override
  void onWindowClose() {
    if (!_quitting && _trayReady && controller.settings.receiveInBackground) {
      unawaited(windowManager.hide());
    } else {
      unawaited(quit());
    }
  }

  @override
  void onTrayIconMouseDown() {
    unawaited(show());
  }

  @override
  void onTrayIconRightMouseDown() {
    unawaited(trayManager.popUpContextMenu());
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        unawaited(show());
      case 'stop':
        unawaited(controller.perform(controller.stopReceiver));
      case 'quit':
        unawaited(quit());
    }
  }

  Future<void> show() async {
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> quit() async {
    if (_quitting) return;
    _quitting = true;
    await controller.shutdown();
    await trayManager.destroy();
    await windowManager.destroy();
  }
}
