import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';
import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import '../core/models.dart';
import '../protocol/protocol.dart';

String fingerprintOfPem(String pem) =>
    sha256.convert(CryptoUtils.getBytesFromPEMString(pem)).toString();
String randomNonce() => base64Url.encode(
  List<int>.generate(32, (_) => Random.secure().nextInt(256)),
);

Future<void> privatePath(String path, {bool directory = false}) async {
  if (!Platform.isWindows) {
    final result = await Process.run('chmod', [
      directory ? '700' : '600',
      path,
    ]);
    if (result.exitCode != 0)
      throw const NshareException(
        'permissions',
        'Cannot restrict local state permissions',
      );
  }
}

Future<void> atomicJson(File file, Object value) async {
  final temp = File('${file.path}.${randomNonce().replaceAll('=', '')}.tmp');
  try {
    await temp.writeAsString(jsonEncode(value), flush: true);
    await privatePath(temp.path);
    await temp.rename(file.path);
  } finally {
    if (await temp.exists()) await temp.delete();
  }
}

class DeviceIdentity {
  DeviceIdentity._(
    this.directory,
    this.name,
    this.certificate,
    this.privateKey,
  );
  final Directory directory;
  final String name;
  final String certificate;
  final String privateKey;
  String get fingerprint => fingerprintOfPem(certificate);
  PeerIdentity get peer => PeerIdentity(name, fingerprint);

  static Future<DeviceIdentity> load(Directory directory) async {
    await directory.create(recursive: true);
    await privatePath(directory.path, directory: true);
    final lock = await File(
      p.join(directory.path, 'identity.lock'),
    ).open(mode: FileMode.append);
    await lock.lock(FileLock.blockingExclusive);
    try {
      final file = File(p.join(directory.path, 'identity.json'));
      if (!await file.exists()) {
        final generated = await Isolate.run(() {
          final pair = CryptoUtils.generateRSAKeyPair(keySize: 2048);
          final private = pair.privateKey as RSAPrivateKey;
          final public = pair.publicKey as RSAPublicKey;
          final csr = X509Utils.generateRsaCsrPem(
            {'CN': 'nshare'},
            private,
            public,
          );
          return {
            'name': Platform.localHostname,
            'certificate': X509Utils.generateSelfSignedCertificate(
              private,
              csr,
              3650,
              cA: false,
              serialNumber: BigInt.parse(
                sha256
                    .convert(utf8.encode(randomNonce()))
                    .toString()
                    .substring(0, 30),
                radix: 16,
              ).toString(),
            ),
            'privateKey': CryptoUtils.encodeRSAPrivateKeyToPem(private),
          };
        });
        await atomicJson(file, generated);
      }
      final data =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final identity = DeviceIdentity._(
        directory,
        requiredString(data, 'name'),
        requiredString(data, 'certificate', max: 16384),
        requiredString(data, 'privateKey', max: 16384),
      );
      final challenge = utf8.encode('nshare identity validation');
      if (!verifyProof(
        identity.certificate,
        challenge,
        identity.sign(challenge),
      )) {
        throw const NshareException(
          'identity',
          'Stored certificate and private key do not match',
        );
      }
      return identity;
    } finally {
      await lock.unlock();
      await lock.close();
    }
  }

  SecurityContext get serverContext => SecurityContext(withTrustedRoots: false)
    ..useCertificateChainBytes(utf8.encode(certificate))
    ..usePrivateKeyBytes(utf8.encode(privateKey));

  Uint8List sign(List<int> bytes) => CryptoUtils.rsaSign(
    CryptoUtils.rsaPrivateKeyFromPem(privateKey),
    Uint8List.fromList(bytes),
  );
}

bool verifyProof(
  String certificate,
  List<int> transcript,
  List<int> signature,
) {
  try {
    final data = X509Utils.x509CertificateFromPem(certificate);
    final exponent = data.tbsCertificate!.subjectPublicKeyInfo.exponent;
    if (data.tbsCertificate!.subjectPublicKeyInfo.length! < 2048 ||
        exponent == null)
      return false;
    final key = RSAPublicKey(
      X509Utils.getModulusFromRSAX509Pem(certificate),
      BigInt.from(exponent),
    );
    return CryptoUtils.rsaVerify(
      key,
      Uint8List.fromList(transcript),
      Uint8List.fromList(signature),
    );
  } catch (_) {
    return false;
  }
}

class TrustStore {
  TrustStore(this.directory);
  final Directory directory;
  File get _file => File(p.join(directory.path, 'trust.json'));
  Future<Map<String, dynamic>> list() async => await _file.exists()
      ? Map<String, dynamic>.from(jsonDecode(await _file.readAsString()) as Map)
      : <String, dynamic>{};
  Future<void> forget(String fingerprint) async {
    final peers = await list()
      ..remove(fingerprint);
    await atomicJson(_file, peers);
  }

  Future<void> approve(
    PeerIdentity peer,
    PairingApproval? approval, {
    String? expectedFingerprint,
    String? endpoint,
  }) async {
    final peers = await list();
    if (expectedFingerprint != null &&
        peer.fingerprint != expectedFingerprint.toLowerCase()) {
      throw const NshareException(
        'identity',
        'Peer fingerprint does not match the verified fingerprint',
      );
    }
    for (final entry in peers.entries) {
      if (endpoint != null &&
          ((entry.value as Map)['endpoints'] as List? ?? []).contains(
            endpoint,
          ) &&
          entry.key != peer.fingerprint) {
        throw const NshareException(
          'identity',
          'Device identity changed at this address; forget old trust only after verifying the change',
        );
      }
    }
    if (peers.containsKey(peer.fingerprint)) {
      if (endpoint != null) {
        final entry = Map<String, dynamic>.from(peers[peer.fingerprint] as Map);
        final endpoints = List<String>.from(entry['endpoints'] as List? ?? []);
        if (!endpoints.contains(endpoint)) {
          entry['endpoints'] = [...endpoints, endpoint];
          peers[peer.fingerprint] = entry;
          await atomicJson(_file, peers);
        }
      }
      return;
    }
    if (expectedFingerprint == null &&
        (approval == null || !await approval(peer))) {
      throw const NshareException(
        'untrusted',
        'Peer fingerprint requires out-of-band verification',
      );
    }
    peers[peer.fingerprint] = {
      'name': peer.name,
      'endpoints': [if (endpoint != null) endpoint],
    };
    await atomicJson(_file, peers);
  }
}

List<int> _transcript(
  String client,
  String server,
  String clientNonce,
  String serverNonce,
) => utf8.encode(
  jsonEncode([
    'nshare-v2-client-proof',
    client,
    server,
    clientNonce,
    serverNonce,
  ]),
);

Future<WireConnection> connectAuthenticated(
  String host,
  int port,
  DeviceIdentity identity,
  TrustStore trust, {
  PairingApproval? approve,
  String? expectedFingerprint,
  CancellationToken? cancellation,
}) async {
  final known = await trust.list();
  final endpoint = '$host:$port';
  final pins = known.entries
      .where(
        (e) =>
            ((e.value as Map)['endpoints'] as List? ?? []).contains(endpoint),
      )
      .map((e) => e.key)
      .toSet();
  bool certificateAllowed(X509Certificate cert) {
    final fingerprint = sha256.convert(cert.der).toString();
    final now = DateTime.now();
    return now.isAfter(cert.startValidity) &&
        now.isBefore(cert.endValidity) &&
        (pins.isEmpty || pins.contains(fingerprint)) &&
        (expectedFingerprint == null ||
            fingerprint == expectedFingerprint.toLowerCase()) &&
        (known.containsKey(fingerprint) ||
            expectedFingerprint != null ||
            approve != null);
  }

  final socket = await SecureSocket.connect(
    host,
    port,
    context: SecurityContext(withTrustedRoots: false),
    onBadCertificate: certificateAllowed,
    timeout: const Duration(seconds: 10),
  );
  final wire = WireConnection(socket, cancellation: cancellation);
  try {
    final cert = socket.peerCertificate!;
    if (!certificateAllowed(cert))
      throw const NshareException('identity', 'Peer certificate rejected');
    final receiver = PeerIdentity(host, sha256.convert(cert.der).toString());
    await wire.waitFor(
      trust.approve(
        receiver,
        approve,
        expectedFingerprint: expectedFingerprint,
        endpoint: endpoint,
      ),
    );
    final clientNonce = randomNonce();
    await wire.send(WireType.hello, {
      'name': identity.name,
      'certificate': identity.certificate,
      'nonce': clientNonce,
    });
    final challenge = await wire.expect(
      WireType.challenge,
      wait: const Duration(minutes: 5),
    );
    final serverNonce = requiredString(challenge, 'nonce', max: 64);
    await wire.send(WireType.proof, {
      'signature': base64.encode(
        identity.sign(
          _transcript(
            identity.fingerprint,
            receiver.fingerprint,
            clientNonce,
            serverNonce,
          ),
        ),
      ),
    });
    await wire.expect(WireType.ready, wait: const Duration(minutes: 5));
    return wire;
  } catch (_) {
    await wire.close();
    rethrow;
  }
}

Future<PeerIdentity> authenticateIncoming(
  WireConnection wire,
  DeviceIdentity identity,
  TrustStore trust, {
  PairingApproval? approve,
  String? expectedFingerprint,
}) async {
  final hello = await wire.expect(
    WireType.hello,
    wait: const Duration(minutes: 5),
  );
  final certificate = requiredString(hello, 'certificate', max: 16384);
  final peer = PeerIdentity(
    requiredString(hello, 'name', max: 255),
    fingerprintOfPem(certificate),
  );
  final clientNonce = requiredString(hello, 'nonce', max: 64);
  final serverNonce = randomNonce();
  await wire.send(WireType.challenge, {'nonce': serverNonce});
  final proof = await wire.expect(WireType.proof);
  final signature = base64.decode(
    requiredString(proof, 'signature', max: 4096),
  );
  if (!verifyProof(
    certificate,
    _transcript(
      peer.fingerprint,
      identity.fingerprint,
      clientNonce,
      serverNonce,
    ),
    signature,
  )) {
    throw const NshareException('identity', 'Peer failed identity proof');
  }
  await wire.waitFor(
    trust.approve(peer, approve, expectedFingerprint: expectedFingerprint),
  );
  await wire.send(WireType.ready, {'version': protocolVersion});
  return peer;
}
