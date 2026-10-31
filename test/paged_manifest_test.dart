import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:nshare/nshare.dart';
import 'package:nshare/src/protocol/protocol.dart';
import 'package:test/test.dart';

Future<void> withWire(
  Future<void> Function(WireConnection, WireConnection) action,
) async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final incoming = server.first;
  final sender = WireConnection(await Socket.connect('127.0.0.1', server.port));
  final receiver = WireConnection(await incoming);
  sender.extensions = {...supportedExtensions};
  receiver.extensions = {...supportedExtensions};
  try {
    await action(sender, receiver);
  } finally {
    await sender.close();
    await receiver.close();
    await server.close();
  }
}

Map<String, dynamic> entry(int id, String path) => {
  'id': id,
  'path': path,
  'size': 0,
  'kind': 'file',
  'sha256': sha256.convert([]).toString(),
};
Map<String, dynamic> header(List<Map<String, dynamic>> entries) => {
  'transfer': sha256
      .convert(
        utf8.encode(
          'nshare-manifest-v3\n${entries.map((e) => '${jsonEncode(e)}\n').join()}',
        ),
      )
      .toString(),
  'count': entries.length,
  'files': entries.where((e) => e['kind'] == 'file').length,
  'bytes': entries.fold<int>(
    0,
    (a, b) => a + (b['size'] is int ? b['size'] as int : 0),
  ),
};
Future<void> receiveEntries(
  List<Map<String, dynamic>> entries, {
  Map<String, dynamic>? overrides,
}) => withWire((out, input) async {
  final meta = {...header(entries), ...?overrides};
  final result = PagedManifest.receive(input, meta);
  // Attach rejection handler before sending to avoid unhandled async errors.
  final checked = expectLater(result, throwsA(isA<NshareException>()));
  await out.send(WireType.manifestPage, {'entries': entries});
  await out.send(WireType.manifestEnd, {'transfer': meta['transfer']});
  await checked;
});
void main() {
  late Directory root;
  setUp(
    () async => root = await Directory.systemTemp.createTemp('nshare_paged_'),
  );
  tearDown(() => root.delete(recursive: true));
  for (final path in [
    '../x',
    '/x',
    'C:/x',
    'a\\b',
    'a//b',
    'a/./b',
    'a/../b',
    '.nshare-state/x',
    'CON',
    'NUL.txt',
    'a.',
    'a ',
    'a\u0000b',
  ]) {
    test(
      'paged validation rejects unsafe path $path',
      () => receiveEntries([entry(0, path)]),
    );
  }
  for (final paths in [
    ['a', 'a'],
    ['A', 'a'],
    ['é', 'e\u0301'],
    ['a', 'a/b'],
    ['a/b', 'a'],
    ['Dir/a', 'dir/b'],
  ]) {
    test(
      'disk index rejects collision $paths',
      () => receiveEntries([
        for (var i = 0; i < paths.length; i++) entry(i, paths[i]),
      ]),
    );
  }
  for (final change in <Map<String, dynamic>>[
    {'id': 1},
    {'id': -1},
    {'size': -1},
    {'size': '1'},
    {'kind': 'link'},
    {'sha256': 'bad'},
    {'kind': 'directory', 'size': 1, 'sha256': ''},
    {'path': 3},
    {'sha256': null},
  ]) {
    test(
      'paged entry rejects $change',
      () => receiveEntries([
        {...entry(0, 'a'), ...change},
      ]),
    );
  }
  for (final change in <Map<String, dynamic>>[
    {'files': 0},
    {'bytes': 1},
    {'transfer': '0' * 64},
  ]) {
    test(
      'paged manifest rejects incorrect summary $change',
      () => receiveEntries([entry(0, 'a')], overrides: change),
    );
  }
  for (final count in [0, -1, 1000001]) {
    test(
      'paged manifest rejects entry count $count',
      () => withWire((out, input) async {
        await expectLater(
          PagedManifest.receive(input, {
            'count': count,
            'files': 0,
            'bytes': 0,
            'transfer': '0' * 64,
          }),
          throwsA(isA<NshareException>()),
        );
      }),
    );
  }
  test(
    'paged collection has deterministic identity and is disposable',
    () async {
      final tree = Directory('${root.path}/tree')..createSync();
      File('${tree.path}/b').writeAsStringSync('b');
      File('${tree.path}/a').writeAsStringSync('a');
      final first = await PagedManifest.collect(tree.path);
      final second = await PagedManifest.collect(tree.path);
      try {
        expect(first.id, second.id);
        expect(first.files, 2);
        expect(first.bytes, 2);
        expect((await first.streamEntries().toList()).map((e) => e.path), [
          'tree',
          'tree/a',
          'tree/b',
        ]);
      } finally {
        await first.dispose();
        await second.dispose();
      }
      expect(await first.temporary.exists(), isFalse);
    },
  );
  test('cancelled collection stops and cleans up', () async {
    final token = CancellationToken()..cancel();
    await expectLater(
      PagedManifest.collect(root.path, cancellation: token),
      throwsA(isA<NshareException>()),
    );
  });
  test(
    '1100-file folder transfers through real TLS with paginated metadata',
    () async {
      final tree = Directory('${root.path}/many')..createSync();
      for (var i = 0; i < 1100; i++) {
        File(
          '${tree.path}/file-${i.toString().padLeft(4, '0')}-${'x' * 110}',
        ).writeAsStringSync('file:$i');
      }
      final sender = await DeviceIdentity.load(
        Directory('${root.path}/sender'),
      );
      final receiver = await DeviceIdentity.load(
        Directory('${root.path}/receiver'),
      );
      final server = await TransferReceiver.start(
        identity: receiver,
        trust: TrustStore(receiver.directory),
        output: Directory('${root.path}/out'),
        approveOffer: (offer) async {
          expect(offer.fileCount, 1100);
          return true;
        },
        expectedFingerprint: sender.fingerprint,
        bind: InternetAddress.loopbackIPv4,
        port: 0,
        discover: false,
      );
      try {
        final result = await sendPath(
          tree.path,
          '127.0.0.1',
          server.port,
          sender,
          TrustStore(sender.directory),
          expectedFingerprint: receiver.fingerprint,
        );
        expect(result.files, 1100);
        for (final source in tree.listSync().cast<File>()) {
          expect(
            await File(
              '${root.path}/out/many/${source.uri.pathSegments.last}',
            ).readAsString(),
            await source.readAsString(),
          );
        }
        // Receipts and manifest ID permit an idempotent restart of the entire tree.
        final retry = await sendPath(
          tree.path,
          '127.0.0.1',
          server.port,
          sender,
          TrustStore(sender.directory),
          expectedFingerprint: receiver.fingerprint,
        );
        expect(retry.files, 1100);
        expect(retry.bytes, 0);
      } finally {
        await server.close();
      }
    },
    timeout: Timeout(Duration(minutes: 3)),
  );
}
