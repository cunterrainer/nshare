import 'dart:convert';
import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'dart:async';
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
  if (Platform.isWindows) return;
  final nativePath = path.toNativeUtf8();
  try {
    final chmod = DynamicLibrary.process()
        .lookupFunction<
          Int32 Function(Pointer<Utf8>, Uint32),
          int Function(Pointer<Utf8>, int)
        >('chmod');
    if (chmod(nativePath, directory ? 448 : 384) != 0) {
      throw const NshareException(
        'permissions',
        'Cannot restrict local state permissions',
      );
    }
  } finally {
    malloc.free(nativePath);
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
        exponent == null) {
      return false;
    }
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
  static final _queues = <String, Future<void>>{};

  Future<void> _mutate(Future<void> Function(Map<String, dynamic>) action) {
    final key = p.normalize(p.absolute(directory.path));
    final previous = _queues[key] ?? Future<void>.value();
    final result = previous.then((_) async {
      final lock = await File(
        p.join(directory.path, 'trust.lock'),
      ).open(mode: FileMode.append);
      await lock.lock(FileLock.blockingExclusive);
      try {
        final peers = await list();
        await action(peers);
        await atomicJson(_file, peers);
      } finally {
        await lock.unlock();
        await lock.close();
      }
    });
    final tail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _queues[key] = tail;
    unawaited(
      tail.then((_) {
        if (identical(_queues[key], tail)) _queues.remove(key);
      }),
    );
    return result;
  }

  Future<void> forget(String fingerprint) => _mutate((peers) async {
    peers.remove(fingerprint);
  });

  void _validatePin(
    Map<String, dynamic> peers,
    PeerIdentity peer,
    String? expectedFingerprint,
    String? endpoint,
  ) {
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
  }

  Future<void> approve(
    PeerIdentity peer,
    PairingApproval? approval, {
    String? expectedFingerprint,
    String? endpoint,
    bool persist = true,
    bool forceApproval = false,
  }) async {
    final snapshot = await list();
    _validatePin(snapshot, peer, expectedFingerprint, endpoint);
    // Never hold an OS lock (or a timeout timer) while a UI decision is pending.
    // The connection owns the approval deadline and cancellation race.
    if ((forceApproval ||
            (!snapshot.containsKey(peer.fingerprint) &&
                expectedFingerprint == null)) &&
        (approval == null || !await approval(peer))) {
      throw const NshareException(
        'untrusted',
        'Peer fingerprint requires out-of-band verification',
      );
    }
    if (!persist) return;
    await _mutate((peers) async {
      _validatePin(peers, peer, expectedFingerprint, endpoint);
      final entry = peers.containsKey(peer.fingerprint)
          ? Map<String, dynamic>.from(peers[peer.fingerprint] as Map)
          : <String, dynamic>{'name': peer.name, 'endpoints': <String>[]};
      final endpoints = List<String>.from(entry['endpoints'] as List? ?? []);
      if (endpoint != null && !endpoints.contains(endpoint)) {
        endpoints.add(endpoint);
      }
      entry['endpoints'] = endpoints;
      peers[peer.fingerprint] = entry;
    });
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

// The client commits before learning the server nonce. Both certificate pins,
// both nonces and the revealed 256-bit secret are bound into the signed proof.
List<int> _codeTranscript(
  String client,
  String server,
  String clientNonce,
  String serverNonce,
  String secret,
) => utf8.encode(
  jsonEncode([
    'nshare-confirmation-code-v1',
    client,
    server,
    clientNonce,
    serverNonce,
    secret,
  ]),
);
String _codeCommit(String client, String server, String nonce, String secret) =>
    sha256
        .convert(
          utf8.encode(
            jsonEncode([
              'nshare-confirmation-commit-v1',
              client,
              server,
              nonce,
              secret,
            ]),
          ),
        )
        .toString();
String _matchingCode(List<int> transcript) {
  final digest = sha256.convert(transcript).bytes;
  var value = 0;
  for (final byte in digest.take(5)) {
    value = (value << 8) | byte;
  }
  // Fixed width, approximately 40 bits. It is a comparison, never a password.
  final digits = value.toString().padLeft(13, '0');
  return '${digits.substring(0, 4)} ${digits.substring(4, 8)} ${digits.substring(8)}';
}

Future<WireConnection> connectAuthenticated(
  String host,
  int port,
  DeviceIdentity identity,
  TrustStore trust, {
  PairingApproval? approve,
  String? expectedFingerprint,
  String? targetFingerprint,
  CancellationToken? cancellation,
  bool requireConfirmationCode = false,
}) async {
  cancellation?.check();
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
        (targetFingerprint == null || fingerprint == targetFingerprint) &&
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
    if (!certificateAllowed(cert)) {
      throw const NshareException('identity', 'Peer certificate rejected');
    }
    var receiver = PeerIdentity(host, sha256.convert(cert.der).toString());
    if (!requireConfirmationCode) {
      await wire.waitFor(
        trust.approve(
          receiver,
          approve,
          expectedFingerprint: expectedFingerprint,
          endpoint: endpoint,
        ),
      );
    }
    final clientNonce = randomNonce();
    final secret = requireConfirmationCode ? randomNonce() : null;
    await wire.send(WireType.hello, {
      'name': identity.name,
      'certificate': identity.certificate,
      'nonce': clientNonce,
      if (secret != null)
        'codeCommit': _codeCommit(
          identity.fingerprint,
          receiver.fingerprint,
          clientNonce,
          secret,
        ),
      'extensions': supportedExtensions.toList(),
    });
    final challenge = await wire.expect(
      WireType.challenge,
      wait: const Duration(minutes: 5),
    );
    final serverNonce = requiredString(challenge, 'nonce', max: 64);
    if (requireConfirmationCode && challenge['confirmationCode'] != true) {
      throw const NshareException(
        'unsupported',
        'Peer does not support matching confirmation codes; use a verified invitation or full fingerprint',
      );
    }
    final transcript = secret == null
        ? _transcript(
            identity.fingerprint,
            receiver.fingerprint,
            clientNonce,
            serverNonce,
          )
        : _codeTranscript(
            identity.fingerprint,
            receiver.fingerprint,
            clientNonce,
            serverNonce,
            secret,
          );
    await wire.send(WireType.proof, {
      'codeSecret': ?secret,
      'signature': base64.encode(identity.sign(transcript)),
    });
    if (secret != null) {
      receiver = PeerIdentity(
        host,
        receiver.fingerprint,
        confirmationCode: _matchingCode(transcript),
      );
      await wire.waitFor(
        trust.approve(
          receiver,
          approve,
          expectedFingerprint: expectedFingerprint,
          endpoint: endpoint,
          persist: false,
          forceApproval: true,
        ),
      );
    }
    final ready = await wire.expect(
      WireType.ready,
      wait: const Duration(minutes: 5),
    );
    wire.extensions = parseExtensions(ready['extensions']);
    if (secret != null) {
      wire.require('confirmation-code-v1');
      await wire.send(WireType.authConfirm, {'approved': true});
      final confirmed = await wire.expect(
        WireType.ready,
        wait: const Duration(minutes: 5),
      );
      if (confirmed['confirmed'] != true) {
        throw const NshareException(
          'protocol',
          'Missing mutual code confirmation',
        );
      }
      await trust.approve(
        receiver,
        null,
        expectedFingerprint: receiver.fingerprint,
        endpoint: endpoint,
      );
      wire.confirmationCodeVerified = true;
    }
    wire.remotePeer = receiver;
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
  wire.extensions = parseExtensions(hello['extensions']);
  final certificate = requiredString(hello, 'certificate', max: 16384);
  var peer = PeerIdentity(
    requiredString(hello, 'name', max: 255),
    fingerprintOfPem(certificate),
  );
  final clientNonce = requiredString(hello, 'nonce', max: 64);
  final commitment = hello['codeCommit'];
  if (commitment != null &&
      (commitment is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(commitment))) {
    throw const NshareException('protocol', 'Invalid confirmation commitment');
  }
  if (commitment != null) wire.require('confirmation-code-v1');
  final serverNonce = randomNonce();
  await wire.send(WireType.challenge, {
    'nonce': serverNonce,
    if (commitment != null) 'confirmationCode': true,
  });
  final proof = await wire.expect(WireType.proof);
  final signature = base64.decode(
    requiredString(proof, 'signature', max: 4096),
  );
  final secret = commitment == null
      ? null
      : requiredString(proof, 'codeSecret', max: 64);
  if (secret != null &&
      (!RegExp(r'^[A-Za-z0-9_-]{43}=$').hasMatch(secret) ||
          _codeCommit(
                peer.fingerprint,
                identity.fingerprint,
                clientNonce,
                secret,
              ) !=
              commitment)) {
    throw const NshareException(
      'identity',
      'Confirmation commitment does not match',
    );
  }
  final transcript = secret == null
      ? _transcript(
          peer.fingerprint,
          identity.fingerprint,
          clientNonce,
          serverNonce,
        )
      : _codeTranscript(
          peer.fingerprint,
          identity.fingerprint,
          clientNonce,
          serverNonce,
          secret,
        );
  if (!verifyProof(certificate, transcript, signature)) {
    throw const NshareException('identity', 'Peer failed identity proof');
  }
  if (secret != null) {
    peer = PeerIdentity(
      peer.name,
      peer.fingerprint,
      confirmationCode: _matchingCode(transcript),
    );
  }
  await wire.waitFor(
    trust.approve(
      peer,
      approve,
      expectedFingerprint: expectedFingerprint,
      persist: secret == null,
      forceApproval: secret != null,
    ),
  );
  await wire.send(WireType.ready, {
    'version': protocolVersion,
    'extensions': wire.extensions.toList(),
  });
  if (secret != null) {
    final confirmed = await wire.expect(
      WireType.authConfirm,
      wait: const Duration(minutes: 5),
    );
    if (confirmed['approved'] != true) {
      throw const NshareException(
        'untrusted',
        'Peer did not confirm matching code',
      );
    }
    await trust.approve(peer, null, expectedFingerprint: peer.fingerprint);
    await wire.send(WireType.ready, {'confirmed': true});
    wire.confirmationCodeVerified = true;
  }
  wire.remotePeer = peer;
  return peer;
}
