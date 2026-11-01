import 'dart:async';

/// Stable error categories for CLI and UI adapters.
class NshareException implements Exception {
  const NshareException(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => '$code: $message';
}

class CancellationToken {
  final _cancelled = Completer<void>();
  bool get isCancelled => _cancelled.isCompleted;
  Future<void> get whenCancelled => _cancelled.future;
  void cancel() {
    if (!isCancelled) _cancelled.complete();
  }

  void check() {
    if (isCancelled) {
      throw const NshareException('cancelled', 'Transfer cancelled');
    }
  }
}

enum ConflictPolicy { refuse, overwrite, skip }

enum TransferPhase {
  scanning,
  connecting,
  awaitingApproval,
  transferring,
  verifying,
  complete,
}

class TransferProgress {
  const TransferProgress({
    required this.phase,
    this.path = '',
    this.bytes = 0,
    this.total = 0,
    this.verifiedFiles = 0,
    this.bytesPerSecond = 0,
    this.networkBytes = 0,
    this.scannedEntries = 0,
  });
  final TransferPhase phase;
  final String path;
  final int bytes;
  final int total;
  final int verifiedFiles;
  final double bytesPerSecond;
  final int networkBytes;
  final int scannedEntries;
}

class PeerIdentity {
  const PeerIdentity(this.name, this.fingerprint);
  final String name;
  final String fingerprint;
}

/// Caller must compare the fingerprint through a trusted channel before approval.
typedef PairingApproval = Future<bool> Function(PeerIdentity peer);

class TransferOffer {
  const TransferOffer(this.peer, this.fileCount, this.bytes);
  final PeerIdentity peer;
  final int fileCount;
  final int bytes;
}

typedef OfferApproval = Future<bool> Function(TransferOffer offer);
typedef ScanCallback = void Function(int entries, String path);

typedef ProgressCallback = void Function(TransferProgress progress);

class TransferResult {
  const TransferResult(
    this.files,
    this.bytes, {
    this.skipped = 0,
    int? networkBytes,
  }) : networkBytes = networkBytes ?? bytes;
  final int networkBytes;
  final int files;
  final int bytes;
  final int skipped;
}
