import 'dart:io';
import 'package:nshare/core.dart';
import 'package:test/test.dart';

void main() {
  test(
    'loopback UDP discovery replies to source port and stops at deadline',
    () async {
      final dir = await Directory.systemTemp.createTemp('nshare_discovery_');
      final identity = await DeviceIdentity.load(dir);
      final service = await DiscoveryService.advertise(
        identity,
        53317,
        port: 0,
        bindAddress: InternetAddress.loopbackIPv4,
      );
      final port = service.port;
      try {
        final devices = await discoverDevices(
          port: port,
          target: InternetAddress.loopbackIPv4,
          // Match the production discovery window under parallel native builds.
          duration: const Duration(seconds: 3),
        );
        expect(devices.single.fingerprint, identity.fingerprint);
        expect(devices.single.port, 53317);
        expect(selectDevice(devices, null).address, '127.0.0.1');
        expect(
          () => selectDevice([...devices, ...devices], null),
          throwsA(isA<NshareException>()),
        );
      } finally {
        await service.close();
        await dir.delete(recursive: true);
      }
      expect(
        await discoverDevices(
          port: port,
          target: InternetAddress.loopbackIPv4,
          duration: const Duration(milliseconds: 50),
        ),
        isEmpty,
      );
    },
  );
}
