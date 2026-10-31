import 'dart:io';
import 'package:nshare/nshare.dart';

/// Pass an out-of-band-verified receiver fingerprint as the third argument.
Future<void> main(List<String> args) async {
  if (args.length != 3) {
    stderr.writeln(
      'Usage: dart run example/send.dart <path> <IP> <verified SHA-256 fingerprint>',
    );
    exitCode = 64;
    return;
  }
  final identity = await DeviceIdentity.load(Directory('.nshare-example'));
  final task = TransferTask(
    (cancellation, progress) => sendPath(
      args[0],
      args[1],
      53317,
      identity,
      TrustStore(identity.directory),
      expectedFingerprint: args[2],
      cancellation: cancellation,
      onProgress: progress,
    ),
  );
  final subscription = task.progress.listen((event) {
    stdout.writeln('${event.phase.name}: ${event.bytes}/${event.total}');
  });
  try {
    final result = await task.result;
    stdout.writeln('${result.files} verified files');
  } finally {
    await subscription.cancel();
  }
}
