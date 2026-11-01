import 'dart:io';
import 'dart:convert';
import 'package:nshare/nshare.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'support/native_cli.dart';

void main() {
  late NativeCli cli;
  late Directory state;
  setUpAll(() async {
    cli = await NativeCli.create();
  });
  tearDownAll(() => cli.close());
  setUp(() async {
    final workspace = await cli.root.createTemp('cli_');
    state = Directory(p.join(workspace.path, 'state-not-yet-created'));
  });
  test(
    'native CLI pairs by code through a real terminal and persists trust',
    () async {
      final receiverState = await Directory(
        '${state.parent.path}/code-receiver',
      ).create();
      final identity = await DeviceIdentity.load(receiverState);
      String? code;
      final receiver = await TransferReceiver.start(
        output: Directory('${state.parent.path}/received'),
        identity: identity,
        trust: TrustStore(receiverState),
        port: 0,
        discover: false,
        approvePeer: (peer) async {
          code = peer.confirmationCode;
          return true;
        },
        approveOffer: (_) async => false,
      );
      final args = [
        cli.executable,
        '--state-dir',
        state.path,
        'pair',
        '--connect',
        '127.0.0.1',
        '--port',
        '${receiver.port}',
      ];
      String quote(String value) => "'${value.replaceAll("'", "'\\''")}'";
      final process = await Process.start('script', [
        '-q',
        '-e',
        '-c',
        args.map(quote).join(' '),
        '/dev/null',
      ]);
      final output = process.stdout.transform(utf8.decoder).join();
      final errors = process.stderr.transform(utf8.decoder).join();
      process.stdin.writeln('yes');
      try {
        final exit = await process.exitCode.timeout(
          const Duration(seconds: 30),
        );
        expect(exit, 0, reason: '${await output} ${await errors}');
        expect(code, isNotNull);
        expect(await output, contains('Matching code: $code'));
        expect(await output, contains('Paired: ${identity.fingerprint}'));
        expect(await TrustStore(state).list(), contains(identity.fingerprint));
      } finally {
        process.kill();
        await process.stdin.close();
        await receiver.close();
      }
    },
    skip: !Platform.isLinux,
  );

  for (final command in ['', 'send', 'receive', 'devices', 'trust']) {
    test(
      'native CLI help for ${command.isEmpty ? 'global' : command} exits without creating state',
      () async {
        final result = await cli.run(state, [
          if (command.isNotEmpty) command,
          '--help',
        ]);
        expect(result.code, 0, reason: result.toString());
        expect(result.out, contains('Usage:'));
        expect(await state.exists(), isFalse);
      },
    );
  }
  for (final loopback in [false, true]) {
    test(
      'native CLI show-ip include-loopback=$loopback is standalone and does not create state',
      () async {
        final result = await cli.run(state, [
          '--show-ip',
          if (loopback) '--include-loopback',
        ]);
        expect(result.code, 0, reason: result.toString());
        if (loopback) expect(result.out, contains('127.0.0.1'));
        expect(await state.exists(), isFalse);
      },
    );
  }
  final invalid = <String, List<String>>{
    'unknown global flag': ['--bogus'],
    'unknown send flag': ['send', '--bogus'],
    'missing send path': ['send'],
    'two send paths': ['send', 'a', 'b'],
    'unexpected receive argument': ['receive', 'path'],
    'unexpected devices argument': ['devices', 'path'],
    'unexpected trust argument': ['trust', 'path'],
    'unknown command': ['unknown'],
    'show-ip plus command': ['--show-ip', 'receive'],
    'show-ip plus positional argument': ['--show-ip', 'stray'],
    'both target selectors': [
      'send',
      'a',
      '--ip',
      '127.0.0.1',
      '--to',
      'a' * 64,
    ],
    for (final port in ['0', '-1', '65536', 'abc', '1.5'])
      'invalid sender TCP port $port': [
        'send',
        'file',
        '--ip',
        '127.0.0.1',
        '--port',
        port,
      ],
    for (final port in ['0', '65536'])
      'invalid receiver TCP port $port': ['receive', '--port', port],
    'invalid discovery port': ['devices', '--discovery-port', '0'],
    for (final fingerprint in ['', 'abc', 'g' * 64, 'a' * 65])
      'invalid fingerprint length=${fingerprint.length}': [
        'send',
        'file',
        '--peer-fingerprint',
        fingerprint,
      ],
    'unsupported conflict policy': ['receive', '--conflict', 'erase'],
    'missing port value': ['send', 'file', '--port'],
  };
  for (final entry in invalid.entries) {
    test('native CLI rejects ${entry.key} as usage error', () async {
      final result = await cli.run(state, entry.value);
      expect(result.code, 64, reason: result.toString());
      expect(result.out, isNot(contains('Complete:')));
      expect(result.err, isNotEmpty);
    });
  }
  test('native CLI missing source fails without reporting success', () async {
    final result = await cli.run(state, [
      'send',
      p.join(state.parent.path, 'missing'),
      '--ip',
      '127.0.0.1',
    ]);
    expect(result.code, 1, reason: result.toString());
    expect(result.out, isNot(contains('Complete:')));
    expect(result.err, contains('source'));
  });
  test(
    'native CLI trust creates a persistent identity and forgets an unknown pin safely',
    () async {
      final first = await cli.run(state, ['trust']);
      final second = await cli.run(state, ['trust', '--forget', 'f' * 64]);
      expect(first.code, 0, reason: first.toString());
      expect(second.code, 0, reason: second.toString());
      expect(second.out, first.out);
      expect(first.out, matches(RegExp(r'^This device: [a-f0-9]{64}\s*$')));
    },
  );
}
