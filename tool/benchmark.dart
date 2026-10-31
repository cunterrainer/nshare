import 'dart:convert';
import 'dart:io';
import 'package:nshare/nshare.dart';

/// Loopback timings include source hashing, TLS, verification and finalization.
Future<void> main() async {
  final temp = await Directory.systemTemp.createTemp('nshare_benchmark_');
  try {
    final sender = await DeviceIdentity.load(Directory('${temp.path}/sender'));
    final receiver = await DeviceIdentity.load(
      Directory('${temp.path}/receiver'),
    );
    final large = File('${temp.path}/large.bin');
    final sink = large.openWrite();
    final block = List<int>.generate(65536, (i) => i % 251);
    for (var i = 0; i < 512; i++) {
      sink.add(block);
    }
    await sink.close();
    final small = Directory('${temp.path}/small');
    await small.create();
    for (var i = 0; i < 128; i++) {
      await File(
        '${small.path}/$i.txt',
      ).writeAsBytes(block.take(4096).toList());
    }
    for (final entry in [large, small]) {
      final failures = <Object>[];
      final server = await TransferReceiver.start(
        identity: receiver,
        trust: TrustStore(receiver.directory),
        output: Directory('${temp.path}/out'),
        approveOffer: (_) async => true,
        expectedFingerprint: sender.fingerprint,
        bind: InternetAddress.loopbackIPv4,
        port: 0,
        discover: false,
        onError: failures.add,
      );
      try {
        final stopwatch = Stopwatch()..start();
        final result = await sendPath(
          entry.path,
          '127.0.0.1',
          server.port,
          sender,
          TrustStore(sender.directory),
          expectedFingerprint: receiver.fingerprint,
        );
        stopwatch.stop();
        if (failures.isNotEmpty) throw StateError(failures.toString());
        stdout.writeln(
          jsonEncode({
            'case': entry is File ? '32MiB file' : '128 x 4KiB files',
            'files': result.files,
            'bytes': result.bytes,
            'seconds': stopwatch.elapsedMicroseconds / 1000000,
            'MiB_per_second':
                result.bytes /
                1048576 /
                (stopwatch.elapsedMicroseconds / 1000000),
          }),
        );
      } finally {
        await server.close();
      }
    }
  } finally {
    await temp.delete(recursive: true);
  }
}
