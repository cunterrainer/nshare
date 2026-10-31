import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:qr/qr.dart';
import '../core/models.dart';
import '../identity/identity.dart';
import 'state.dart';

class PairingInvitation {
  const PairingInvitation(
    this.host,
    this.port,
    this.fingerprint,
    this.token,
    this.expires,
  );
  final String host, fingerprint, token;
  final int port;
  final DateTime expires;
  Uri get uri => Uri(
    scheme: 'nshare',
    host: 'pair',
    queryParameters: {
      'v': '3',
      'host': host,
      'port': '$port',
      'fp': fingerprint,
      'token': token,
      'expires': '${expires.millisecondsSinceEpoch}',
    },
  );
  factory PairingInvitation.parse(String text, {DateTime? now}) {
    if (text.length > 2048) {
      throw const NshareException('pairing', 'Invitation too large');
    }
    final uri = Uri.tryParse(text);
    if (uri == null ||
        uri.scheme != 'nshare' ||
        uri.host != 'pair' ||
        uri.path.isNotEmpty ||
        uri.fragment.isNotEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort ||
        uri.queryParametersAll.length != 6 ||
        uri.queryParametersAll.values.any((v) => v.length != 1)) {
      throw const NshareException('pairing', 'Invalid pairing invitation');
    }
    final q = uri.queryParameters;
    final port = int.tryParse(q['port'] ?? '');
    final expires = int.tryParse(q['expires'] ?? '');
    final host = q['host'] ?? '';
    final instant = now ?? DateTime.now();
    if (q['v'] != '3' ||
        host.isEmpty ||
        host.length > 255 ||
        RegExp(r'[\s/\\?#@\x00-\x1f]').hasMatch(host) ||
        port == null ||
        port < 1 ||
        port > 65535 ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(q['fp'] ?? '') ||
        !RegExp(r'^[A-Za-z0-9_-]{43}=$').hasMatch(q['token'] ?? '') ||
        expires == null ||
        expires <= instant.millisecondsSinceEpoch ||
        expires >
            instant.add(const Duration(minutes: 10)).millisecondsSinceEpoch) {
      throw const NshareException(
        'pairing',
        'Expired or invalid pairing invitation',
      );
    }
    return PairingInvitation(
      host,
      port,
      q['fp']!,
      q['token']!,
      DateTime.fromMillisecondsSinceEpoch(expires),
    );
  }
  String get terminalQr {
    final image = QrImage(
      QrCode.fromData(
        data: uri.toString(),
        errorCorrectLevel: QrErrorCorrectLevel.M,
      ),
    );
    final out = StringBuffer();
    // Black modules on an explicit white quiet zone; no terminal theme dependence.
    bool dark(int x, int y) =>
        x >= 0 &&
        y >= 0 &&
        x < image.moduleCount &&
        y < image.moduleCount &&
        image.isDark(y, x);
    for (var y = -4; y < image.moduleCount + 4; y += 2) {
      for (var x = -4; x < image.moduleCount + 4; x++) {
        // Half-block cells keep modules square and fit ordinary 80-column terminals.
        out.write('\x1b[${dark(x, y) ? 30 : 37};${dark(x, y + 1) ? 40 : 47}m▀');
      }
      out.writeln('\x1b[0m');
    }
    return out.toString();
  }

  String get svg {
    final image = QrImage(
      QrCode.fromData(
        data: uri.toString(),
        errorCorrectLevel: QrErrorCorrectLevel.M,
      ),
    );
    final size = image.moduleCount + 8;
    final out = StringBuffer(
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 $size $size" shape-rendering="crispEdges"><rect width="$size" height="$size" fill="white"/><g fill="black">',
    );
    for (var y = 0; y < image.moduleCount; y++) {
      for (var x = 0; x < image.moduleCount; x++) {
        if (image.isDark(y, x)) {
          out.write('<rect x="${x + 4}" y="${y + 4}" width="1" height="1"/>');
        }
      }
    }
    return '$out</g></svg>';
  }
}

class InvitationStore {
  InvitationStore(Directory directory)
    : _store = StateStore(directory, 'invitations');
  final StateStore _store;
  Future<PairingInvitation> issue(
    String host,
    int port,
    String fingerprint, {
    DateTime? now,
  }) async {
    final instant = now ?? DateTime.now();
    final invite = PairingInvitation(
      host,
      port,
      fingerprint,
      randomNonce(),
      instant.add(const Duration(minutes: 5)),
    );
    PairingInvitation.parse(invite.uri.toString(), now: instant);
    await _store.update((data) {
      data.removeWhere(
        (key, value) =>
            key != 'version' &&
            (value is! int || value <= instant.millisecondsSinceEpoch),
      );
      if (data.length > 32) {
        throw const NshareException('limit', 'Too many live invitations');
      }
      data[_key(invite.token)] = invite.expires.millisecondsSinceEpoch;
    });
    return invite;
  }

  Future<void> consume(String token, {DateTime? now}) => _store.update((data) {
    final expiry = data.remove(_key(token));
    if (expiry is! int ||
        expiry <= (now ?? DateTime.now()).millisecondsSinceEpoch) {
      throw const NshareException(
        'pairing',
        'Invitation expired, unknown or already used',
      );
    }
  });
  static String _key(String token) =>
      sha256.convert(utf8.encode(token)).toString();
}
