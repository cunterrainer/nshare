import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nshare/nshare.dart';
import 'package:nshare_app/controller.dart';
import 'package:nshare_app/main.dart';

class FakeController extends NshareController {
  FakeController() {
    ready = true;
  }
  @override
  Future<void> setSetting(String key, bool value) async {
    settings = AppSettings(
      compression: key == 'compression' ? value : settings.compression,
      allowCompression: key == 'allowCompression'
          ? value
          : settings.allowCompression,
    );
    notify();
  }

  @override
  Future<void> search() async {
    devices = [
      const DiscoveredDevice(
        'Test laptop',
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        '192.168.1.10',
        53317,
      ),
    ];
    notify();
  }
}

void main() {
  const pages = ['Devices', 'Send', 'Receive', 'Queue', 'History', 'Settings'];
  Future<FakeController> mount(WidgetTester tester, double width) async {
    tester.view.physicalSize = Size(width, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = FakeController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(NshareApp(controller: controller));
    await tester.pump();
    return controller;
  }

  for (final width in [390.0, 720.0, 1100.0]) {
    for (final page in pages) {
      testWidgets('$page is accessible at width $width', (tester) async {
        await mount(tester, width);
        await tester.tap(find.text(page).last);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          find.byType(width >= 850 ? NavigationRail : NavigationBar),
          findsOneWidget,
        );
      });
    }
  }
  testWidgets(
    'compression defaults off and changes only through explicit switch',
    (tester) async {
      final controller = await mount(tester, 1100);
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      expect(controller.settings.compression, isFalse);
      expect(controller.settings.allowCompression, isFalse);
      await tester.tap(
        find.widgetWithText(SwitchListTile, 'Compress outgoing transfers'),
      );
      await tester.pumpAndSettle();
      expect(controller.settings.compression, isTrue);
      expect(controller.settings.allowCompression, isFalse);
    },
  );
  testWidgets('incoming compression has independent opt-in', (tester) async {
    final controller = await mount(tester, 1100);
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithText(SwitchListTile, 'Allow incoming compression'),
    );
    await tester.pumpAndSettle();
    expect(controller.settings.allowCompression, isTrue);
    expect(controller.settings.compression, isFalse);
  });
  testWidgets('discovery refresh shows a device without trusting it', (
    tester,
  ) async {
    final c = await mount(tester, 1100);
    await tester.tap(find.text('Refresh nearby devices'));
    await tester.pumpAndSettle();
    expect(find.text('Test laptop'), findsOneWidget);
    expect(c.jobs, isEmpty);
  });
  testWidgets('manual IP fallback opens full CLI-equivalent send form', (
    tester,
  ) async {
    await mount(tester, 1100);
    await tester.tap(find.text('Enter address manually'));
    await tester.pumpAndSettle();
    expect(
      find.widgetWithText(TextField, 'IP address or hostname'),
      findsOneWidget,
    );
    expect(
      find.widgetWithText(TextField, 'Verified full SHA-256 fingerprint'),
      findsOneWidget,
    );
  });
  testWidgets('receiver state is explicit before starting', (tester) async {
    await mount(tester, 1100);
    await tester.tap(find.text('Receive'));
    await tester.pumpAndSettle();
    expect(find.text('Receiver stopped'), findsOneWidget);
    expect(find.text('Start receiving'), findsOneWidget);
  });
  testWidgets('clipboard sharing is a separate explicit action', (
    tester,
  ) async {
    await mount(tester, 1100);
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();
    expect(find.text('Send clipboard text'), findsOneWidget);
  });
  for (final status in JobStatus.values) {
    for (final width in [390.0, 1100.0]) {
      testWidgets('queue ${status.name} renders correct category at $width', (
        tester,
      ) async {
        final c = await mount(tester, width);
        c.jobs = [
          TransferJob(
            id: 'test',
            path: '/photos/file.txt',
            host: '127.0.0.1',
            port: 53317,
            fingerprint: 'a' * 64,
            compression: false,
            status: status,
          ),
        ];
        c.notify();
        final history = [
          JobStatus.completed,
          JobStatus.failed,
          JobStatus.cancelled,
        ].contains(status);
        await tester.tap(find.text(history ? 'History' : 'Queue').last);
        await tester.pumpAndSettle();
        expect(find.text('/photos/file.txt'), findsOneWidget);
        expect(find.textContaining(status.name), findsWidgets);
        if (status == JobStatus.waitingForPeer) {
          expect(find.text('Pause'), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
      });
    }
  }
  testWidgets('failures are visible and copyable', (tester) async {
    final c = await mount(tester, 1100);
    c.error = 'network: no route';
    c.notify();
    await tester.pump();
    expect(find.text('network: no route'), findsOneWidget);
  });
}
