import 'dart:io';
import 'package:flutter/services.dart';
import 'package:nshare/nshare.dart';

/// System Bonjour works with iOS local-network permission without raw multicast
/// entitlements. Discovery data remains untrusted until pairing verifies it.
class IosDiscovery {
  const IosDiscovery();
  static const channel = MethodChannel('dev.nshare/discovery');
  Future<List<DiscoveredDevice>> search() async {
    final values = await channel.invokeMethod<List<dynamic>>('search');
    final devices = <String, DiscoveredDevice>{};
    for (final value in (values ?? []).take(256)) {
      if (value is! Map) continue;
      final name = value['name'],
          fp = value['fingerprint'],
          address = value['address'],
          port = value['port'];
      if (name is! String ||
          name.isEmpty ||
          name.length > 255 ||
          fp is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(fp) ||
          address is! String ||
          !_validAddress(address) ||
          port is! int ||
          port < 1 ||
          port > 65535) {
        continue;
      }
      devices.putIfAbsent(fp, () => DiscoveredDevice(name, fp, address, port));
    }
    return devices.values.toList();
  }

  Future<void> publish(DeviceIdentity identity, int port) =>
      channel.invokeMethod<void>('publish', {
        'name': identity.name,
        'fingerprint': identity.fingerprint,
        'port': port,
      });
  Future<void> stop() => channel.invokeMethod<void>('stop');
}

bool _validAddress(String text) {
  final parts = text.split('%');
  final address = InternetAddress.tryParse(parts.first);
  return address != null &&
      (parts.length == 1 ||
          (parts.length == 2 &&
              address.type == InternetAddressType.IPv6 &&
              RegExp(r'^[a-zA-Z0-9_.-]{1,32}$').hasMatch(parts.last)));
}
