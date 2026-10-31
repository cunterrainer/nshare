import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import '../core/models.dart';
import '../discovery/discovery.dart';
import '../identity/identity.dart';
import '../protocol/protocol.dart';
import '../storage/storage.dart';

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
  CancellationToken? cancellation,
  ProgressCallback? onProgress,
  bool resume = true,
}) async {
  final manifest = await Manifest.collect(input, cancellation: cancellation);
  onProgress?.call(
    TransferProgress(phase: TransferPhase.connecting, total: manifest.bytes),
  );
  final wire = await connectAuthenticated(
    host,
    port,
    identity,
    trust,
    approve: approvePeer,
    expectedFingerprint: expectedFingerprint,
    cancellation: cancellation,
  );
  var acknowledged = false;
  try {
    await wire.send(WireType.offer, manifest.toJson());
    final accept = await wire.expect(
      WireType.accept,
      wait: const Duration(minutes: 5),
    );
    if (accept['transfer'] != manifest.id)
      throw const NshareException('protocol', 'Unexpected accepted transfer');
    var files = 0, bytes = 0, skipped = 0, reused = 0;
    final elapsed = Stopwatch()..start();
    for (final entry in manifest.entries) {
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
            : await hashFile(source, end: offset);
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
            if (chunk.isEmpty)
              throw const NshareException('source', 'Source was truncated');
            final payload = Uint8List(8 + chunk.length);
            ByteData.sublistView(payload).setUint64(0, offset, Endian.big);
            payload.setRange(8, payload.length, chunk);
            await wire.sendBytes(WireType.data, payload);
            offset += chunk.length;
            bytes += chunk.length;
            onProgress?.call(
              TransferProgress(
                phase: TransferPhase.transferring,
                path: entry.path,
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
      await wire.send(WireType.fileEnd, {
        ..._entryMessage(manifest, entry),
        'sha256': entry.hash,
      });
      final ack = await wire.expect(WireType.fileAck);
      _checkEntry(ack, manifest, entry);
      if (ack['sha256'] != entry.hash)
        throw const NshareException(
          'integrity',
          'Receiver acknowledged a different digest',
        );
      if (!entry.directory) files++;
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
    return TransferResult(files, bytes, skipped: skipped);
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
  );
  final SecureServerSocket _server;
  final DeviceIdentity identity;
  final TrustStore trust;
  final Directory output;
  final ConflictPolicy conflict;
  final PairingApproval? approvePeer;
  final OfferApproval approveOffer;
  final String? expectedFingerprint;
  final ProgressCallback? onProgress;
  final void Function(TransferResult)? onResult;
  final void Function(Object)? onError;
  StreamSubscription<SecureSocket>? _subscription;
  DiscoveryService? _discovery;
  final Set<WireConnection> _connections = {};
  final Set<Future<void>> _tasks = {};
  int get port => _server.port;

  static Future<TransferReceiver> start({
    required DeviceIdentity identity,
    required TrustStore trust,
    required Directory output,
    required OfferApproval approveOffer,
    InternetAddress? bind,
    int port = 53317,
    bool discover = true,
    int discoveryPort = 1970,
    ConflictPolicy conflict = ConflictPolicy.refuse,
    PairingApproval? approvePeer,
    String? expectedFingerprint,
    ProgressCallback? onProgress,
    void Function(TransferResult)? onResult,
    void Function(Object)? onError,
  }) async {
    final server = await SecureServerSocket.bind(
      bind ?? InternetAddress.anyIPv4,
      port,
      identity.serverContext,
    );
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
    );
    receiver._subscription = server.listen(
      receiver._accept,
      onError: (Object error) => onError?.call(error),
    );
    try {
      if (discover)
        receiver._discovery = await DiscoveryService.advertise(
          identity,
          server.port,
          port: discoveryPort,
        );
    } catch (_) {
      await receiver.close();
      rethrow;
    }
    return receiver;
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
    try {
      final peer = await authenticateIncoming(
        wire,
        identity,
        trust,
        approve: approvePeer,
        expectedFingerprint: expectedFingerprint,
      );
      final manifest = Manifest.parse(
        await wire.expect(WireType.offer, wait: const Duration(minutes: 5)),
      );
      if (!await wire.waitFor(
        approveOffer(TransferOffer(peer, manifest.files, manifest.bytes)),
      )) {
        throw const NshareException(
          'rejected',
          'Receiver declined the transfer',
        );
      }
      final store = await DestinationStore.open(
        output,
        manifest,
        peer.fingerprint,
        conflict,
      );
      await wire.send(WireType.accept, {'transfer': manifest.id});
      var files = 0, bytes = 0, skipped = 0, reused = 0;
      final elapsed = Stopwatch()..start();
      for (final entry in manifest.entries) {
        final start = await wire.expect(WireType.fileStart);
        _checkEntry(start, manifest, entry);
        if (start['resume'] is! bool)
          throw const NshareException('protocol', 'Invalid resume policy');
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
                if (offset > 0)
                  prefixHash = await hashFile(partial, end: offset);
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
            if (frame.type != WireType.data || frame.payload.length <= 8) {
              throw const NshareException(
                'protocol',
                'Expected nonempty file data',
              );
            }
            final chunkOffset = ByteData.sublistView(
              frame.payload,
            ).getUint64(0, Endian.big);
            final chunk = Uint8List.sublistView(frame.payload, 8);
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
          if (end['sha256'] != entry.hash)
            throw const NshareException(
              'integrity',
              'Sender digest does not match manifest',
            );
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
      onResult?.call(TransferResult(files, bytes, skipped: skipped));
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
    }
  }

  Future<void> close() async {
    await _discovery?.close();
    await _subscription?.cancel();
    await _server.close();
    for (final wire in _connections.toList()) {
      await wire.close();
    }
    await Future.wait(_tasks.toList());
  }
}
