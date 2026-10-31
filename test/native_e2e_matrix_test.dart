import 'dart:async';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:nshare/src/storage/storage.dart';
import 'package:test/test.dart';
import 'support/native_cli.dart';

void main() {
  late NativeCli cli;
  late Scenario scenario;
  setUpAll(() async {
    cli = await NativeCli.create();
  });
  tearDownAll(() => cli.close());
  setUp(() async {
    scenario = await cli.scenario();
  });

  Future<CliResult> transfer(
    String source, {
    String conflict = 'refuse',
    bool shared = false,
    String host = '127.0.0.1',
    int? port,
  }) async {
    final selectedPort = port ?? await cli.port();
    final receiver = await scenario.receive(
      selectedPort,
      conflict: conflict,
      sharedIdentity: shared,
      host: host,
    );
    try {
      final result = await scenario.send(
        source,
        selectedPort,
        sharedIdentity: shared,
        host: host,
      );
      expect(result.code, 0, reason: result.toString());
      final received = await receiver.finish();
      expect(received.code, 0, reason: received.toString());
      expect(result.out, contains('Complete:'));
      expect(received.out, contains('Complete:'));
      return result;
    } finally {
      await receiver.stop();
    }
  }

  Future<void> compareTree(String source) async {
    final manifest = await Manifest.collect(source);
    for (final entry in manifest.entries) {
      final target = p.joinAll([
        scenario.output.path,
        ...entry.path.split('/'),
      ]);
      if (entry.directory) {
        expect(await Directory(target).exists(), isTrue, reason: entry.path);
      } else {
        expect(await File(target).length(), entry.size, reason: entry.path);
        expect(await hashFile(File(target)), entry.hash, reason: entry.path);
      }
    }
  }

  for (final size in [
    0,
    1,
    2,
    255,
    256,
    4095,
    4096,
    65535,
    65536,
    65537,
    131071,
    131072,
    131073,
    1048579,
  ]) {
    test('native TLS end-to-end file size $size bytes', () async {
      final data = List<int>.generate(size, (i) => (i * 37 + size) % 256);
      final source = await scenario.file('boundary-$size.bin', data);
      final result = await transfer(source.path);
      expect(
        result.out,
        contains('1 verified files, 0 skipped, $size bytes sent'),
      );
      expect(
        await File(
          p.join(scenario.output.path, p.basename(source.path)),
        ).readAsBytes(),
        data,
      );
    });
  }
  for (final name in [
    'café.txt',
    '文件.txt',
    'emoji-📦.bin',
    'space name.txt',
    'résumé_日本語.txt',
    'multi.part.name',
    '.hidden',
  ]) {
    test('native TLS preserves filename $name', () async {
      final source = await scenario.file(name, [0, 255, 13, 10, 42]);
      await transfer(source.path);
      expect(await File(p.join(scenario.output.path, name)).readAsBytes(), [
        0,
        255,
        13,
        10,
        42,
      ]);
    });
  }
  final trees = <String, Future<void> Function(Directory)>{
    'empty root': (root) async {},
    'only empty directories': (root) async {
      await Directory(p.join(root.path, 'a', 'b')).create(recursive: true);
      await Directory(p.join(root.path, 'c')).create();
    },
    'deep nesting': (root) async {
      final dir = Directory(
        p.joinAll([root.path, ...List.generate(8, (i) => 'level$i')]),
      );
      await dir.create(recursive: true);
      await File(p.join(dir.path, 'leaf')).writeAsString('deep');
    },
    'mixed empty and nonempty files': (root) async {
      await File(p.join(root.path, 'empty')).writeAsString('');
      await File(p.join(root.path, 'nonempty')).writeAsString('nonempty');
    },
    '100 small files': (root) async {
      for (var i = 0; i < 100; i++) {
        await File(p.join(root.path, '$i.txt')).writeAsString('payload $i');
      }
    },
    'hidden subdirectories': (root) async {
      final dir = Directory(p.join(root.path, '.hidden'));
      await dir.create();
      await File(p.join(dir.path, '.file')).writeAsBytes([0, 255]);
    },
    'all binary byte values': (root) async {
      await File(
        p.join(root.path, 'bytes'),
      ).writeAsBytes(List.generate(256, (i) => i));
    },
    'Unicode directory with spaces': (root) async {
      final dir = Directory(p.join(root.path, '文件 with spaces'));
      await dir.create();
      await File(p.join(dir.path, 'résumé.txt')).writeAsString('日本語 — café');
    },
  };
  for (final entry in trees.entries) {
    test('native TLS directory end-to-end ${entry.key}', () async {
      final root = Directory(p.join(scenario.directory.path, 'folder'));
      await root.create();
      await entry.value(root);
      final manifest = await Manifest.collect(root.path);
      final result = await transfer(root.path);
      expect(
        result.out,
        contains(
          '${manifest.files} verified files, 0 skipped, ${manifest.bytes} bytes sent',
        ),
      );
      await compareTree(root.path);
    });
  }
  for (final policy in ['refuse', 'skip', 'overwrite']) {
    test('native end-to-end conflict policy $policy', () async {
      final source = await scenario.file('conflict.txt', [1, 2, 3]);
      await scenario.output.create();
      final destination = File(p.join(scenario.output.path, 'conflict.txt'));
      await destination.writeAsBytes([9, 8, 7]);
      final port = await cli.port();
      final receiver = await scenario.receive(port, conflict: policy);
      try {
        final result = await scenario.send(source.path, port);
        final received = await receiver.finish();
        expect(
          result.code,
          policy == 'refuse' ? 1 : 0,
          reason: result.toString(),
        );
        expect(
          received.code,
          policy == 'refuse' ? 1 : 0,
          reason: received.toString(),
        );
        expect(
          await destination.readAsBytes(),
          policy == 'overwrite' ? [1, 2, 3] : [9, 8, 7],
        );
        if (policy == 'skip') {
          expect(
            result.out,
            contains('0 verified files, 1 skipped, 0 bytes sent'),
          );
        }
        if (policy == 'refuse') {
          expect(result.out, isNot(contains('Complete:')));
        }
      } finally {
        await receiver.stop();
      }
    });
  }
  test(
    'native directory/file collision never replaces the destination directory',
    () async {
      final source = await scenario.file('collision', [1]);
      await Directory(
        p.join(scenario.output.path, 'collision'),
      ).create(recursive: true);
      final port = await cli.port();
      final receiver = await scenario.receive(port, conflict: 'overwrite');
      try {
        expect((await scenario.send(source.path, port)).code, 1);
        expect((await receiver.finish()).code, 1);
        expect(
          await Directory(p.join(scenario.output.path, 'collision')).exists(),
          isTrue,
        );
      } finally {
        await receiver.stop();
      }
    },
  );
  test(
    'native retry revalidates finalized bytes without resending data',
    () async {
      final source = await scenario.file(
        'retry.bin',
        List.generate(65537, (i) => i % 256),
      );
      await transfer(source.path);
      final retry = await transfer(source.path);
      expect(retry.out, contains('1 verified files, 0 skipped, 0 bytes sent'));
      await compareTree(source.path);
    },
  );
  test(
    'native retry refuses a destination modified after completion',
    () async {
      final source = await scenario.file('tampered', [1, 2, 3, 4]);
      await transfer(source.path);
      final target = File(p.join(scenario.output.path, 'tampered'));
      await target.writeAsBytes([4, 3, 2, 1]);
      final port = await cli.port();
      final receiver = await scenario.receive(port);
      try {
        expect((await scenario.send(source.path, port)).code, 1);
        expect((await receiver.finish()).code, 1);
        expect(await target.readAsBytes(), [4, 3, 2, 1]);
      } finally {
        await receiver.stop();
      }
    },
  );
  test(
    'native changed source uses a new manifest and explicit overwrite',
    () async {
      final source = await scenario.file('changed', [1, 2, 3]);
      await transfer(source.path);
      await source.writeAsBytes([4, 5, 6]);
      final result = await transfer(source.path, conflict: 'overwrite');
      expect(result.out, contains('3 bytes sent'));
      await compareTree(source.path);
    },
  );
  test(
    'native sender and receiver can share their complete identity/trust state',
    () async {
      final source = await scenario.file('self.txt', [42]);
      await transfer(source.path, shared: true);
      await compareTree(source.path);
    },
  );
  test(
    'native remembered peers transfer again without fingerprint arguments',
    () async {
      final source = await scenario.file('remembered', [1, 2]);
      final port = await cli.port();
      await transfer(source.path, port: port);
      final receiver = await scenario.receive(port, usePin: false);
      try {
        final result = await scenario.send(source.path, port, usePin: false);
        expect(result.code, 0, reason: result.toString());
        expect((await receiver.finish()).code, 0);
        expect(result.out, contains('0 bytes sent'));
      } finally {
        await receiver.stop();
      }
    },
  );
  test(
    'native noninteractive receiver declines offers without explicit acceptance',
    () async {
      final source = await scenario.file('declined', [42]);
      final port = await cli.port();
      final receiver = await scenario.receive(port, accept: false);
      try {
        expect((await scenario.send(source.path, port)).code, 1);
        expect((await receiver.finish()).code, 1);
        expect(await scenario.output.exists(), isFalse);
      } finally {
        await receiver.stop();
      }
    },
  );
  test(
    'native authenticated receiver rejects the wrong sender pin before files',
    () async {
      final source = await scenario.file('wrong-peer', [42]);
      final port = await cli.port();
      final receiver = await scenario.receive(
        port,
        pin: cli.receiver.fingerprint,
      );
      try {
        expect((await scenario.send(source.path, port)).code, 1);
        expect((await receiver.finish()).code, 1);
        expect(await scenario.output.exists(), isFalse);
      } finally {
        await receiver.stop();
      }
    },
  );
  test(
    'native receiver remains alive across four distinct sender sessions',
    () async {
      final port = await cli.port();
      final receiver = await scenario.receive(port, once: false);
      try {
        for (var i = 0; i < 4; i++) {
          final source = await scenario.file('session-$i', [i]);
          final result = await scenario.send(source.path, port);
          expect(result.code, 0, reason: result.toString());
          await compareTree(source.path);
        }
      } finally {
        await receiver.stop();
      }
    },
  );
  test(
    'native receiver termination retains a partial and restart resumes it',
    () async {
      final source = await scenario.file(
        'interrupted.bin',
        List.generate(8 * 1048576, (i) => i % 251),
      );
      final port = await cli.port();
      CliChild? receiving;
      final killed = Completer<void>();
      receiving = await scenario.receive(
        port,
        onLine: (line) {
          if (line.startsWith('transferring:') &&
              receiving != null &&
              !killed.isCompleted) {
            receiving.process.kill();
            killed.complete();
          }
        },
      );
      try {
        final sending = scenario.send(source.path, port);
        await killed.future.timeout(const Duration(seconds: 20));
        expect((await sending).code, isNot(0));
        expect((await receiving.finish()).code, isNot(0));
        expect(
          await File(p.join(scenario.output.path, 'interrupted.bin')).exists(),
          isFalse,
        );
      } finally {
        await receiving.stop();
      }
      final resumed = await transfer(source.path);
      final sent = int.parse(
        RegExp(r'(\d+) bytes sent').firstMatch(resumed.out)!.group(1)!,
      );
      expect(sent, lessThan(await source.length()));
      await compareTree(source.path);
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );
}
