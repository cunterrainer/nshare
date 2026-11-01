import 'dart:io';
import 'package:nshare/nshare.dart';
import 'package:test/test.dart';

void main() {
  for (final count in [0, 3, 1030]) {
    test(
      'scan reports all $count files monotonically across paging fallback',
      () async {
        final root = await Directory.systemTemp.createTemp('scan_');
        try {
          for (var i = 0; i < count; i++) {
            await File('${root.path}/file$i').writeAsString('payload $i');
          }
          final counts = <int>[];
          final manifest = await collectTransferManifest(
            root.path,
            onScan: (n, path) {
              expect(path, startsWith(root.path));
              counts.add(n);
            },
          );
          try {
            expect(counts, List.generate(count + 1, (i) => i + 1));
            expect(manifest.files, count);
          } finally {
            await manifest.dispose();
          }
        } finally {
          await root.delete(recursive: true);
        }
      },
    );
  }
  test('scan cancellation stops enumeration', () async {
    final root = await Directory.systemTemp.createTemp('scan_cancel_');
    try {
      await File('${root.path}/file').writeAsString('payload');
      final token = CancellationToken();
      await expectLater(
        collectTransferManifest(
          root.path,
          cancellation: token,
          onScan: (_, _) => token.cancel(),
        ),
        throwsA(isA<NshareException>()),
      );
    } finally {
      await root.delete(recursive: true);
    }
  });
}
