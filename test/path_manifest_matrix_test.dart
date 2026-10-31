import 'dart:convert';
import 'dart:io';
import 'package:nshare/nshare.dart';
import 'package:nshare/src/storage/storage.dart';
import 'package:test/test.dart';

const emptyHash =
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';
Map<String, dynamic> offer() => Manifest([
  const ManifestEntry(0, 'safe.txt', 0, false, emptyHash),
]).toJson();
Matcher code(String value) =>
    isA<NshareException>().having((e) => e.code, 'code', value);
void main() {
  final invalidPaths = <String, String>{
    'empty': '',
    'dot': '.',
    'parent': '..',
    'root': '/',
    'absolute Unix': '/etc/passwd',
    'parent escape': '../outside',
    'nested parent': 'folder/../outside',
    'nested dot': 'folder/./file',
    'backslash traversal': '..\\outside',
    'Windows absolute': 'C:/outside',
    'UNC': '\\\\server\\share',
    'double separator': 'folder//file',
    'trailing separator': 'folder/',
    'trailing dot': 'name.',
    'trailing space': 'name ',
    'nested trailing dot': 'folder./file',
    'nested trailing space': 'folder /file',
    'colon': 'a:b',
    'wildcard': 'a*b',
    'question mark': 'a?b',
    'quote': 'a"b',
    'less than': 'a<b',
    'greater than': 'a>b',
    'pipe': 'a|b',
    'NUL': 'a\x00b',
    'tab': 'a\tb',
    'newline': 'a\nb',
    'carriage return': 'a\rb',
    'DEL': 'a\x7fb',
    'state root': '.nshare-state',
    'state root case': '.NSHARE-STATE/file',
    'byte length': 'a' * 1025,
    'UTF8 byte length': '文' * 342,
    for (final name in [
      'CON',
      'prn',
      'AUX',
      'nul',
      'COM1',
      'COM9',
      'LPT1',
      'LPT9',
    ])
      'reserved $name': name,
    for (final name in [
      'con.txt',
      'PRN.log',
      'aux.bin',
      'nul.dat',
      'com1.txt',
      'lpt9.txt',
    ])
      'reserved extension $name': 'folder/$name',
  };
  group('portable paths reject', () {
    for (final entry in invalidPaths.entries) {
      test(
        entry.key,
        () => expect(
          () => validateRelativePath(entry.value),
          throwsA(code('path')),
        ),
      );
    }
  });
  for (final name in [
    'notes.txt',
    'folder/file',
    '.hidden',
    'folder/.hidden',
    'a..b',
    'leading space/file',
    'file name.txt',
    'café.txt',
    '文件.txt',
    '📦.bin',
    'e\u0301.txt',
    'auxiliary.txt',
    'COM10.txt',
    'null.txt',
    'folder/.nshare-state/file',
    'a' * 1024,
  ]) {
    test(
      'portable path preserves ${name.length > 40 ? '1024 byte boundary' : name}',
      () => expect(validateRelativePath(name), name),
    );
  }

  final badFields = <String, (String, dynamic)>{
    'missing id': ('id', null),
    'negative id': ('id', -1),
    'fractional id': ('id', 0.5),
    'string id': ('id', '0'),
    'nonconsecutive id': ('id', 1),
    'missing path': ('path', null),
    'empty path': ('path', ''),
    'numeric path': ('path', 12),
    'missing kind': ('kind', null),
    'empty kind': ('kind', ''),
    'unknown kind': ('kind', 'link'),
    'numeric kind': ('kind', 1),
    'missing size': ('size', null),
    'negative size': ('size', -1),
    'fractional size': ('size', 0.5),
    'string size': ('size', '0'),
    'boolean size': ('size', false),
    'missing digest': ('sha256', null),
    'numeric digest': ('sha256', 0),
    'empty digest': ('sha256', ''),
    'short digest': ('sha256', 'a' * 63),
    'long digest': ('sha256', 'a' * 65),
    'nonhex digest': ('sha256', 'g' * 64),
    'uppercase digest': ('sha256', 'A' * 64),
  };
  for (final field in badFields.entries) {
    test('manifest rejects ${field.key}', () {
      final json = offer();
      (json['entries'] as List).single[field.value.$1] = field.value.$2;
      expect(() => Manifest.parse(json), throwsA(code('protocol')));
    });
  }
  for (final value in [
    null,
    false,
    'entries',
    <dynamic>[],
    [null],
    [1],
    [true],
  ]) {
    test('manifest rejects invalid entry collection ${jsonEncode(value)}', () {
      expect(
        () => Manifest.parse({'entries': value, 'transfer': 'invalid'}),
        throwsA(code('protocol')),
      );
    });
  }
  for (final value in [null, '', 'a' * 63, 'b' * 64, 1]) {
    test(
      'manifest rejects invalid transfer identity ${value.toString().length}',
      () {
        final json = offer()..['transfer'] = value;
        expect(() => Manifest.parse(json), throwsA(code('protocol')));
      },
    );
  }
  for (final paths in [
    ['same', 'same'],
    ['Same', 'same'],
    ['é', 'e\u0301'],
    ['file', 'file/child'],
  ]) {
    test('manifest rejects path conflict ${paths.join(' versus ')}', () {
      final manifest = Manifest([
        ManifestEntry(0, paths[0], 0, false, emptyHash),
        ManifestEntry(1, paths[1], 0, false, emptyHash),
      ]);
      expect(() => Manifest.parse(manifest.toJson()), throwsA(code('path')));
    });
  }
  for (final entry in [
    const ManifestEntry(0, 'dir', 1, true, ''),
    const ManifestEntry(0, 'dir', 0, true, emptyHash),
  ]) {
    test(
      'manifest rejects directory metadata size=${entry.size}',
      () => expect(
        () => Manifest.parse(Manifest([entry]).toJson()),
        throwsA(code('protocol')),
      ),
    );
  }
  test('manifest rejects more than 1024 entries', () {
    final entries = List.generate(
      1025,
      (i) => ManifestEntry(i, 'file-$i', 0, false, emptyHash),
    );
    expect(
      () => Manifest.parse(Manifest(entries).toJson()),
      throwsA(code('protocol')),
    );
  });
  test('manifest accepts exactly 1024 distinct entries', () {
    final entries = List.generate(
      1024,
      (i) => ManifestEntry(i, 'file-$i', 0, false, emptyHash),
    );
    expect(Manifest.parse(Manifest(entries).toJson()).files, 1024);
  });
  test(
    'manifest collects a changed source into a different transfer identity',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'nshare_manifest_changed_',
      );
      try {
        final source = File('${temp.path}/source')..writeAsStringSync('before');
        final before = await Manifest.collect(source.path);
        await source.writeAsString('after!');
        expect((await Manifest.collect(source.path)).id, isNot(before.id));
      } finally {
        await temp.delete(recursive: true);
      }
    },
  );
}
