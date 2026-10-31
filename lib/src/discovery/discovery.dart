import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../core/models.dart';
import '../identity/identity.dart';
import '../protocol/protocol.dart';

class DiscoveredDevice {
  const DiscoveredDevice(this.name, this.fingerprint, this.address, this.port);
  final String name;
  final String fingerprint;
  final String address;
  final int port;
}

class DiscoveryService {
  DiscoveryService._(this._socket, this._subscription);
  final RawDatagramSocket _socket;
  final StreamSubscription<RawSocketEvent> _subscription;

  static Future<DiscoveryService> advertise(
    DeviceIdentity identity,
    int transferPort, {
    int port = 1970,
    InternetAddress? bindAddress,
  }) async {
    final socket = await RawDatagramSocket.bind(
      bindAddress ?? InternetAddress.anyIPv4,
      port,
    );
    final recent = <String, DateTime>{};
    final subscription = socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? packet;
      while ((packet = socket.receive()) != null) {
        final datagram = packet!;
        if (datagram.data.length > 2048) continue;
        try {
          final json =
              jsonDecode(utf8.decode(datagram.data)) as Map<String, dynamic>;
          if (json['magic'] != 'nshare-discover' ||
              json['version'] != protocolVersion)
            continue;
          final request = requiredString(json, 'request', max: 64);
          final now = DateTime.now();
          recent.removeWhere((_, time) => now.difference(time).inSeconds > 2);
          final key = '${datagram.address.address}:${datagram.port}';
          if (recent.containsKey(key) || recent.length >= 256) continue;
          recent[key] = now;
          final response = utf8.encode(
            jsonEncode({
              'magic': 'nshare-device',
              'version': protocolVersion,
              'request': request,
              'name': identity.name,
              'fingerprint': identity.fingerprint,
              'port': transferPort,
            }),
          );
          socket.send(response, datagram.address, datagram.port);
        } catch (_) {
          /* Ignore malformed unauthenticated discovery datagrams. */
        }
      }
    });
    return DiscoveryService._(socket, subscription);
  }

  Future<void> close() async {
    _socket.close();
    await _subscription.cancel();
  }
}

Future<List<DiscoveredDevice>> discoverDevices({
  int port = 1970,
  Duration duration = const Duration(seconds: 3),
  InternetAddress? target,
}) async {
  final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  socket.broadcastEnabled = true;
  final request = randomNonce();
  final devices = <String, DiscoveredDevice>{};
  final message = utf8.encode(
    jsonEncode({
      'magic': 'nshare-discover',
      'version': protocolVersion,
      'request': request,
    }),
  );
  final subscription = socket.listen((event) {
    if (event != RawSocketEvent.read) return;
    Datagram? packet;
    while ((packet = socket.receive()) != null) {
      final datagram = packet!;
      if (datagram.data.length > 2048) continue;
      try {
        final json =
            jsonDecode(utf8.decode(datagram.data)) as Map<String, dynamic>;
        if (json['magic'] != 'nshare-device' ||
            json['version'] != protocolVersion ||
            json['request'] != request)
          continue;
        final fingerprint = requiredString(json, 'fingerprint', max: 64);
        if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(fingerprint)) continue;
        final transferPort = requiredInt(json, 'port', max: 65535);
        if (transferPort == 0 || devices.length >= 256) continue;
        devices[fingerprint] = DiscoveredDevice(
          requiredString(json, 'name', max: 255),
          fingerprint,
          datagram.address.address,
          transferPort,
        );
      } catch (_) {
        /* Discovery results are untrusted hints only. */
      }
    }
  });
  void send() {
    socket.send(message, target ?? InternetAddress('255.255.255.255'), port);
  }

  final timer = Timer.periodic(const Duration(seconds: 1), (_) => send());
  try {
    send();
    await Future<void>.delayed(duration);
  } finally {
    timer.cancel();
    socket.close();
    await subscription.cancel();
  }
  return devices.values.toList()
    ..sort((a, b) => a.fingerprint.compareTo(b.fingerprint));
}

DiscoveredDevice selectDevice(
  List<DiscoveredDevice> devices,
  String? fingerprint,
) {
  final matches = fingerprint == null
      ? devices
      : devices.where((d) => d.fingerprint == fingerprint).toList();
  if (matches.isEmpty)
    throw const NshareException(
      'discovery',
      'No matching receiver found; try a direct --ip address',
    );
  if (matches.length != 1)
    throw const NshareException(
      'discovery',
      'Multiple receivers found; select one with --to <full fingerprint>',
    );
  return matches.single;
}
