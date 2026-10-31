import 'dart:async';
import 'models.dart';

/// Bridges callback-based core operations to a Flutter-friendly event stream.
/// Subscribe immediately after construction; work starts on the next event turn.
class TransferTask {
  TransferTask(
    Future<TransferResult> Function(CancellationToken, ProgressCallback) run,
  ) {
    result = Future(() => run(_cancellation, _progress.add)).whenComplete(() {
      unawaited(_progress.close());
    });
  }
  final _cancellation = CancellationToken();
  final _progress = StreamController<TransferProgress>.broadcast();
  late final Future<TransferResult> result;
  Stream<TransferProgress> get progress => _progress.stream;
  void cancel() => _cancellation.cancel();
}
