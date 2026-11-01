import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nshare_app/ios_discovery.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const discovery = IosDiscovery();
  final valid = <String, Object>{
    'name': 'Nearby phone',
    'fingerprint': 'a' * 64,
    'address': '192.168.1.25',
    'port': 53317,
  };
  tearDown(
    () => messenger.setMockMethodCallHandler(IosDiscovery.channel, null),
  );
  for (final override in <Map<String, Object?>>[
    {'name': ''},
    {'name': 123},
    {'name': 'x' * 256},
    {'fingerprint': 'bad'},
    {'fingerprint': 'A' * 64},
    {'address': 'https://remote.example'},
    {'address': ''},
    {'port': 0},
    {'port': 65536},
    {'port': '53317'},
  ]) {
    test('Bonjour rejects malformed untrusted metadata $override', () async {
      messenger.setMockMethodCallHandler(
        IosDiscovery.channel,
        (_) async => [
          {...valid, ...override},
          valid,
        ],
      );
      final devices = await discovery.search();
      expect(devices, hasLength(1));
      expect(devices.single.address, '192.168.1.25');
      expect(devices.single.remembered, isFalse);
    });
  }
  test(
    'Bonjour deduplicates peers while retaining valid IPv6 scope addresses',
    () async {
      messenger.setMockMethodCallHandler(
        IosDiscovery.channel,
        (_) async => [
          {...valid, 'address': 'fe80::1%en0'},
          valid,
        ],
      );
      final peers = await discovery.search();
      expect(peers, hasLength(1));
      expect(peers.single.address, 'fe80::1%en0');
    },
  );
  test('Bonjour permission failure reaches the user interface', () async {
    messenger.setMockMethodCallHandler(
      IosDiscovery.channel,
      (_) async => throw PlatformException(
        code: 'permission',
        message: 'Local network denied',
      ),
    );
    await expectLater(discovery.search(), throwsA(isA<PlatformException>()));
  });
  test('Bonjour stop reaches platform lifecycle adapter', () async {
    String? called;
    messenger.setMockMethodCallHandler(IosDiscovery.channel, (call) async {
      called = call.method;
      return null;
    });
    await discovery.stop();
    expect(called, 'stop');
  });
}
