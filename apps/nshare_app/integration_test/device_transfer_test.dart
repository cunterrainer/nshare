import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nshare/nshare.dart';
import 'package:nshare_app/controller.dart';
import 'package:nshare_app/main.dart';

/// Runs on Android, iOS and desktop without a host CLI, camera, or remote server.
/// These are real TLS socket, disk, queue and platform-clipboard operations.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('device queues a paged folder and verifies every received file', (
    tester,
  ) async {
    late Directory root;
    late NshareController c;
    late TransferReceiver receiver;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('nshare_device_');
      c = NshareController(
        stateDirectory: Directory('${root.path}/gui-state'),
        receiveDirectory: Directory('${root.path}/gui-output'),
      );
      await c.initialize();
      expect(c.ready, isTrue, reason: c.error);
      final identity = await DeviceIdentity.load(
        Directory('${root.path}/peer'),
      );
      receiver = await TransferReceiver.start(
        output: Directory('${root.path}/out'),
        identity: identity,
        trust: TrustStore(identity.directory),
        port: 0,
        discover: false,
        expectedFingerprint: c.identity!.fingerprint,
        approveOffer: (_) async => true,
        allowCompression: true,
      );
    });
    await tester.pumpWidget(NshareApp(controller: c));
    try {
      await tester.runAsync(() async {
        final folder = await Directory(
          '${root.path}/source/empty',
        ).create(recursive: true);
        for (var i = 0; i < 1050; i++) {
          await File(
            '${folder.parent.path}/file-$i.txt',
          ).writeAsString('device payload $i ${'abc' * 80}');
        }
        await c.setSetting('compression', true);
        await c.enqueue(
          folder.parent.path,
          '127.0.0.1',
          receiver.port,
          receiver.identity.fingerprint,
        );
        final deadline = DateTime.now().add(const Duration(minutes: 6));
        while (true) {
          final jobs = await QueueStore(c.stateDirectory!).list();
          if (jobs.single.status == JobStatus.failed) {
            fail(jobs.single.error ?? 'failed');
          }
          if (jobs.single.status == JobStatus.completed) break;
          if (DateTime.now().isAfter(deadline)) {
            throw TimeoutException('Device queue did not complete');
          }
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        for (var i = 0; i < 1050; i++) {
          expect(
            await File('${root.path}/out/source/file-$i.txt').readAsString(),
            await File('${root.path}/source/file-$i.txt').readAsString(),
          );
        }
        expect(
          await Directory('${root.path}/out/source/empty').exists(),
          isTrue,
        );
      });
      await tester.tap(find.text('Queue').last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await receiver.close();
        await c.shutdown();
        c.dispose();
        await root.delete(recursive: true);
      });
    }
  }, timeout: const Timeout(Duration(minutes: 8)));

  testWidgets('device clipboard changes only after explicit incoming approval', (
    tester,
  ) async {
    // Android only permits clipboard reads while this activity has input focus.
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: TextField(autofocus: true))),
    );
    await tester.pumpAndSettle();
    await tester.showKeyboard(find.byType(TextField));
    await tester.pump();
    Future<String?> readClipboard() async {
      for (var i = 0; i < 30; i++) {
        final data = await Clipboard.getData(Clipboard.kTextPlain);
        if (data != null) return data.text;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      return null;
    }

    await tester.runAsync(() async {
      final root = await Directory.systemTemp.createTemp(
        'nshare_clipboard_device_',
      );
      final a = await DeviceIdentity.load(Directory('${root.path}/a'));
      final b = await DeviceIdentity.load(Directory('${root.path}/b'));
      var accepted = false;
      final receiver = await TransferReceiver.start(
        output: Directory('${root.path}/out'),
        identity: b,
        trust: TrustStore(b.directory),
        expectedFingerprint: a.fingerprint,
        port: 0,
        discover: false,
        approveOffer: (_) async => false,
        approveClipboard: (offer) async {
          if (!accepted) return false;
          await Clipboard.setData(ClipboardData(text: offer.text));
          return true;
        },
      );
      try {
        await Clipboard.setData(
          const ClipboardData(text: 'keep existing clipboard'),
        );
        expect(await readClipboard(), 'keep existing clipboard');
        await expectLater(
          shareText(
            'declined text',
            '127.0.0.1',
            receiver.port,
            a,
            TrustStore(a.directory),
            expectedFingerprint: b.fingerprint,
          ),
          throwsA(isA<NshareException>()),
        );
        expect(await readClipboard(), 'keep existing clipboard');
        accepted = true;
        await shareText(
          'approved device text',
          '127.0.0.1',
          receiver.port,
          a,
          TrustStore(a.directory),
          expectedFingerprint: b.fingerprint,
        );
        expect(await readClipboard(), 'approved device text');
      } finally {
        await receiver.close();
        await root.delete(recursive: true);
      }
    });
  });
}
