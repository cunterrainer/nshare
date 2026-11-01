import '../core/file_lock.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import '../core/models.dart';
import '../application/sharing.dart';
import '../application/pairing.dart';
import '../discovery/discovery.dart';
import '../discovery/mdns.dart';
import '../identity/identity.dart';
import '../protocol/protocol.dart';
import '../protocol/compression.dart';
import '../storage/storage.dart';
import '../storage/paged_manifest.dart';

void _checkEntry(
  Map<String, dynamic> message,
  Manifest manifest,
  ManifestEntry entry,
) {
  if (message['transfer'] != manifest.id || message['entry'] != entry.id) {
    throw const NshareException(
      'protocol',
      'Unexpected transfer or entry identity',
    );
  }
}

Map<String, dynamic> _entryMessage(Manifest manifest, ManifestEntry entry) => {
  'transfer': manifest.id,
  'entry': entry.id,
};

Future<TransferResult> sendPath(
  String input,
  String host,
  int port,
  DeviceIdentity identity,
  TrustStore trust, {
  PairingApproval? approvePeer,
  String? expectedFingerprint,
  String? targetFingerprint,
  CancellationToken? cancellation,
  ProgressCallback? onProgress,
  bool resume = true,
  bool compression = false,
}) async {
  onProgress?.call(const TransferProgress(phase: TransferPhase.scanning));
  final scanClock = Stopwatch()..start();
  var scanned = 0;
  var scanPath = input;
  final manifest = await collectTransferManifest(
    input,
    cancellation: cancellation,
    onScan: (count, path) {
      scanned = count;
      scanPath = path;
      if (count == 1 || scanClock.elapsedMilliseconds >= 100) {
        onProgress?.call(
          TransferProgress(
            phase: TransferPhase.scanning,
            path: path,
            scannedEntries: count,
          ),
        );
        scanClock.reset();
      }
    },
  );
  onProgress?.call(
    TransferProgress(
      phase: TransferPhase.scanning,
      path: scanPath,
      scannedEntries: scanned,
    ),
  );
  onProgress?.call(
    TransferProgress(phase: TransferPhase.connecting, total: manifest.bytes),
  );
  late final WireConnection wire;
  try {
    wire = await connectAuthenticated(
      host,
      port,
      identity,
      trust,
      approve: approvePeer,
      expectedFingerprint: expectedFingerprint,
      targetFingerprint: targetFingerprint,
      cancellation: cancellation,
    );
  } catch (_) {
    await manifest.dispose();
    rethrow;
  }
  var acknowledged = false;
  try {
    onProgress?.call(
      TransferProgress(
        phase: TransferPhase.awaitingApproval,
        total: manifest.bytes,
      ),
    );
    if (compression) wire.require('block-gzip-v1');
    if (manifest is PagedManifest) {
      await manifest.send(wire, compression: compression);
    } else {
      await wire.send(WireType.offer, {
        ...manifest.toJson(),
        if (compression) 'compression': true,
      });
    }
    final accept = await wire.expect(
      WireType.accept,
      wait: const Duration(minutes: 5),
    );
    if (accept['transfer'] != manifest.id) {
      throw const NshareException('protocol', 'Unexpected accepted transfer');
    }
    if (compression && accept['compression'] != true) {
      throw const NshareException(
        'unsupported',
        'Receiver has not enabled compression',
      );
    }
    var files = 0, bytes = 0, skipped = 0, reused = 0, networkBytes = 0;
    final elapsed = Stopwatch()..start();
    await for (final entry in manifest.streamEntries()) {
      cancellation?.check();
      await wire.send(WireType.fileStart, {
        ..._entryMessage(manifest, entry),
        'resume': resume,
      });
      final accepted = await wire.expect(WireType.fileAccept);
      _checkEntry(accepted, manifest, entry);
      if (accepted['skip'] == true) {
        if (!entry.directory) skipped++;
        continue;
      }
      var offset = requiredInt(accepted, 'offset', max: entry.size);
      if (!resume && offset != 0) {
        throw const NshareException(
          'protocol',
          'Receiver ignored restart request',
        );
      }
      reused += offset;
      if (!entry.directory) {
        final source = File(entry.source!);
        if (await FileSystemEntity.type(source.path, followLinks: false) !=
                FileSystemEntityType.file ||
            await source.length() != entry.size) {
          throw const NshareException(
            'source',
            'Source changed since the offer was created',
          );
        }
        final prefix = offset == 0
            ? sha256.convert([]).toString()
            : await hashFile(source, end: offset, cancellation: cancellation);
        if (accepted['prefixHash'] != prefix) {
          throw const NshareException(
            'resume',
            'Retained data differs from source; retry with --no-resume to discard the partial file',
          );
        }
        final reader = await source.open();
        try {
          await reader.setPosition(offset);
          while (offset < entry.size) {
            cancellation?.check();
            final chunk = await reader.read(
              (entry.size - offset).clamp(0, maxChunkBytes),
            );
            if (chunk.isEmpty) {
              throw const NshareException('source', 'Source was truncated');
            }
            final payload = Uint8List(8 + chunk.length);
            ByteData.sublistView(payload).setUint64(0, offset, Endian.big);
            payload.setRange(8, payload.length, chunk);
            final packed = compression ? compressBlock(offset, chunk) : null;
            await wire.sendBytes(
              packed == null ? WireType.data : WireType.compressedData,
              packed ?? payload,
            );
            networkBytes += packed == null ? chunk.length : packed.length - 12;
            offset += chunk.length;
            bytes += chunk.length;
            onProgress?.call(
              TransferProgress(
                phase: TransferPhase.transferring,
                path: entry.path,
                networkBytes: networkBytes,
                bytes: bytes + reused,
                total: manifest.bytes,
                verifiedFiles: files,
                bytesPerSecond:
                    bytes *
                    1000000 /
                    elapsed.elapsedMicroseconds.clamp(1, 0x7fffffffffffffff),
              ),
            );
          }
        } finally {
          await reader.close();
        }
      }
      onProgress?.call(
        TransferProgress(
          phase: TransferPhase.verifying,
          path: entry.path,
          bytes: bytes + reused,
          total: manifest.bytes,
          verifiedFiles: files,
          networkBytes: networkBytes,
        ),
      );
      await wire.send(WireType.fileEnd, {
        ..._entryMessage(manifest, entry),
        'sha256': entry.hash,
      });
      final ack = await wire.expect(WireType.fileAck);
      _checkEntry(ack, manifest, entry);
      if (ack['sha256'] != entry.hash) {
        throw const NshareException(
          'integrity',
          'Receiver acknowledged a different digest',
        );
      }
      if (!entry.directory) files++;
      onProgress?.call(
        TransferProgress(
          phase: TransferPhase.transferring,
          path: entry.path,
          bytes: bytes + reused,
          total: manifest.bytes,
          verifiedFiles: files,
          networkBytes: networkBytes,
        ),
      );
    }
    await wire.send(WireType.complete, {
      'transfer': manifest.id,
      'files': files,
      'skipped': skipped,
    });
    final ack = await wire.expect(WireType.completeAck);
    if (ack['transfer'] != manifest.id ||
        ack['files'] != files ||
        ack['skipped'] != skipped) {
      throw const NshareException(
        'protocol',
        'Invalid completion acknowledgment',
      );
    }
    acknowledged = true;
    onProgress?.call(
      TransferProgress(
        phase: TransferPhase.complete,
        bytes: bytes + reused,
        total: manifest.bytes,
        verifiedFiles: files,
      ),
    );
    return TransferResult(
      files,
      bytes,
      skipped: skipped,
      networkBytes: networkBytes,
    );
  } catch (error) {
    try {
      await wire.send(WireType.error, {
        'code': 'sender',
        'message': error is NshareException ? error.message : 'Sender failed',
      });
    } catch (_) {}
    if (!acknowledged &&
        error is NshareException &&
        error.code == 'disconnected') {
      throw const NshareException(
        'uncertain',
        'Connection lost before receiver acknowledgment; some files may have completed',
      );
    }
    rethrow;
  } finally {
    await wire.close();
    await manifest.dispose();
  }
}

class TransferReceiver {
  TransferReceiver._(
    this._server,
    this.identity,
    this.trust,
    this.output,
    this.conflict,
    this.approvePeer,
    this.approveOffer,
    this.expectedFingerprint,
    this.onProgress,
    this.onResult,
    this.onError,
    this.allowCompression,
    this.approveClipboard,
  );
  final SecureServerSocket _server;
  final DeviceIdentity identity;
  final TrustStore trust;
  final Directory output;
  final ConflictPolicy conflict;
  final bool allowCompression;
  final ClipboardApproval? approveClipboard;
  final PairingApproval? approvePeer;
  final OfferApproval approveOffer;
  final String? expectedFingerprint;
  final ProgressCallback? onProgress;
  final void Function(TransferResult)? onResult;
  final void Function(Object)? onError;
  StreamSubscription<SecureSocket>? _subscription;
  DiscoveryService? _discovery;
  final _mdns = <MdnsAdvertiser>[];
  final Set<WireConnection> _connections = {};
  final Set<Future<void>> _tasks = {};
  static final _outputOwners = <String>{};
  String? _outputKey;
  FileLease? _outputLock;
  bool _closed = false;
  Timer? _networkTimer;
  bool _checkingNetwork = false;
  String _networkSignature = '';
  int _mdnsGeneration = 0;
  int get port => _server.port;
  InternetAddress get address => _server.address;

  static Future<TransferReceiver> start({
    required DeviceIdentity identity,
    required TrustStore trust,
    required Directory output,
    required OfferApproval approveOffer,
    InternetAddress? bind,
    int port = 53317,
    bool discover = true,
    bool allowCompression = false,
    ClipboardApproval? approveClipboard,
    int discoveryPort = 1970,
    ConflictPolicy conflict = ConflictPolicy.refuse,
    PairingApproval? approvePeer,
    String? expectedFingerprint,
    ProgressCallback? onProgress,
    void Function(TransferResult)? onResult,
    void Function(Object)? onError,
  }) async {
    late final SecureServerSocket server;
    if (bind != null) {
      server = await SecureServerSocket.bind(
        bind,
        port,
        identity.serverContext,
      );
    } else {
      try {
        server = await SecureServerSocket.bind(
          InternetAddress.anyIPv6,
          port,
          identity.serverContext,
          v6Only: false,
        );
      } on SocketException {
        server = await SecureServerSocket.bind(
          InternetAddress.anyIPv4,
          port,
          identity.serverContext,
        );
      }
    }
    final receiver = TransferReceiver._(
      server,
      identity,
      trust,
      output,
      conflict,
      approvePeer,
      approveOffer,
      expectedFingerprint,
      onProgress,
      onResult,
      onError,
      allowCompression,
      approveClipboard,
    );
    receiver._subscription = server.listen(
      receiver._accept,
      onError: (Object error) => onError?.call(error),
    );
    if (discover && !server.address.isLoopback) {
      try {
        receiver._discovery = await DiscoveryService.advertise(
          identity,
          server.port,
          port: discoveryPort,
        );
      } catch (_) {
        /* The authenticated listener remains usable without discovery. */
      }
      // Optional providers must never delay listener readiness or crash reception.
      unawaited(receiver._advertiseMdns());
      receiver._networkTimer = Timer.periodic(
        const Duration(seconds: 10),
        (_) => unawaited(receiver._networkChanged()),
      );
    }
    return receiver;
  }

  Future<void> _networkChanged() async {
    if (_closed || _checkingNetwork) return;
    _checkingNetwork = true;
    try {
      final interfaces = await NetworkInterface.list(includeLinkLocal: true);
      final addresses = [
        for (final interface in interfaces)
          for (final address in interface.addresses)
            '${interface.index}:${address.address}',
      ]..sort();
      final signature = addresses.join('|');
      if (signature != _networkSignature && !_closed) {
        _networkSignature = signature;
        final previous = _mdns.toList();
        _mdns.clear();
        for (final advertiser in previous) {
          await advertiser.close();
        }
        await _advertiseMdns();
      }
    } catch (_) {
    } finally {
      _checkingNetwork = false;
    }
  }

  Future<void> _advertiseMdns() async {
    final generation = ++_mdnsGeneration;
    for (final ipv6 in [
      false,
      if (address.type == InternetAddressType.IPv6) true,
    ]) {
      if (_closed) return;
      try {
        final advertiser = await MdnsAdvertiser.start(
          identity,
          port,
          ipv6: ipv6,
        );
        if (_closed || generation != _mdnsGeneration) {
          await advertiser.close();
          return;
        }
        _mdns.add(advertiser);
      } catch (_) {
        /* Broadcast/direct IP remain available on restricted hosts. */
      }
    }
  }

  Future<void> _acquireOutput() async {
    if (_outputLock != null) return;
    if (await FileSystemEntity.type(output.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const NshareException('path', 'Output root must not be a link');
    }
    await output.create(recursive: true);
    final canonical = await output.resolveSymbolicLinks();
    if (!_outputOwners.add(canonical)) {
      throw const NshareException(
        'busy',
        'Another receiver owns this output folder',
      );
    }
    FileLease? lease;
    try {
      final state = Directory(p.join(canonical, '.nshare-state'));
      await assertNoLinks(state.path);
      await state.create();
      await privatePath(state.path, directory: true);
      final path = p.join(state.path, 'receiver.lock');
      await assertNoLinks(path);
      lease = await FileLease.acquire(File(path));
      _outputKey = canonical;
      _outputLock = lease;
    } catch (_) {
      await lease?.close();
      _outputOwners.remove(canonical);
      rethrow;
    }
  }

  void _accept(SecureSocket socket) {
    if (_connections.isNotEmpty) {
      socket.destroy();
      return;
    }
    final wire = WireConnection(socket);
    _connections.add(wire);
    final task = _handle(wire);
    _tasks.add(task);
    unawaited(task.whenComplete(() => _tasks.remove(task)));
  }

  Future<void> _handle(WireConnection wire) async {
    Manifest? disposableManifest;
    try {
      final peer = await authenticateIncoming(
        wire,
        identity,
        trust,
        approve: approvePeer,
        expectedFingerprint: expectedFingerprint,
      );
      final first = await wire.read(wait: const Duration(minutes: 5));
      if (first.type == WireType.pair) {
        wire.require('pair-v1');
        if (first.json['confirmationCode'] == true) {
          if (!wire.confirmationCodeVerified) {
            throw const NshareException(
              'untrusted',
              'Matching code was not confirmed',
            );
          }
          await wire.send(WireType.pairAck, {'confirmationCode': true});
          onResult?.call(const TransferResult(0, 0));
          return;
        }
        final token = requiredString(first.json, 'token', max: 64);
        await InvitationStore(identity.directory).consume(token);
        await wire.send(WireType.pairAck, {'token': token});
        onResult?.call(const TransferResult(0, 0));
        return;
      }
      if (first.type == WireType.clipboard) {
        wire.require('clipboard-v1');
        final data = first.json;
        final id = requiredString(data, 'id', max: 64);
        final text = data['text'];
        final expiry = requiredInt(data, 'expires');
        final now = DateTime.now().millisecondsSinceEpoch;
        if (text is! String ||
            utf8.encode(text).length > maxClipboardBytes ||
            expiry <= now ||
            expiry > now + const Duration(minutes: 5).inMilliseconds) {
          throw const NshareException(
            'protocol',
            'Invalid or expired clipboard offer',
          );
        }
        if (approveClipboard == null ||
            !await wire.waitFor(
              approveClipboard!(ClipboardOffer(peer, text, id)),
            )) {
          throw const NshareException('rejected', 'Clipboard offer declined');
        }
        await wire.send(WireType.clipboardAck, {'id': id});
        onResult?.call(const TransferResult(0, 0));
        return;
      }
      if (first.type != WireType.offer &&
          first.type != WireType.manifestBegin) {
        throw const NshareException('protocol', 'Expected transfer offer');
      }
      final offer = first.json;
      final compression = offer['compression'] == true;
      if (compression &&
          (!allowCompression || !wire.supports('block-gzip-v1'))) {
        throw const NshareException(
          'unsupported',
          'Receiver compression is disabled',
        );
      }
      final manifest = first.type == WireType.manifestBegin
          ? await PagedManifest.receive(wire, offer)
          : Manifest.parse(offer);
      disposableManifest = manifest;
      if (!await wire.waitFor(
        approveOffer(TransferOffer(peer, manifest.files, manifest.bytes)),
      )) {
        throw const NshareException(
          'rejected',
          'Receiver declined the transfer',
        );
      }
      await _acquireOutput();
      final store = await DestinationStore.open(
        output,
        manifest,
        peer.fingerprint,
        conflict,
      );
      await wire.send(WireType.accept, {
        'transfer': manifest.id,
        if (compression) 'compression': true,
      });
      var files = 0, bytes = 0, skipped = 0, reused = 0, networkBytes = 0;
      final elapsed = Stopwatch()..start();
      await for (final entry in manifest.streamEntries()) {
        final start = await wire.expect(WireType.fileStart);
        _checkEntry(start, manifest, entry);
        if (start['resume'] is! bool) {
          throw const NshareException('protocol', 'Invalid resume policy');
        }
        final finalized =
            start['resume'] == true && await store.isFinalized(entry);
        final destination = await store.destination(entry);
        final existing = await FileSystemEntity.type(
          destination,
          followLinks: false,
        );
        if (!finalized &&
            !entry.directory &&
            existing != FileSystemEntityType.notFound) {
          if (conflict == ConflictPolicy.skip &&
              existing == FileSystemEntityType.file) {
            await wire.send(WireType.fileAccept, {
              ..._entryMessage(manifest, entry),
              'skip': true,
            });
            skipped++;
            continue;
          }
          if (conflict != ConflictPolicy.overwrite ||
              existing != FileSystemEntityType.file) {
            throw const NshareException(
              'conflict',
              'Destination exists; choose an explicit conflict policy',
            );
          }
        }
        RandomAccessFile? writer;
        try {
          var offset = finalized ? entry.size : 0;
          var prefixHash = finalized && !entry.directory
              ? entry.hash
              : sha256.convert([]).toString();
          if (!entry.directory && !finalized) {
            final partial = store.partial(entry);
            await assertNoLinks(partial.path);
            if (start['resume'] == true && await partial.exists()) {
              final length = await partial.length();
              if (length <= entry.size) {
                offset = length == entry.size
                    ? length
                    : length ~/ maxChunkBytes * maxChunkBytes;
                if (offset > 0) {
                  prefixHash = await hashFile(partial, end: offset);
                }
              }
            }
            writer = await partial.open(mode: FileMode.append);
            await writer.truncate(offset);
            await writer.setPosition(offset);
          }
          reused += offset;
          await wire.send(WireType.fileAccept, {
            ..._entryMessage(manifest, entry),
            'offset': offset,
            'prefixHash': prefixHash,
          });
          while (offset < entry.size) {
            final frame = await wire.read();
            if ((frame.type != WireType.data &&
                    !(compression && frame.type == WireType.compressedData)) ||
                frame.payload.length <= 8) {
              throw const NshareException(
                'protocol',
                'Expected nonempty file data',
              );
            }
            final chunkOffset = ByteData.sublistView(
              frame.payload,
            ).getUint64(0, Endian.big);
            final chunk = frame.type == WireType.compressedData
                ? decompressBlock(frame.payload)
                : Uint8List.sublistView(frame.payload, 8);
            networkBytes +=
                frame.payload.length -
                (frame.type == WireType.compressedData ? 12 : 8);
            if (chunkOffset != offset || chunk.length > entry.size - offset) {
              throw const NshareException(
                'protocol',
                'Unexpected offset or excess file bytes',
              );
            }
            await writer!.writeFrom(chunk);
            offset += chunk.length;
            bytes += chunk.length;
            onProgress?.call(
              TransferProgress(
                phase: TransferPhase.transferring,
                path: entry.path,
                networkBytes: networkBytes,
                bytes: bytes + reused,
                total: manifest.bytes,
                verifiedFiles: files,
                bytesPerSecond:
                    bytes *
                    1000000 /
                    elapsed.elapsedMicroseconds.clamp(1, 0x7fffffffffffffff),
              ),
            );
          }
          final end = await wire.expect(WireType.fileEnd);
          _checkEntry(end, manifest, entry);
          if (end['sha256'] != entry.hash) {
            throw const NshareException(
              'integrity',
              'Sender digest does not match manifest',
            );
          }
          await writer?.flush();
          await writer?.close();
          writer = null;
          onProgress?.call(
            TransferProgress(
              phase: TransferPhase.verifying,
              path: entry.path,
              bytes: bytes + reused,
              total: manifest.bytes,
              verifiedFiles: files,
            ),
          );
          if (!finalized) await store.finalize(entry);
          await wire.send(WireType.fileAck, {
            ..._entryMessage(manifest, entry),
            'sha256': entry.hash,
          });
          if (!entry.directory) files++;
        } finally {
          await writer?.close();
        }
      }
      final complete = await wire.expect(WireType.complete);
      if (complete['transfer'] != manifest.id ||
          complete['files'] != files ||
          complete['skipped'] != skipped) {
        throw const NshareException(
          'protocol',
          'Unexpected completion message',
        );
      }
      await wire.send(WireType.completeAck, {
        'transfer': manifest.id,
        'files': files,
        'skipped': skipped,
      });
      onProgress?.call(
        TransferProgress(
          phase: TransferPhase.complete,
          bytes: bytes + reused,
          total: manifest.bytes,
          verifiedFiles: files,
        ),
      );
      onResult?.call(
        TransferResult(
          files,
          bytes,
          skipped: skipped,
          networkBytes: networkBytes,
        ),
      );
    } catch (error) {
      try {
        await wire.send(WireType.error, {
          'code': error is NshareException ? error.code : 'receiver',
          'message': error is NshareException
              ? error.message
              : 'Receiver could not complete transfer',
        });
      } catch (_) {}
      onError?.call(error);
    } finally {
      await wire.close();
      _connections.remove(wire);
      await disposableManifest?.dispose();
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _networkTimer?.cancel();
    _mdnsGeneration++;
    for (final advertiser in _mdns.toList()) {
      await advertiser.close();
    }
    _mdns.clear();
    await _discovery?.close();
    await _subscription?.cancel();
    await _server.close();
    for (final wire in _connections.toList()) {
      await wire.close();
    }
    await Future.wait(_tasks.toList());
    await _outputLock?.close();
    if (_outputKey != null) _outputOwners.remove(_outputKey);
  }
}
