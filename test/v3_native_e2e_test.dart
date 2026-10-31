import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:test/test.dart';
import 'support/native_cli.dart';

void main() {
  late NativeCli cli;
  setUpAll(() async => cli = await NativeCli.create());
  tearDownAll(() => cli.close());
  for (final size in [
    0,
    1,
    31,
    1024,
    4096,
    65535,
    65536,
    65537,
    131072,
    262145,
  ]) {
    for (final compressible in [false, true]) {
      for (final saved in [false, true]) {
        test(
          'native compressed transfer $size bytes repetitive=$compressible saved=$saved',
          () async {
            final s = await cli.scenario();
            final port = await cli.port();
            final random = Random(size);
            final data = List.generate(
              size,
              (_) => compressible ? 65 : random.nextInt(256),
            );
            final source = await s.file('payload.bin', data);
            final receiver = await cli.start(s.receiverState, [
              'receive',
              '--bind',
              '127.0.0.1',
              '--port',
              '$port',
              '--no-discover',
              '--allow-compression',
              '--output',
              s.output.path,
              '--once',
              '--accept',
              '--peer-fingerprint',
              cli.sender.fingerprint,
            ]);
            try {
              await receiver.ready();
              if (saved) {
                final settings = await cli.run(s.senderState, [
                  'settings',
                  '--set',
                  'compression',
                  '--value',
                  'true',
                ]);
                expect(settings.code, 0, reason: settings.toString());
              }
              final sent = await cli.run(s.senderState, [
                'send',
                source.path,
                '--ip',
                '127.0.0.1',
                '--port',
                '$port',
                '--peer-fingerprint',
                cli.receiver.fingerprint,
                if (!saved) '--compress',
              ]);
              expect(sent.code, 0, reason: sent.toString());
              expect((await receiver.finish()).code, 0);
              expect(
                await File('${s.output.path}/payload.bin').readAsBytes(),
                data,
              );
            } finally {
              await receiver.stop();
            }
          },
        );
      }
    }
  }
  for (final text in [
    '',
    'plain text',
    'line one\nline two',
    '日本語 😀',
    'a\tb',
    'é' * 1000,
  ]) {
    test(
      'native clipboard sends exact UTF8 text length ${text.length}',
      () async {
        final s = await cli.scenario();
        final port = await cli.port();
        final receiver = await cli.start(s.receiverState, [
          'receive',
          '--bind',
          '127.0.0.1',
          '--port',
          '$port',
          '--no-discover',
          '--output',
          s.output.path,
          '--once',
          '--accept-clipboard',
          '--peer-fingerprint',
          cli.sender.fingerprint,
        ]);
        try {
          await receiver.ready();
          final result = await cli.run(s.senderState, [
            'clipboard',
            '--ip',
            '127.0.0.1',
            '--port',
            '$port',
            '--peer-fingerprint',
            cli.receiver.fingerprint,
            '--text',
            text,
          ]);
          expect(result.code, 0, reason: result.toString());
          final received = await receiver.finish();
          expect(received.code, 0);
          expect(received.out, text);
        } finally {
          await receiver.stop();
        }
      },
    );
  }
  test('native clipboard is rejected without separate consent', () async {
    final s = await cli.scenario();
    final port = await cli.port();
    final receiver = await s.receive(port);
    try {
      final result = await cli.run(s.senderState, [
        'clipboard',
        '--ip',
        '127.0.0.1',
        '--port',
        '$port',
        '--peer-fingerprint',
        cli.receiver.fingerprint,
        '--text',
        'private text',
      ]);
      expect(result.code, 1);
      expect(result.out, isNot(contains('private text')));
      expect((await receiver.finish()).code, 1);
    } finally {
      await receiver.stop();
    }
  });
  test('native camera-free pairing consumes invitation exactly once', () async {
    final s = await cli.scenario();
    final port = await cli.port();
    final invitation = await cli.run(s.receiverState, [
      'pair',
      '--host',
      '127.0.0.1',
      '--port',
      '$port',
    ]);
    expect(invitation.code, 0);
    final uri = invitation.out.trim();
    for (final expected in [0, 1]) {
      final receiver = await s.receive(port);
      try {
        final joined = await cli.run(s.senderState, ['pair', '--join', uri]);
        expect(joined.code, expected, reason: joined.toString());
        expect((await receiver.finish()).code, expected);
      } finally {
        await receiver.stop();
      }
    }
  });
  test(
    'native queue preserves paused job and sends remaining FIFO work',
    () async {
      final s = await cli.scenario();
      final port = await cli.port();
      final jobs = <Map<String, dynamic>>[];
      for (var i = 0; i < 3; i++) {
        final file = await s.file('job-$i.txt', utf8.encode('queued:$i'));
        final result = await cli.run(s.senderState, [
          'queue',
          '--action',
          'add',
          '--path',
          file.path,
          '--ip',
          '127.0.0.1',
          '--port',
          '$port',
          '--peer-fingerprint',
          cli.receiver.fingerprint,
        ]);
        expect(result.code, 0);
        jobs.add(jsonDecode(result.out) as Map<String, dynamic>);
      }
      expect(
        (await cli.run(s.senderState, [
          'queue',
          '--action',
          'pause',
          '--id',
          jobs[0]['id'] as String,
        ])).code,
        0,
      );
      final receiver = await s.receive(port, once: false);
      try {
        final result = await cli.run(s.senderState, [
          'queue',
          '--action',
          'run',
        ]);
        expect(result.code, 0, reason: result.toString());
        expect(await File('${s.output.path}/job-0.txt').exists(), isFalse);
        for (var i = 1; i < 3; i++) {
          expect(
            await File('${s.output.path}/job-$i.txt').readAsString(),
            'queued:$i',
          );
        }
        final list = await cli.run(s.senderState, ['queue', '--json']);
        final data = jsonDecode(list.out) as List;
        expect(data.map((v) => v['status']), [
          'paused',
          'completed',
          'completed',
        ]);
        await cli.run(s.senderState, [
          'queue',
          '--action',
          'resume',
          '--id',
          jobs[0]['id'] as String,
        ]);
        expect(
          (await cli.run(s.senderState, ['queue', '--action', 'run'])).code,
          0,
        );
        expect(
          await File('${s.output.path}/job-0.txt').readAsString(),
          'queued:0',
        );
      } finally {
        await receiver.stop();
      }
    },
  );
  test(
    'native local service exposes status and shuts down through authenticated client',
    () async {
      final s = await cli.scenario();
      final port = await cli.port();
      final owner = await cli.start(s.receiverState, [
        'service',
        '--action',
        'run',
        '--port',
        '$port',
        '--output',
        s.output.path,
        '--accept',
        '--peer-fingerprint',
        cli.sender.fingerprint,
      ]);
      try {
        await owner.ready();
        final result = await cli.run(s.receiverState, [
          'service',
          '--action',
          'status',
        ]);
        expect(result.code, 0, reason: result.toString());
        expect((jsonDecode(result.out) as Map)['receiverPort'], port);
        final file = await s.file(
          'service.txt',
          utf8.encode('service transfer'),
        );
        expect((await s.send(file.path, port)).code, 0);
        expect(
          await File('${s.output.path}/service.txt').readAsString(),
          'service transfer',
        );
        expect(
          (await cli.run(s.receiverState, [
            'service',
            '--action',
            'stop',
          ])).code,
          0,
        );
        expect((await owner.finish()).code, 0);
      } finally {
        await owner.stop();
      }
    },
  );
  for (final command in ['pair', 'clipboard', 'queue', 'settings', 'service']) {
    test('native $command help is available without side effects', () async {
      final s = await cli.scenario();
      final result = await cli.run(s.senderState, [command, '--help']);
      expect(result.code, 0, reason: result.toString());
      expect(result.out, contains('Usage:'));
    });
  }
}
