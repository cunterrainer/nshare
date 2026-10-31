import 'dart:io';
import 'package:nshare/nshare.dart';
import 'package:test/test.dart';

void main() {
  late Directory root, state;
  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('nshare_trust_matrix_');
  });
  tearDownAll(() => root.delete(recursive: true));
  setUp(() async {
    state = await root.createTemp('case_');
  });
  const peer = PeerIdentity(
    'test peer',
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  );
  const other = PeerIdentity(
    'other peer',
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  );
  Matcher error(String code) =>
      isA<NshareException>().having((e) => e.code, 'code', code);
  test(
    'new trust store starts empty',
    () async => expect(await TrustStore(state).list(), isEmpty),
  );
  test(
    'unverified unknown peer is rejected without an approval callback',
    () async {
      await expectLater(
        TrustStore(state).approve(peer, null),
        throwsA(error('untrusted')),
      );
      expect(await TrustStore(state).list(), isEmpty);
    },
  );
  test('declined pairing never persists trust', () async {
    await expectLater(
      TrustStore(state).approve(peer, (_) async => false),
      throwsA(error('untrusted')),
    );
    expect(await TrustStore(state).list(), isEmpty);
  });
  test('approved pairing survives a fresh store instance', () async {
    await TrustStore(state).approve(peer, (_) async => true);
    expect((await TrustStore(state).list()).keys, [peer.fingerprint]);
  });
  test('verified uppercase expected fingerprint is normalized', () async {
    await TrustStore(
      state,
    ).approve(peer, null, expectedFingerprint: peer.fingerprint.toUpperCase());
    expect((await TrustStore(state).list()).keys, [peer.fingerprint]);
  });
  test(
    'mismatched explicit pin is rejected before approval is requested',
    () async {
      var requested = false;
      await expectLater(
        TrustStore(state).approve(peer, (_) async {
          requested = true;
          return true;
        }, expectedFingerprint: other.fingerprint),
        throwsA(error('identity')),
      );
      expect(requested, isFalse);
      expect(await TrustStore(state).list(), isEmpty);
    },
  );
  test(
    'remembered identity does not prompt for pairing a second time',
    () async {
      final store = TrustStore(state);
      await store.approve(peer, null, expectedFingerprint: peer.fingerprint);
      await store.approve(
        peer,
        (_) async => throw StateError('Must not prompt'),
      );
    },
  );
  test('repeated connections do not duplicate endpoint pins', () async {
    final store = TrustStore(state);
    for (var i = 0; i < 3; i++) {
      await store.approve(
        peer,
        null,
        expectedFingerprint: peer.fingerprint,
        endpoint: '127.0.0.1:1',
      );
    }
    expect((await store.list())[peer.fingerprint]['endpoints'], [
      '127.0.0.1:1',
    ]);
  });
  test('forgetting one peer preserves the other peer and endpoint', () async {
    final store = TrustStore(state);
    await store.approve(
      peer,
      null,
      expectedFingerprint: peer.fingerprint,
      endpoint: 'a:1',
    );
    await store.approve(
      other,
      null,
      expectedFingerprint: other.fingerprint,
      endpoint: 'b:1',
    );
    await store.forget(peer.fingerprint);
    final records = await store.list();
    expect(records.keys, [other.fingerprint]);
    expect(records[other.fingerprint]['endpoints'], ['b:1']);
  });
  test(
    'changed endpoint identity is rejected even with explicit new fingerprint',
    () async {
      final store = TrustStore(state);
      await store.approve(
        peer,
        null,
        expectedFingerprint: peer.fingerprint,
        endpoint: 'a:1',
      );
      await expectLater(
        store.approve(
          other,
          null,
          expectedFingerprint: other.fingerprint,
          endpoint: 'a:1',
        ),
        throwsA(error('identity')),
      );
    },
  );
  test(
    'concurrent store instances preserve all independently approved peers',
    () async {
      final peers = List.generate(
        12,
        (i) => PeerIdentity('peer $i', i.toRadixString(16).padLeft(64, '0')),
      );
      await Future.wait(
        peers.map(
          (peer) => TrustStore(state).approve(
            peer,
            null,
            expectedFingerprint: peer.fingerprint,
            endpoint: 'host:${peer.name}',
          ),
        ),
      );
      expect(
        (await TrustStore(state).list()).keys,
        unorderedEquals(peers.map((p) => p.fingerprint)),
      );
    },
  );
  test('concurrent endpoint additions to one identity are not lost', () async {
    await Future.wait(
      List.generate(
        12,
        (i) => TrustStore(state).approve(
          peer,
          null,
          expectedFingerprint: peer.fingerprint,
          endpoint: 'host:$i',
        ),
      ),
    );
    expect(
      (await TrustStore(state).list())[peer.fingerprint]['endpoints'],
      unorderedEquals(List.generate(12, (i) => 'host:$i')),
    );
  });
}
