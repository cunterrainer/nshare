import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nshare/nshare.dart';
import 'package:nshare_app/controller.dart';
import 'package:nshare_app/main.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late String executable;
  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('nshare_window_e2e_');
    executable = '${root.path}/${Platform.isWindows ? 'nshare.exe' : 'nshare'}';
    final build = await Process.run(
      Platform.environment['NSHARE_DART'] ?? 'dart',
      ['compile', 'exe', 'bin/nshare.dart', '-o', executable],
      workingDirectory: '../..',
    );
    if (build.exitCode != 0) {
      throw StateError('CLI compilation failed: ${build.stderr}');
    }
  });
  tearDownAll(() => root.delete(recursive: true));
  Future<void> waitFor(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 200; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (finder.evaluate().isNotEmpty) return;
    }
    throw TimeoutException(
      'Expected interface element did not appear: $finder',
    );
  }

  testWidgets('desktop window approves an incoming native CLI transfer', (
    tester,
  ) async {
    final c = NshareController(
      stateDirectory: Directory('${root.path}/gui-receiver'),
      receiveDirectory: Directory('${root.path}/gui-out'),
    );
    await c.initialize();
    expect(c.ready, isTrue, reason: c.error);
    await tester.pumpWidget(NshareApp(controller: c));
    await tester.pumpAndSettle();
    await c.startReceiver(port: 0);
    final file = File('${root.path}/from-cli.txt');
    await file.writeAsString('Approved in a real Flutter desktop window.');
    final sender = await Process.start(executable, [
      '--state-dir',
      '${root.path}/cli-sender',
      'send',
      file.path,
      '--ip',
      '127.0.0.1',
      '--port',
      '${c.service!.receiver!.port}',
      '--peer-fingerprint',
      c.identity!.fingerprint,
    ]);
    final out = sender.stdout.transform(utf8.decoder).join();
    final err = sender.stderr.transform(utf8.decoder).join();
    try {
      await waitFor(tester, find.text('Verify peer identity'));
      await tester.tap(find.text('Approve'));
      await tester.pumpAndSettle();
      await waitFor(tester, find.text('Incoming transfer'));
      await tester.tap(find.text('Approve'));
      await tester.pumpAndSettle();
      expect(await sender.exitCode, 0, reason: await err);
      expect(await out, contains('Complete:'));
      expect(
        await File('${c.receiveDirectory!.path}/from-cli.txt').readAsString(),
        await file.readAsString(),
      );
    } finally {
      sender.kill();
      await sender.exitCode;
      await c.shutdown();
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    }
  });
  testWidgets('desktop window queues and sends a file to native CLI', (
    tester,
  ) async {
    final c = NshareController(
      stateDirectory: Directory('${root.path}/gui-sender'),
      receiveDirectory: Directory('${root.path}/unused-out'),
    );
    await c.initialize();
    expect(c.ready, isTrue, reason: c.error);
    final receiverState = Directory('${root.path}/cli-receiver');
    final identity = await DeviceIdentity.load(receiverState);
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();
    final receiver = await Process.start(executable, [
      '--state-dir',
      receiverState.path,
      'receive',
      '--port',
      '$port',
      '--bind',
      '127.0.0.1',
      '--no-discover',
      '--once',
      '--accept',
      '--output',
      '${root.path}/cli-out',
      '--peer-fingerprint',
      c.identity!.fingerprint,
    ]);
    final ready = Completer<void>();
    final logs = receiver.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          if (line.startsWith('Listening on') && !ready.isCompleted) {
            ready.complete();
          }
        });
    final drained = receiver.stdout.drain<void>();
    try {
      await ready.future.timeout(const Duration(seconds: 20));
      await tester.pumpWidget(NshareApp(controller: c));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Send').last);
      await tester.pumpAndSettle();
      final file = File('${root.path}/from-window.txt');
      await file.writeAsString('Queued through the Flutter interface.');
      tester.widget<DropTarget>(find.byType(DropTarget)).onDragDone!(
        DropDoneDetails(
          files: [DropItemFile(file.path)],
          localPosition: Offset.zero,
          globalPosition: Offset.zero,
        ),
      );
      for (var i = 0; i < 100; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        if (tester
                .widget<TextField>(
                  find.widgetWithText(TextField, 'File or folder path'),
                )
                .controller!
                .text ==
            file.path) {
          break;
        }
      }
      expect(
        tester
            .widget<TextField>(
              find.widgetWithText(TextField, 'File or folder path'),
            )
            .controller!
            .text,
        file.path,
      );
      for (final field in {
        'IP address or hostname': '127.0.0.1',
        'Port': '$port',
        'Verified full SHA-256 fingerprint': identity.fingerprint,
      }.entries) {
        await tester.enterText(
          find.widgetWithText(TextField, field.key),
          field.value,
        );
      }
      await tester.ensureVisible(find.text('Add to transfer queue'));
      await tester.tap(find.text('Add to transfer queue'));
      await tester.pump();
      await waitFor(tester, find.text('Confirm target identity'));
      await tester.tap(find.text('Approve'));
      for (var i = 0; i < 200; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        final jobs = await QueueStore(c.stateDirectory!).list();
        if (jobs.isNotEmpty && jobs.single.status == JobStatus.completed) break;
      }
      expect(
        (await QueueStore(c.stateDirectory!).list()).single.status,
        JobStatus.completed,
      );
      expect(await receiver.exitCode, 0);
      expect(
        await File('${root.path}/cli-out/from-window.txt').readAsString(),
        await file.readAsString(),
      );
    } finally {
      receiver.kill();
      await receiver.exitCode;
      await logs.cancel();
      await drained;
      await c.shutdown();
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    }
  });
  testWidgets('desktop window requires approval of matching pairing code', (
    tester,
  ) async {
    final c = NshareController(
      stateDirectory: Directory('${root.path}/code-gui'),
      receiveDirectory: Directory('${root.path}/code-out'),
    );
    await c.initialize();
    await tester.pumpWidget(NshareApp(controller: c));
    await tester.pumpAndSettle();
    await c.startReceiver(port: 0);
    final sender = await DeviceIdentity.load(
      Directory('${root.path}/code-cli'),
    );
    String? clientCode;
    final pairing = pairByCode(
      '127.0.0.1',
      c.service!.receiver!.port,
      sender,
      TrustStore(sender.directory),
      approvePeer: (peer) async {
        clientCode = peer.confirmationCode;
        return true;
      },
    );
    try {
      await waitFor(tester, find.text('Verify peer identity'));
      expect(clientCode, isNotNull);
      expect(find.textContaining('Matching code: $clientCode'), findsOneWidget);
      expect(await TrustStore(sender.directory).list(), isEmpty);
      await tester.tap(find.text('Approve'));
      await tester.pumpAndSettle();
      expect((await pairing).fingerprint, c.identity!.fingerprint);
      expect(
        await TrustStore(sender.directory).list(),
        contains(c.identity!.fingerprint),
      );
    } finally {
      await c.shutdown();
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    }
  });
}
