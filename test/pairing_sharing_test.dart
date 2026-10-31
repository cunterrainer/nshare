import 'dart:io';
import 'package:nshare/nshare.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  final now = DateTime.utc(2026, 10, 31);
  final base = PairingInvitation(
    '192.168.1.4',
    53317,
    'a' * 64,
    'A' * 43 + '=',
    now.add(const Duration(minutes: 5)),
  );
  setUp(
    () async => root = await Directory.systemTemp.createTemp('nshare_pair_'),
  );
  tearDown(() => root.delete(recursive: true));
  for (final host in [
    '192.168.1.4',
    '127.0.0.1',
    '::1',
    'fe80::1%eth0',
    'my-pc.local',
  ]) {
    test('invitation round trips endpoint $host', () {
      final input = PairingInvitation(
        host,
        53317,
        'a' * 64,
        'A' * 43 + '=',
        base.expires,
      );
      final parsed = PairingInvitation.parse(input.uri.toString(), now: now);
      expect(parsed.host, host);
      expect(parsed.fingerprint, 'a' * 64);
      expect(parsed.port, 53317);
    });
  }
  for (final field in <String, List<String>>{
    'v': ['1', '2', '4', ''],
    'host': ['', 'bad host', '/etc/passwd', 'a@b', 'a?b', 'a#b', 'x' * 256],
    'port': ['0', '-1', '65536', 'nan'],
    'fp': ['a' * 63, 'A' * 64, 'g' * 64, ''],
    'token': ['', 'abc', 'x' * 100],
    'expires': [
      '0',
      'nan',
      '${now.millisecondsSinceEpoch}',
      '${now.add(const Duration(minutes: 11)).millisecondsSinceEpoch}',
    ],
  }.entries) {
    for (final value in field.value) {
      test('reject invitation ${field.key}=$value', () {
        final q = {...base.uri.queryParameters, field.key: value};
        expect(
          () => PairingInvitation.parse(
            base.uri.replace(queryParameters: q).toString(),
            now: now,
          ),
          throwsA(isA<NshareException>()),
        );
      });
    }
  }
  for (final text in [
    'https://example.com',
    'nshare://pair',
    '${base.uri}&v=3',
    '${base.uri}#fragment',
    'x' * 2049,
  ]) {
    test(
      'reject invalid invitation envelope ${text.substring(0, text.length.clamp(0, 40))}',
      () => expect(
        () => PairingInvitation.parse(text, now: now),
        throwsA(isA<NshareException>()),
      ),
    );
  }
  test('invitation consumption is atomic and single use', () async {
    final store = InvitationStore(root);
    final invite = await store.issue('127.0.0.1', 53317, 'a' * 64);
    await store.consume(invite.token);
    await expectLater(
      InvitationStore(root).consume(invite.token),
      throwsA(isA<NshareException>()),
    );
  });
  test('expired token is rejected by receiver', () async {
    final invite = await InvitationStore(
      root,
    ).issue('127.0.0.1', 53317, 'a' * 64, now: now);
    await expectLater(
      InvitationStore(
        root,
      ).consume(invite.token, now: now.add(const Duration(minutes: 6))),
      throwsA(isA<NshareException>()),
    );
  });
  test('QR exports contain quiet zone and no private key', () {
    expect(base.svg, contains('viewBox='));
    expect(base.svg, contains('fill="white"'));
    expect(base.svg, contains('fill="black"'));
    expect(base.terminalQr, contains('47m▀'));
    expect(base.svg, isNot(contains('PRIVATE KEY')));
  });
  test('UTF8 clipboard limit counts bytes', () {
    validateClipboardText('a' * 65536);
    validateClipboardText('😀' * 16384);
    expect(
      () => validateClipboardText('😀' * 16385),
      throwsA(isA<NshareException>()),
    );
  });
}
