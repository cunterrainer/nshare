import 'dart:io';

class LocalAddress {
  const LocalAddress(this.interfaceName, this.address, this.family);
  final String interfaceName;
  final String address;
  final String family;
}

Future<List<LocalAddress>> localAddresses({
  bool includeLoopback = false,
}) async {
  final interfaces = await NetworkInterface.list(
    includeLoopback: includeLoopback,
    includeLinkLocal: true,
  );
  final addresses = <LocalAddress>[];
  for (final interface in interfaces) {
    for (final address in interface.addresses) {
      var value = address.address;
      if (address.type == InternetAddressType.IPv6 &&
          value.toLowerCase().startsWith('fe80:') &&
          !value.contains('%')) {
        value = '$value%${interface.name}';
      }
      addresses.add(
        LocalAddress(
          interface.name,
          value,
          address.type == InternetAddressType.IPv4 ? 'IPv4' : 'IPv6',
        ),
      );
    }
  }
  addresses.sort(
    (a, b) => '${a.interfaceName}/${a.family}/${a.address}'.compareTo(
      '${b.interfaceName}/${b.family}/${b.address}',
    ),
  );
  return addresses;
}
