import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import '../core/models.dart';
import '../identity/identity.dart';
import '../protocol/protocol.dart';

const maxEntries = 1024;
final _digestPattern = RegExp(r'^[a-f0-9]{64}$');

String validateRelativePath(String value) {
  if (value.isEmpty ||
      utf8.encode(value).length > 1024 ||
      value.contains('\\') ||
      value.startsWith('/') ||
      RegExp(r'[\x00-\x1f\x7f<>:"|?*]').hasMatch(value)) {
    throw const NshareException('path', 'Invalid portable relative path');
  }
  final segments = value.split('/');
  for (final segment in segments) {
    if (segment.isEmpty ||
        segment == '.' ||
        segment == '..' ||
        segment.endsWith('.') ||
        segment.endsWith(' ') ||
        RegExp(
          r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)',
          caseSensitive: false,
        ).hasMatch(segment)) {
      throw const NshareException('path', 'Unsafe or reserved path component');
    }
  }
  if (segments.first.toLowerCase() == '.nshare-state') {
    throw const NshareException('path', 'Reserved nshare state path');
  }
  return value;
}

Future<String> hashFile(File file, {int? end}) async =>
    (await sha256.bind(file.openRead(0, end)).first).toString();
String manifestId(List<ManifestEntry> entries) => sha256
    .convert(
      utf8.encode(
        jsonEncode({
          'version': protocolVersion,
          'entries': entries.map((e) => e.toJson()).toList(),
        }),
      ),
    )
    .toString();

class ManifestEntry {
  const ManifestEntry(
    this.id,
    this.path,
    this.size,
    this.directory,
    this.hash, {
    this.source,
  });
  final int id;
  final String path;
  final int size;
  final bool directory;
  final String hash;
  final String? source;
  Map<String, dynamic> toJson() => {
    'id': id,
    'path': path,
    'size': size,
    'kind': directory ? 'directory' : 'file',
    'sha256': hash,
  };
}

class Manifest {
  Manifest(this.entries) : id = manifestId(entries);
  final List<ManifestEntry> entries;
  final String id;
  int get bytes => entries.fold(0, (a, b) => a + b.size);
  int get files => entries.where((e) => !e.directory).length;
  Map<String, dynamic> toJson() => {
    'transfer': id,
    'entries': entries.map((e) => e.toJson()).toList(),
  };

  static Future<Manifest> collect(
    String input, {
    CancellationToken? cancellation,
  }) async {
    final root = p.normalize(p.absolute(input));
    final base = p.dirname(root);
    final paths = <String>[];
    Future<void> visit(String path) async {
      cancellation?.check();
      final type = await FileSystemEntity.type(path, followLinks: false);
      if (type != FileSystemEntityType.file &&
          type != FileSystemEntityType.directory) {
        throw NshareException(
          'source',
          'Unsupported source type (links are not followed): $path',
        );
      }
      paths.add(path);
      if (paths.length > maxEntries)
        throw const NshareException(
          'limit',
          'Offer exceeds 1024 entries; split the folder',
        );
      if (type == FileSystemEntityType.directory) {
        await for (final entity in Directory(path).list(followLinks: false)) {
          await visit(entity.path);
        }
      }
    }

    await visit(root);
    paths.sort();
    final entries = <ManifestEntry>[];
    for (final source in paths) {
      cancellation?.check();
      final relative = validateRelativePath(
        p.relative(source, from: base).split(p.separator).join('/'),
      );
      final directory = await FileSystemEntity.isDirectory(source);
      entries.add(
        ManifestEntry(
          entries.length,
          relative,
          directory ? 0 : await File(source).length(),
          directory,
          directory ? '' : await hashFile(File(source)),
          source: source,
        ),
      );
    }
    final manifest = Manifest(entries);
    Manifest.parse(manifest.toJson());
    if (utf8.encode(jsonEncode(manifest.toJson())).length > maxControlBytes) {
      throw const NshareException(
        'limit',
        'Manifest exceeds metadata limit; split the folder',
      );
    }
    return manifest;
  }

  static Manifest parse(Map<String, dynamic> json) {
    final values = json['entries'];
    if (values is! List || values.isEmpty || values.length > maxEntries) {
      throw const NshareException('protocol', 'Invalid manifest entry count');
    }
    final paths = <String, bool>{};
    final entries = <ManifestEntry>[];
    for (final value in values) {
      if (value is! Map<String, dynamic>)
        throw const NshareException('protocol', 'Invalid manifest entry');
      final id = requiredInt(value, 'id', max: maxEntries);
      if (id != entries.length)
        throw const NshareException(
          'protocol',
          'Entry IDs must be consecutive',
        );
      final path = validateRelativePath(
        requiredString(value, 'path', max: 1024),
      );
      final key = path.toLowerCase();
      if (paths.containsKey(key))
        throw const NshareException(
          'path',
          'Duplicate or case-colliding manifest paths',
        );
      final kind = requiredString(value, 'kind');
      if (kind != 'file' && kind != 'directory')
        throw const NshareException('protocol', 'Unknown entry kind');
      final size = requiredInt(value, 'size');
      final hash = value['sha256'];
      if (hash is! String ||
          (kind == 'file'
              ? !_digestPattern.hasMatch(hash)
              : hash != '' || size != 0)) {
        throw const NshareException('protocol', 'Invalid entry digest or size');
      }
      paths[key] = kind == 'directory';
      entries.add(ManifestEntry(id, path, size, kind == 'directory', hash));
    }
    for (final key in paths.keys) {
      final segments = key.split('/');
      for (var i = 1; i < segments.length; i++) {
        if (paths[segments.take(i).join('/')] == false)
          throw const NshareException('path', 'File is used as a directory');
      }
    }
    final manifest = Manifest(entries);
    if (requiredString(json, 'transfer', max: 64) != manifest.id) {
      throw const NshareException('protocol', 'Manifest identity mismatch');
    }
    return manifest;
  }
}

/// Reject links in every existing component. Call before creation and finalization.
/// Destination directories must not be concurrently modified by another local user.
Future<void> assertNoLinks(String absolutePath) async {
  var current = p.normalize(p.absolute(absolutePath));
  while (true) {
    if (await FileSystemEntity.type(current, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const NshareException(
        'path',
        'Symbolic links are not allowed in destination paths',
      );
    }
    final parent = p.dirname(current);
    if (parent == current) break;
    current = parent;
  }
}

class DestinationStore {
  DestinationStore._(this.root, this.state, this.manifest, this.policy);
  final Directory root;
  final Directory state;
  final Manifest manifest;
  final ConflictPolicy policy;

  static Future<DestinationStore> open(
    Directory directory,
    Manifest manifest,
    String peer,
    ConflictPolicy policy,
  ) async {
    final root = Directory(p.normalize(p.absolute(directory.path)));
    await assertNoLinks(root.path);
    await root.create(recursive: true);
    final binding = sha256
        .convert(utf8.encode('$peer:${manifest.id}:${root.path}'))
        .toString();
    final state = Directory(p.join(root.path, '.nshare-state', binding));
    await assertNoLinks(state.path);
    await state.create(recursive: true);
    await privatePath(p.dirname(state.path), directory: true);
    await privatePath(state.path, directory: true);
    await atomicJson(File(p.join(state.path, 'manifest.json')), {
      'version': protocolVersion,
      'peer': peer,
      'root': root.path,
      ...manifest.toJson(),
    });
    final store = DestinationStore._(root, state, manifest, policy);
    for (final entry in manifest.entries) {
      await store.destination(entry);
    }
    return store;
  }

  Future<String> destination(ManifestEntry entry) async {
    final dest = p.joinAll([
      root.path,
      ...validateRelativePath(entry.path).split('/'),
    ]);
    if (!p.isWithin(root.path, dest))
      throw const NshareException('path', 'Destination escapes root');
    await assertNoLinks(dest);
    return dest;
  }

  File partial(ManifestEntry entry) =>
      File(p.join(state.path, '${entry.id}.part'));
  File receipt(ManifestEntry entry) =>
      File(p.join(state.path, '${entry.id}.done'));
  Future<bool> isFinalized(ManifestEntry entry) async {
    final dest = await destination(entry);
    if (!await receipt(entry).exists()) return false;
    if (entry.directory) return await Directory(dest).exists();
    return await File(dest).exists() &&
        await File(dest).length() == entry.size &&
        await hashFile(File(dest)) == entry.hash;
  }

  Future<void> finalize(ManifestEntry entry) async {
    final dest = await destination(entry);
    if (entry.directory) {
      await Directory(dest).create(recursive: true);
    } else {
      final part = partial(entry);
      await assertNoLinks(part.path);
      if (await part.length() != entry.size ||
          await hashFile(part) != entry.hash) {
        throw const NshareException(
          'integrity',
          'Received bytes do not match the offered file',
        );
      }
      await Directory(p.dirname(dest)).create(recursive: true);
      await assertNoLinks(dest);
      final type = await FileSystemEntity.type(dest, followLinks: false);
      if (type != FileSystemEntityType.notFound) {
        if (type != FileSystemEntityType.file ||
            policy != ConflictPolicy.overwrite) {
          throw const NshareException('conflict', 'Destination already exists');
        }
        // File.rename replaces ordinary files on supported desktop platforms.
      }
      // Persist intent first: retries rehash the actual destination before reuse,
      // including a crash between rename and acknowledgment.
      await atomicJson(receipt(entry), {
        'sha256': entry.hash,
        'size': entry.size,
      });
      await part.rename(dest);
    }
    await atomicJson(receipt(entry), {
      'sha256': entry.hash,
      'size': entry.size,
    });
  }
}
