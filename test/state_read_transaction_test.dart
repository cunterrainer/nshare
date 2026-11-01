import 'dart:async';
import 'dart:io';
import 'package:nshare/nshare.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  setUp(
    () async => root = await Directory.systemTemp.createTemp('state_read_'),
  );
  tearDown(() => root.delete(recursive: true));
  test(
    'read waits for replacement rather than reporting missing state as empty',
    () async {
      final store = StateStore(root, 'queue');
      await store.update((data) {
        data['jobs'] = ['retained'];
      });
      final gap = Completer<void>(), resume = Completer<void>();
      final update = store.update((data) async {
        // Model a filesystem replacement gap while the writer owns the lock.
        await store.file.delete();
        gap.complete();
        await resume.future;
        data['jobs'] = ['retained', 'new'];
      });
      await gap.future;
      var completed = false;
      final read = StateStore(root, 'queue').read().then((data) {
        completed = true;
        return data;
      });
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);
      resume.complete();
      await update;
      expect((await read)['jobs'], ['retained', 'new']);
    },
  );
  test(
    'concurrent status readers and replacements preserve every snapshot',
    () async {
      final store = StateStore(root, 'queue');
      await store.update((data) {
        data['generation'] = 0;
        data['jobs'] = List.generate(50, (i) => '$i');
      });
      await Future.wait([
        for (var i = 0; i < 100; i++)
          store.update((data) {
            data['generation'] = i + 1;
          }),
        for (var i = 0; i < 100; i++)
          StateStore(root, 'queue').read().then((data) {
            expect(data['jobs'], hasLength(50));
            expect(data['generation'], isA<int>());
          }),
      ]);
      expect((await store.read())['generation'], 100);
    },
  );
  test(
    'reading an absent profile does not create directories or state',
    () async {
      final missing = Directory('${root.path}/absent');
      expect(await StateStore(missing, 'queue').read(), {'version': 1});
      expect(await missing.exists(), isFalse);
    },
  );
}
