import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:unorm_dart/unorm_dart.dart' as unicode;
import '../core/models.dart';
import '../protocol/protocol.dart';
import 'storage.dart';

const maxPagedEntries = 1000000;
const maxManifestDiskBytes = 512 * 1024 * 1024;

/// A disposable JSONL manifest. Entry contents and collision indexes live on disk.
class PagedManifest extends Manifest {
  PagedManifest._(
    this.temporary,
    this._id,
    this._files,
    this._bytes,
    this.count,
  ) : super(const []);
  final Directory temporary;
  final String _id;
  final int _files, _bytes, count;
  File get spool => File(p.join(temporary.path, 'entries.jsonl'));
  @override
  String get id => _id;
  @override
  int get files => _files;
  @override
  int get bytes => _bytes;
  @override
  Map<String, dynamic> get stateJson => {
    'transfer': id,
    'entriesOnDisk': true,
    'count': count,
    'files': files,
    'bytes': bytes,
  };
  @override
  Map<String, dynamic> toJson() => throw const NshareException(
    'limit',
    'Paged manifest requires negotiated streaming',
  );
  @override
  Stream<ManifestEntry> streamEntries() async* {
    await for (final line
        in spool
            .openRead()
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      final data = jsonDecode(line) as Map<String, dynamic>;
      yield ManifestEntry(
        data['id'] as int,
        data['path'] as String,
        data['size'] as int,
        data['kind'] == 'directory',
        data['sha256'] as String,
        source: data['_source'] as String?,
      );
    }
  }

  @override
  Future<void> dispose() async {
    if (await temporary.exists()) await temporary.delete(recursive: true);
  }

  static Future<PagedManifest> collect(
    String input, {
    CancellationToken? cancellation,
  }) async {
    final builder = await _Builder.create();
    final root = p.normalize(p.absolute(input));
    final base = p.dirname(root);
    Future<void> visit(String source) async {
      cancellation?.check();
      final type = await FileSystemEntity.type(source, followLinks: false);
      if (type != FileSystemEntityType.file &&
          type != FileSystemEntityType.directory) {
        throw const NshareException(
          'source',
          'Unsupported source object; links are not followed',
        );
      }
      final directory = type == FileSystemEntityType.directory;
      final entry = ManifestEntry(
        builder.count,
        p.relative(source, from: base).split(p.separator).join('/'),
        directory ? 0 : await File(source).length(),
        directory,
        directory
            ? ''
            : await hashFile(File(source), cancellation: cancellation),
        source: source,
      );
      await builder.add(entry.toJson(), source: source);
      if (directory) {
        // Bound a single directory listing too, rather than collecting the tree.
        final children = <String>[];
        await for (final child in Directory(source).list(followLinks: false)) {
          cancellation?.check();
          if (children.length >= 100000) {
            throw const NshareException(
              'limit',
              'One directory exceeds 100000 children',
            );
          }
          children.add(child.path);
        }
        children.sort();
        for (final child in children) {
          await visit(child);
        }
      }
    }

    try {
      await visit(root);
      return await builder.finish();
    } catch (_) {
      await builder.abort();
      rethrow;
    }
  }

  Future<void> send(WireConnection wire, {bool compression = false}) async {
    wire.require('manifest-pages-v1');
    await wire.send(WireType.manifestBegin, {
      ...stateJson,
      'compression': compression,
    });
    var page = <Map<String, dynamic>>[];
    var encoded = 32;
    await for (final entry in streamEntries()) {
      final json = entry.toJson();
      final length = utf8.encode(jsonEncode(json)).length + 1;
      if (page.isNotEmpty && encoded + length > 128 * 1024) {
        await wire.send(WireType.manifestPage, {'entries': page});
        page = [];
        encoded = 32;
      }
      page.add(json);
      encoded += length;
    }
    if (page.isNotEmpty) {
      await wire.send(WireType.manifestPage, {'entries': page});
    }
    await wire.send(WireType.manifestEnd, {'transfer': id});
  }

  static Future<PagedManifest> receive(
    WireConnection wire,
    Map<String, dynamic> header,
  ) async {
    wire.require('manifest-pages-v1');
    final count = requiredInt(header, 'count', max: maxPagedEntries);
    final files = requiredInt(header, 'files', max: count);
    final bytes = requiredInt(header, 'bytes');
    final id = requiredString(header, 'transfer', max: 64);
    if (count == 0) throw const NshareException('protocol', 'Empty manifest');
    final builder = await _Builder.create();
    try {
      while (builder.count < count) {
        final page = await wire.expect(WireType.manifestPage);
        final entries = page['entries'];
        if (entries is! List ||
            entries.isEmpty ||
            entries.length > count - builder.count) {
          throw const NshareException('protocol', 'Invalid manifest page');
        }
        for (final value in entries) {
          if (value is! Map<String, dynamic>) {
            throw const NshareException('protocol', 'Invalid entry');
          }
          await builder.add(value);
        }
      }
      final end = await wire.expect(WireType.manifestEnd);
      final manifest = await builder.finish();
      if (manifest.id != id ||
          end['transfer'] != id ||
          manifest.files != files ||
          manifest.bytes != bytes) {
        await manifest.dispose();
        throw const NshareException(
          'integrity',
          'Paged manifest totals or digest differ',
        );
      }
      return manifest;
    } catch (_) {
      await builder.abort();
      rethrow;
    }
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest value) {
    this.value = value;
  }

  @override
  void close() {}
}

class _Builder {
  _Builder(this.directory, this.writer) {
    digest = sha256.startChunkedConversion(output);
    digest.add(utf8.encode('nshare-manifest-v3\n'));
  }
  final Directory directory;
  final IOSink writer;
  final output = _DigestSink();
  late final ByteConversionSink digest;
  int count = 0, files = 0, bytes = 0, metadataBytes = 0;
  bool _closed = false;
  static Future<_Builder> create() async {
    final dir = await Directory.systemTemp.createTemp('nshare_manifest_');
    await Directory(p.join(dir.path, 'index')).create();
    return _Builder(dir, File(p.join(dir.path, 'entries.jsonl')).openWrite());
  }

  Future<void> add(Map<String, dynamic> data, {String? source}) async {
    if (count >= maxPagedEntries ||
        requiredInt(data, 'id', max: maxPagedEntries) != count) {
      throw const NshareException(
        'protocol',
        'Invalid manifest entry sequence',
      );
    }
    final path = validateRelativePath(requiredString(data, 'path', max: 1024));
    final kind = requiredString(data, 'kind');
    final size = requiredInt(data, 'size');
    final hash = data['sha256'];
    if ((kind != 'file' && kind != 'directory') ||
        hash is! String ||
        (kind == 'directory'
            ? size != 0 || hash != ''
            : !RegExp(r'^[0-9a-f]{64}$').hasMatch(hash))) {
      throw const NshareException(
        'protocol',
        'Invalid manifest kind, size or digest',
      );
    }
    if (size > 0x7fffffffffffffff - bytes) {
      throw const NshareException('limit', 'Transfer size overflow');
    }
    final segments = path.split('/');
    for (var i = 1; i <= segments.length; i++) {
      final prefix = segments.take(i).join('/');
      final key = sha256
          .convert(utf8.encode(unicode.nfc(prefix).toLowerCase()))
          .toString();
      final file = File(p.join(directory.path, 'index', key));
      final last = i == segments.length;
      final isDirectory = !last || kind == 'directory';
      if (await file.exists()) {
        final previous = jsonDecode(await file.readAsString()) as Map;
        if (previous['path'] != prefix ||
            previous['directory'] != true ||
            !isDirectory ||
            (last && previous['explicit'] == true)) {
          throw const NshareException(
            'path',
            'Colliding or unsafe manifest paths',
          );
        }
      }
      if (last || !await file.exists()) {
        await file.writeAsString(
          jsonEncode({
            'path': prefix,
            'directory': isDirectory,
            'explicit': last,
          }),
        );
      }
    }
    final canonical = ManifestEntry(
      count,
      path,
      size,
      kind == 'directory',
      hash,
    ).toJson();
    final line = '${jsonEncode(canonical)}\n';
    final wireBytes = utf8.encode(line);
    metadataBytes += wireBytes.length;
    if (metadataBytes > maxManifestDiskBytes) {
      throw const NshareException('limit', 'Manifest disk quota exceeded');
    }
    digest.add(wireBytes);
    writer.writeln(jsonEncode({...canonical, '_source': ?source}));
    // Backpressure includes disk metadata, not just file payload streams.
    if (count % 128 == 0) await writer.flush();
    count++;
    bytes += size;
    if (kind == 'file') files++;
  }

  Future<PagedManifest> finish() async {
    await writer.flush();
    await writer.close();
    _closed = true;
    digest.close();
    return PagedManifest._(
      directory,
      output.value.toString(),
      files,
      bytes,
      count,
    );
  }

  Future<void> abort() async {
    try {
      if (!_closed) {
        await writer.close();
      }
    } finally {
      _closed = true;
      if (await directory.exists()) await directory.delete(recursive: true);
    }
  }
}

Future<Manifest> collectTransferManifest(
  String input, {
  CancellationToken? cancellation,
}) async {
  try {
    return await Manifest.collect(input, cancellation: cancellation);
  } on NshareException catch (error) {
    if (error.code != 'limit') rethrow;
    return PagedManifest.collect(input, cancellation: cancellation);
  }
}
