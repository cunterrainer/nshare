import 'dart:io';
import 'package:nshare/src/discovery/discovery.dart';
import 'package:nshare/src/identity/identity.dart';
import 'package:nshare/core.dart';
import 'package:test/test.dart';

void main() {
  test(
    'loopback UDP discovery replies to source port and stops at deadline',
    () async {
      final dir = await Directory.systemTemp.createTemp('nshare_discovery_');
      final identity = await DeviceIdentity.load(dir);
      final probe = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final port = probe.port;
      probe.close();
      final service = await DiscoveryService.advertise(
        identity,
        53317,
        port: port,
        bindAddress: InternetAddress.loopbackIPv4,
      );
      try {
        final devices = await discoverDevices(
          port: port,
          target: InternetAddress.loopbackIPv4,
          duration: const Duration(milliseconds: 150),
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
