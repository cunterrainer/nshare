import 'dart:convert';
import 'dart:io';
import 'package:nshare/nshare.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  setUp(
    () async => root = await Directory.systemTemp.createTemp('nshare_state_'),
  );
  tearDown(() => root.delete(recursive: true));
  test('new settings are opt-in and loading creates no identity', () async {
    expect(
      (await SettingsStore(root).load()).toJson().values,
      everyElement(false),
    );
    expect(root.listSync(), isEmpty);
  });
  for (final key in const AppSettings().toJson().keys) {
    for (final enabled in [true, false]) {
      test('$key persists $enabled without changing other settings', () async {
        await SettingsStore(root).set(key, enabled);
        final data = (await SettingsStore(root).load()).toJson();
        expect(data[key], enabled);
        expect(
          data.entries.where((e) => e.key != key).map((e) => e.value),
          everyElement(false),
        );
      });
    }
    for (final invalid in ['true', 1, null]) {
      test('$key rejects invalid value $invalid', () {
        expect(
          () => AppSettings.fromJson({key: invalid}),
          throwsA(isA<NshareException>()),
        );
      });
    }
  }
  test('unknown settings leave persisted state unchanged', () async {
    final settings = SettingsStore(root);
    await settings.set('compression', true);
    await expectLater(
      settings.set('unknown', true),
      throwsA(isA<NshareException>()),
    );
    expect((await settings.load()).compression, isTrue);
  });
  test('concurrent store instances serialize read-modify-write', () async {
    await Future.wait(
      List.generate(
        20,
        (_) => StateStore(root, 'counter').update((data) async {
          final value = data['count'] as int? ?? 0;
          await Future<void>.delayed(Duration.zero);
          data['count'] = value + 1;
        }),
      ),
    );
    expect((await StateStore(root, 'counter').read())['count'], 20);
  });
  test('failed mutation preserves state and releases locks', () async {
    final store = StateStore(root, 'counter');
    await expectLater(
      store.update<void>((data) {
        data['count'] = 99;
        throw StateError('abort');
      }),
      throwsStateError,
    );
    await store.update((data) => data['count'] = 1);
    expect((await store.read())['count'], 1);
  });
  for (final value in [
    [],
    {'version': 99},
    {'count': 1},
  ]) {
    test('unsupported state $value fails closed', () async {
      await File('${root.path}/settings.json').writeAsString(jsonEncode(value));
      await expectLater(
        SettingsStore(root).load(),
        throwsA(isA<NshareException>()),
      );
    });
  }
}
