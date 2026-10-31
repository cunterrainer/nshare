import 'dart:io';
import 'package:nshare/src/storage/storage.dart';
import 'package:nshare/core.dart';
import 'package:test/test.dart';

void main() {
  test('unsafe portable paths are rejected, never silently rewritten', () {
    for (final value in [
      '../a',
      '/a',
      'C:/a',
      'a/../b',
      'a\\b',
      'a//b',
      'con.txt',
      'a.',
      '.nshare-state/file',
    ]) {
      expect(
        () => validateRelativePath(value),
        throwsA(isA<NshareException>()),
        reason: value,
      );
    }
    expect(validateRelativePath('文件/notes.txt'), '文件/notes.txt');
  });
  test(
    'manifest binds hashes and safe receiver only finalizes verified bytes',
    () async {
      final temp = await Directory.systemTemp.createTemp('nshare_storage_');
      try {
        final file = File('${temp.path}/source.txt');
        await file.writeAsString('hello');
        final manifest = await Manifest.collect(file.path);
        final store = await DestinationStore.open(
          Directory('${temp.path}/out'),
          Manifest.parse(manifest.toJson()),
          'peer',
          ConflictPolicy.refuse,
        );
        final entry = manifest.entries.single;
        await store.partial(entry).writeAsString('wrong');
        await expectLater(
          store.finalize(entry),
          throwsA(isA<NshareException>()),
        );
        expect(await File('${temp.path}/out/source.txt').exists(), isFalse);
        await store.partial(entry).writeAsString('hello');
        await store.finalize(entry);
        expect(await store.isFinalized(entry), isTrue);
        await File('${temp.path}/out/source.txt').writeAsString('changed');
        expect(await store.isFinalized(entry), isFalse);
      } finally {
        await temp.delete(recursive: true);
      }
    },
  );
  test('symlink destinations are refused', () async {
    if (Platform.isWindows)
      return; // Windows link creation needs host privileges.
    final temp = await Directory.systemTemp.createTemp('nshare_links_');
    try {
      await Directory('${temp.path}/target').create();
      await Link('${temp.path}/link').create('${temp.path}/target');
      await expectLater(
        assertNoLinks('${temp.path}/link/file'),
        throwsA(isA<NshareException>()),
      );
    } finally {
      await temp.delete(recursive: true);
    }
  });
}
