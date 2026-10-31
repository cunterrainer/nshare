import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import '../identity/identity.dart';
import 'discovery.dart';

const mdnsServiceName = '_nshare._tcp.local';
final _group = InternetAddress('224.0.0.251');
final _group6 = InternetAddress('ff02::fb');
Future<List<NetworkInterface>> _join(
  RawDatagramSocket socket,
  InternetAddress group,
) async {
  final interfaces = await NetworkInterface.list(
    type: group.type,
    includeLinkLocal: true,
  );
  final joined = <NetworkInterface>[];
  for (final interface in interfaces) {
    try {
      socket.joinMulticast(group, interface);
      joined.add(interface);
    } catch (_) {}
  }
  if (joined.isEmpty) socket.joinMulticast(group);
  return joined;
}

void _multicast(
  RawDatagramSocket socket,
  InternetAddress group,
  List<NetworkInterface> interfaces,
  List<int> packet,
) {
  if (interfaces.isEmpty) {
    socket.send(packet, group, 5353);
    return;
  }
  for (final interface in interfaces) {
    try {
      if (group.type == InternetAddressType.IPv4) {
        final address = interface.addresses.firstWhere(
          (a) => a.type == InternetAddressType.IPv4,
        );
        socket.setRawOption(
          RawSocketOption(
            RawSocketOption.levelIPv4,
            RawSocketOption.IPv4MulticastInterface,
            address.rawAddress,
          ),
        );
        socket.send(packet, group, 5353);
      } else {
        socket.setRawOption(
          RawSocketOption.fromInt(
            RawSocketOption.levelIPv6,
            RawSocketOption.IPv6MulticastInterface,
            interface.index,
          ),
        );
        socket.send(
          packet,
          InternetAddress('${group.address}%${interface.index}'),
          5353,
        );
      }
    } catch (_) {}
  }
}

List<int> _name(String value) => [
  for (final part in value.split('.')) ...[
    utf8.encode(part).length,
    ...utf8.encode(part),
  ],
  0,
];
List<int> _u16(int value) => [value >> 8, value & 255];
List<int> _u32(int value) => [
  value >> 24,
  (value >> 16) & 255,
  (value >> 8) & 255,
  value & 255,
];
Uint8List mdnsQuery() => Uint8List.fromList([
  0,
  0,
  0,
  0,
  0,
  1,
  0,
  0,
  0,
  0,
  0,
  0,
  ..._name(mdnsServiceName),
  0,
  12,
  0,
  1,
]);
Uint8List mdnsAdvertisement(
  String fingerprint,
  String name,
  int port, {
  int ttl = 120,
}) {
  final instance = '${fingerprint.substring(0, 12)}.$mdnsServiceName';
  final host = 'nshare-${fingerprint.substring(0, 12)}.local';
  List<int> record(String owner, int type, List<int> data) => [
    ..._name(owner),
    ..._u16(type),
    0,
    1,
    ..._u32(ttl),
    ..._u16(data.length),
    ...data,
  ];
  final txt = [
    'fp=$fingerprint',
    'name=${name.replaceAll(RegExp(r'[\x00-\x1f]'), '?')}',
    'version=3',
  ];
  final fields = <int>[];
  for (final field in txt) {
    final bytes = utf8.encode(field);
    if (bytes.length > 255) continue;
    fields.addAll([bytes.length, ...bytes]);
  }
  return Uint8List.fromList([
    0,
    0,
    0x84,
    0,
    0,
    0,
    0,
    3,
    0,
    0,
    0,
    0,
    ...record(mdnsServiceName, 12, _name(instance)),
    ...record(instance, 33, [0, 0, 0, 0, ..._u16(port), ..._name(host)]),
    ...record(instance, 16, fields),
  ]);
}

class _Reader {
  _Reader(this.bytes);
  final Uint8List bytes;
  int position = 0;
  int u16() {
    if (position + 2 > bytes.length) throw const FormatException();
    final v = ByteData.sublistView(bytes).getUint16(position, Endian.big);
    position += 2;
    return v;
  }

  int u32() {
    if (position + 4 > bytes.length) throw const FormatException();
    final v = ByteData.sublistView(bytes).getUint32(position, Endian.big);
    position += 4;
    return v;
  }

  String name() {
    final parts = <String>[];
    var offset = position;
    int? resume;
    var steps = 0, total = 0;
    while (true) {
      if (offset >= bytes.length || ++steps > 128) {
        throw const FormatException();
      }
      final length = bytes[offset++];
      if (length == 0) break;
      if (length & 0xc0 == 0xc0) {
        if (offset >= bytes.length) throw const FormatException();
        resume ??= offset + 1;
        offset = ((length & 63) << 8) | bytes[offset];
        continue;
      }
      if (length > 63 ||
          offset + length > bytes.length ||
          (total += length + 1) > 255) {
        throw const FormatException();
      }
      parts.add(utf8.decode(bytes.sublist(offset, offset + length)));
      offset += length;
    }
    position = resume ?? offset;
    return parts.join('.').toLowerCase();
  }
}

/// Parse only a complete DNS-SD response; all returned identities are untrusted.
DiscoveredDevice? parseMdns(Uint8List packet, String address) {
  try {
    if (packet.length < 12 || packet.length > 9000) return null;
    final r = _Reader(packet);
    r.u16();
    final flags = r.u16();
    if (flags & 0x8000 == 0) return null;
    final questions = r.u16();
    final records = r.u16() + r.u16() + r.u16();
    if (questions > 64 || records > 128) return null;
    for (var i = 0; i < questions; i++) {
      r.name();
      r.u16();
      r.u16();
    }
    final instances = <String>{};
    final ports = <String, int>{};
    final metadata = <String, Map<String, String>>{};
    for (var i = 0; i < records; i++) {
      final owner = r.name();
      final type = r.u16();
      r.u16();
      final ttl = r.u32();
      final length = r.u16();
      final end = r.position + length;
      if (end > packet.length) return null;
      if (ttl > 0) {
        if (type == 12 && owner == mdnsServiceName) {
          instances.add(r.name());
        } else if (type == 33 && length >= 7) {
          r.u16();
          r.u16();
          ports[owner] = r.u16();
          r.name();
        } else if (type == 16) {
          final fields = <String, String>{};
          while (r.position < end) {
            final size = packet[r.position++];
            if (r.position + size > end) return null;
            final value = utf8.decode(
              packet.sublist(r.position, r.position + size),
            );
            r.position += size;
            final split = value.indexOf('=');
            if (split > 0) {
              fields[value.substring(0, split)] = value.substring(split + 1);
            }
          }
          metadata[owner] = fields;
        }
        if (r.position > end) return null;
      }
      r.position = end;
    }
    for (final instance in instances) {
      final fields = metadata[instance];
      final port = ports[instance];
      final pin = fields?['fp'];
      if (fields != null &&
          fields['version'] == '3' &&
          pin != null &&
          RegExp(r'^[0-9a-f]{64}$').hasMatch(pin) &&
          port != null &&
          port > 0 &&
          fields['name'] != null &&
          fields['name']!.isNotEmpty &&
          fields['name']!.length <= 255) {
        return DiscoveredDevice(fields['name']!, pin, address, port);
      }
    }
  } catch (_) {
    /* Unauthenticated multicast noise must not terminate discovery. */
  }
  return null;
}

class MdnsAdvertiser {
  MdnsAdvertiser._(this.socket, this.subscription, this.packet, this.timer);
  final RawDatagramSocket socket;
  final StreamSubscription<RawSocketEvent> subscription;
  final Uint8List packet;
  final Timer timer;
  static Future<MdnsAdvertiser> start(
    DeviceIdentity identity,
    int port, {
    bool ipv6 = false,
  }) async {
    final group = ipv6 ? _group6 : _group;
    final socket = await RawDatagramSocket.bind(
      (ipv6 ? InternetAddress.anyIPv6 : InternetAddress.anyIPv4),
      5353,
      reuseAddress: true,
      reusePort: true,
    );
    socket.multicastHops = 255;
    late final List<NetworkInterface> interfaces;
    try {
      interfaces = await _join(socket, group);
    } catch (_) {
      socket.close();
      rethrow;
    }
    final packet = mdnsAdvertisement(identity.fingerprint, identity.name, port);
    void advertise() {
      try {
        _multicast(socket, group, interfaces, packet);
      } catch (_) {}
    }

    var previous = DateTime.fromMillisecondsSinceEpoch(0);
    final sub = socket.listen(
      (event) {
        if (event != RawSocketEvent.read) return;
        Datagram? datagram;
        while ((datagram = socket.receive()) != null) {
          final data = datagram!.data;
          if (data.length < 12 || data.length > 9000 || data[2] & 0x80 != 0) {
            continue;
          }
          try {
            final r = _Reader(data)..position = 4;
            final count = r.u16();
            r.position = 12;
            if (count > 64) continue;
            for (var i = 0; i < count; i++) {
              final name = r.name();
              final type = r.u16();
              r.u16();
              if (name == mdnsServiceName &&
                  (type == 12 || type == 255) &&
                  DateTime.now().difference(previous).inMilliseconds > 250) {
                previous = DateTime.now();
                advertise();
              }
            }
          } catch (_) {}
        }
      },
      onError: (Object error) {
        /* Multicast interfaces may disappear asynchronously. */
      },
    );
    advertise();
    final timer = Timer.periodic(
      const Duration(seconds: 60),
      (_) => advertise(),
    );
    return MdnsAdvertiser._(socket, sub, packet, timer);
  }

  Future<void> close() async {
    timer.cancel();
    socket.close();
    await subscription.cancel();
  }
}

Future<List<DiscoveredDevice>> discoverMdns({
  Duration duration = const Duration(seconds: 3),
  bool ipv6 = false,
}) async {
  final group = ipv6 ? _group6 : _group;
  final socket = await RawDatagramSocket.bind(
    (ipv6 ? InternetAddress.anyIPv6 : InternetAddress.anyIPv4),
    5353,
    reuseAddress: true,
    reusePort: true,
  );
  final devices = <String, DiscoveredDevice>{};
  late final StreamSubscription<RawSocketEvent> sub;
  try {
    final interfaces = await _join(socket, group);
    socket.multicastHops = 255;
    sub = socket.listen(
      (event) {
        if (event != RawSocketEvent.read) return;
        Datagram? packet;
        while ((packet = socket.receive()) != null) {
          final device = parseMdns(packet!.data, packet.address.address);
          if (device != null && devices.length < 256) {
            devices[device.fingerprint] = device;
          }
        }
      },
      onError: (Object error) {
        /* Missing multicast routes do not invalidate direct IP. */
      },
    );
    _multicast(socket, group, interfaces, mdnsQuery());
    await Future<void>.delayed(duration);
    await sub.cancel();
    return devices.values.toList();
  } finally {
    socket.close();
  }
}

/// Every refresh is a fresh bounded snapshot; absent devices expire naturally.
Future<List<DiscoveredDevice>> discoverNearby({
  int port = 1970,
  Duration duration = const Duration(seconds: 3),
  void Function(String)? onDiagnostic,
}) async {
  Future<List<DiscoveredDevice>> safe(
    String name,
    Future<List<DiscoveredDevice>> Function() run,
  ) async {
    try {
      return await run();
    } catch (_) {
      onDiagnostic?.call('$name unavailable; direct IP remains available');
      return [];
    }
  }

  final results = await Future.wait([
    safe('UDP', () => discoverDevices(port: port, duration: duration)),
    safe('IPv4 mDNS', () => discoverMdns(duration: duration)),
    safe('IPv6 mDNS', () => discoverMdns(duration: duration, ipv6: true)),
  ]);
  final devices = <String, DiscoveredDevice>{};
  for (final result in results) {
    for (final device in result) {
      devices.putIfAbsent(device.fingerprint, () => device);
    }
  }
  return devices.values.toList()..sort((a, b) => a.name.compareTo(b.name));
}

Stream<List<DiscoveredDevice>> watchNearby({
  int port = 1970,
  Duration interval = const Duration(seconds: 5),
}) async* {
  while (true) {
    yield await discoverNearby(port: port);
    await Future<void>.delayed(interval);
  }
}
