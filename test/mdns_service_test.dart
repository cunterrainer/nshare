import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:nshare/nshare.dart';
import 'package:nshare/src/discovery/mdns.dart';
import 'package:test/test.dart';

void main() {
  final packet = mdnsAdvertisement('a' * 64, 'Workstation', 53317);
  test('DNS-SD parses full service metadata and source endpoint', () {
    final peer = parseMdns(packet, '192.168.1.2')!;
    expect(peer.fingerprint, 'a' * 64);
    expect(peer.name, 'Workstation');
    expect(peer.port, 53317);
    expect(peer.address, '192.168.1.2');
  });
  test(
    'DNS-SD supports scoped IPv6 source addresses',
    () => expect(parseMdns(packet, 'fe80::1%eth0')!.address, 'fe80::1%eth0'),
  );
  for (final length in [
    0,
    1,
    2,
    4,
    8,
    11,
    12,
    15,
    20,
    30,
    50,
    100,
    packet.length - 1,
  ]) {
    test(
      'truncated DNS packet at $length does not produce a device',
      () => expect(
        parseMdns(Uint8List.sublistView(packet, 0, length), '127.0.0.1'),
        isNull,
      ),
    );
  }
  for (final pin in ['a' * 63, 'g' * 64, 'A' * 64]) {
    test(
      'DNS-SD rejects malformed fingerprint $pin',
      () => expect(
        parseMdns(mdnsAdvertisement(pin, 'PC', 53317), '127.0.0.1'),
        isNull,
      ),
    );
  }
  test(
    'DNS-SD rejects zero service port',
    () => expect(
      parseMdns(mdnsAdvertisement('a' * 64, 'PC', 0), '127.0.0.1'),
      isNull,
    ),
  );
  test(
    'expired DNS records do not produce a device',
    () => expect(
      parseMdns(mdnsAdvertisement('a' * 64, 'PC', 53317, ttl: 0), '127.0.0.1'),
      isNull,
    ),
  );
  test(
    'DNS query is never interpreted as advertisement',
    () => expect(parseMdns(mdnsQuery(), '127.0.0.1'), isNull),
  );
  test('malicious compression pointer loop is bounded', () {
    final bytes = Uint8List.fromList([...packet]);
    bytes[12] = 0xc0;
    bytes[13] = 12;
    expect(parseMdns(bytes, '127.0.0.1'), isNull);
  });
  test('excessive DNS record count rejected before parse', () {
    final bytes = Uint8List.fromList(packet);
    bytes[6] = 255;
    bytes[7] = 255;
    expect(parseMdns(bytes, '127.0.0.1'), isNull);
  });
  test(
    'oversized multicast packet rejected',
    () => expect(parseMdns(Uint8List(9001), '127.0.0.1'), isNull),
  );
  test(
    'service endpoint requires bearer authentication and releases ownership',
    () async {
      final root = await Directory.systemTemp.createTemp('nshare_service_');
      final identity = await DeviceIdentity.load(root);
      final service = await LocalService.start(
        root,
        identity,
        TrustStore(root),
      );
      final client = LocalServiceClient(root);
      try {
        expect((await client.status())['fingerprint'], identity.fingerprint);
        await expectLater(
          LocalService.start(root, identity, TrustStore(root)),
          throwsA(isA<NshareException>()),
        );
        final descriptor =
            jsonDecode(await File('${root.path}/service.json').readAsString())
                as Map;
        final http = HttpClient();
        try {
          final request = await http.getUrl(
            Uri.parse('http://127.0.0.1:${descriptor['port']}/status'),
          );
          final response = await request.close();
          expect(response.statusCode, 401);
          await response.drain<void>();
        } finally {
          http.close(force: true);
        }
        await client.stop();
        await service.done;
        expect(await File('${root.path}/service.json').exists(), isFalse);
        final replacement = await LocalService.start(
          root,
          identity,
          TrustStore(root),
        );
        await replacement.close();
      } finally {
        await service.close();
        await root.delete(recursive: true);
      }
    },
  );
}
