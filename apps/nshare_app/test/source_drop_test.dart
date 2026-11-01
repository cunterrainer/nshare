import 'dart:io';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nshare_app/source_drop_zone.dart';

void main() {
  late Directory root;
  setUp(() async => root = await Directory.systemTemp.createTemp('drop_'));
  tearDown(() => root.delete(recursive: true));
  Future<void> mount(
    WidgetTester tester, {
    required Future<void> Function(List<String>) paths,
    required void Function(Object) error,
    bool enabled = true,
    Future<String> Function(String)? persist,
  }) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SourceDropZone(
          enabled: enabled,
          onPaths: paths,
          onError: error,
          persistFile: persist ?? (path) async => path,
          child: const Text('Send'),
        ),
      ),
    ),
  );
  Future<void> drop(WidgetTester tester, List<DropItem> files) async {
    await tester.runAsync(() async {
      tester.widget<DropTarget>(find.byType(DropTarget)).onDragDone!(
        DropDoneDetails(
          files: files,
          localPosition: Offset.zero,
          globalPosition: Offset.zero,
        ),
      );
      for (var i = 0; i < 100; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await tester.pump();
        if (find.text('Preparing dropped sources…').evaluate().isEmpty) break;
      }
    });
    await tester.pumpAndSettle();
  }

  testWidgets('drop selects multiple files and folders once without sending', (
    tester,
  ) async {
    final file = File('${root.path}/file')..writeAsStringSync('payload');
    final folder = Directory('${root.path}/folder')..createSync();
    List<String>? selected;
    await mount(
      tester,
      paths: (paths) async => selected = paths,
      error: (e) => fail('$e'),
    );
    await drop(tester, [
      DropItemFile(file.path),
      DropItemDirectory(folder.path, []),
      DropItemFile(file.path),
    ]);
    expect(selected, [file.path, folder.path]);
  });
  testWidgets('missing drop source fails atomically', (tester) async {
    final file = File('${root.path}/file')..writeAsStringSync('payload');
    Object? error;
    await mount(
      tester,
      paths: (_) async => fail('Invalid selection accepted'),
      error: (e) => error = e,
    );
    await drop(tester, [
      DropItemFile(file.path),
      DropItemFile('${root.path}/missing'),
    ]);
    expect(error, isNotNull);
  });
  testWidgets('drop refuses links', (tester) async {
    if (Platform.isWindows) return;
    final file = File('${root.path}/file')..writeAsStringSync('payload');
    final link = Link('${root.path}/link')..createSync(file.path);
    Object? error;
    await mount(
      tester,
      paths: (_) async => fail('Link accepted'),
      error: (e) => error = e,
    );
    await drop(tester, [DropItemFile(link.path)]);
    expect(error, isNotNull);
  });
  testWidgets('promised file is retained before selection', (tester) async {
    final file = File('${root.path}/promise')..writeAsStringSync('payload');
    List<String>? selected;
    await mount(
      tester,
      paths: (p) async => selected = p,
      error: (e) => fail('$e'),
      persist: (p) async => (await File(p).copy('${root.path}/retained')).path,
    );
    await drop(tester, [DropItemFile(file.path, fromPromise: true)]);
    file.deleteSync();
    expect(File(selected!.single).readAsStringSync(), 'payload');
  });
  testWidgets('empty drop reports a recoverable error', (tester) async {
    Object? error;
    await mount(
      tester,
      paths: (_) async => fail('Empty selection'),
      error: (e) => error = e,
    );
    await drop(tester, []);
    expect(error, isNotNull);
    expect(find.text('Drop files or folders here'), findsOneWidget);
  });
  testWidgets('mobile keeps picker without desktop listeners', (tester) async {
    await mount(tester, enabled: false, paths: (_) async {}, error: (_) {});
    expect(find.byType(DropTarget), findsNothing);
    expect(find.text('Send'), findsOneWidget);
  });
}
