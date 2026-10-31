import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:nshare/nshare.dart';
import 'package:test/test.dart';

void main() {
  final mutations = <String, void Function(Map<String, dynamic>)>{
    'wrong magic': (m) => m['magic'] = 'another-app',
    'old version': (m) => m['version'] = 1,
    'future version': (m) => m['version'] = 3,
    'unrelated request': (m) => m['request'] = 'wrong-nonce',
    'missing request': (m) => m.remove('request'),
    'short fingerprint': (m) => m['fingerprint'] = 'b' * 63,
    'nonhex fingerprint': (m) => m['fingerprint'] = 'g' * 64,
    'uppercase fingerprint': (m) => m['fingerprint'] = 'B' * 64,
    'zero port': (m) => m['port'] = 0,
    'negative port': (m) => m['port'] = -1,
    'excess port': (m) => m['port'] = 65536,
    'string port': (m) => m['port'] = '53317',
    'missing name': (m) => m.remove('name'),
    'empty name': (m) => m['name'] = '',
    'oversize name': (m) => m['name'] = 'b' * 256,
  };
  Future<void> exercise(
    List<int> Function(Map<String, dynamic>) badReply,
  ) async {
    final socket = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final sawRequest = Completer<void>();
    final subscription = socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? packet;
      while ((packet = socket.receive()) != null) {
        final request =
            jsonDecode(utf8.decode(packet!.data)) as Map<String, dynamic>;
        final good = <String, dynamic>{
          'magic': 'nshare-device',
          'version': 2,
          'request': request['request'],
          'name': 'known valid',
          'fingerprint': 'a' * 64,
          'port': 53317,
        };
        socket.send(
          badReply({...good, 'name': 'bad', 'fingerprint': 'b' * 64}),
          packet.address,
          packet.port,
        );
        // A positive control prevents a false pass from receiving no datagrams at all.
        socket.send(utf8.encode(jsonEncode(good)), packet.address, packet.port);
        if (!sawRequest.isCompleted) sawRequest.complete();
      }
    });
    try {
      final devices = await discoverDevices(
        port: socket.port,
        target: InternetAddress.loopbackIPv4,
        // Use the real discovery budget: a sub-second window can expire before
        // Windows schedules UDP reads while native compilation runs in parallel.
        duration: const Duration(seconds: 3),
      );
      await sawRequest.future.timeout(const Duration(seconds: 2));
      expect(devices, hasLength(1));
      expect(devices.single.fingerprint, 'a' * 64);
      expect(devices.single.name, 'known valid');
      expect(devices.single.address, '127.0.0.1');
      expect(devices.single.port, 53317);
    } finally {
      socket.close();
      await subscription.cancel();
    }
  }

  for (final entry in mutations.entries) {
    test(
      'real UDP discovery ignores ${entry.key} and retains the valid response',
      () => exercise((m) {
        entry.value(m);
        return utf8.encode(jsonEncode(m));
      }),
    );
  }
  for (final payload in <String, List<int>>{
    'invalid UTF8': [255],
    'malformed JSON': utf8.encode('{'),
    'oversized datagram': List.filled(2049, 32),
    'JSON array': utf8.encode('[]'),
  }.entries) {
    test(
      'real UDP discovery ignores ${payload.key}',
      () => exercise((_) => payload.value),
    );
  }
  const first = DiscoveredDevice('first', 'a', '127.0.0.1', 53317);
  const second = DiscoveredDevice('second', 'b', '127.0.0.2', 53317);
  test(
    'selection never guesses when no receivers responded',
    () => expect(() => selectDevice([], null), throwsA(isA<NshareException>())),
  );
  test(
    'selection never guesses between different receivers',
    () => expect(
      () => selectDevice([first, second], null),
      throwsA(isA<NshareException>()),
    ),
  );
  test(
    'selection finds an exact requested fingerprint',
    () => expect(selectDevice([first, second], 'b'), same(second)),
  );
  test(
    'selection rejects an absent requested fingerprint',
    () => expect(
      () => selectDevice([first, second], 'c'),
      throwsA(isA<NshareException>()),
    ),
  );
  test(
    'selection rejects ambiguous duplicate fingerprint advertisements',
    () => expect(
      () => selectDevice([first, first], 'a'),
      throwsA(isA<NshareException>()),
    ),
  );
}
