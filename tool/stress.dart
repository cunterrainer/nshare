import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:args/args.dart';
import 'package:nshare/nshare.dart';
import 'package:nshare/src/storage/storage.dart' show hashFile;

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('entries', defaultsTo: '10000')
    ..addOption('large-bytes', defaultsTo: '0')
    ..addOption('report');
  final args = parser.parse(arguments);
  final count = int.parse(args['entries'] as String);
  final large = int.parse(args['large-bytes'] as String);
  if (count < 0 || count > 100000 || large < 0) {
    throw ArgumentError('Invalid workload');
  }
  final root = await Directory.systemTemp.createTemp('nshare_stress_');
  final results = <Map<String, dynamic>>[];
  try {
    final sender = await DeviceIdentity.load(Directory('${root.path}/sender'));
    final receiver = await DeviceIdentity.load(
      Directory('${root.path}/receiver'),
    );
    Future<void> transfer(String source, String label, bool compression) async {
      final output = Directory('${root.path}/out');
      final completed = Completer<TransferResult>();
      final server = await TransferReceiver.start(
        identity: receiver,
        trust: TrustStore(receiver.directory),
        output: output,
        approveOffer: (offer) async {
          stderr.writeln(
            '$label: approved ${offer.fileCount} files, ${offer.bytes} bytes',
          );
          return true;
        },
        expectedFingerprint: sender.fingerprint,
        bind: InternetAddress.loopbackIPv4,
        port: 0,
        discover: false,
        allowCompression: compression,
        onResult: completed.complete,
        onError: completed.completeError,
      );
      var previous = 0;
      final watch = Stopwatch()..start();
      try {
        final sent = await sendPath(
          source,
          '127.0.0.1',
          server.port,
          sender,
          TrustStore(sender.directory),
          expectedFingerprint: receiver.fingerprint,
          compression: compression,
          onProgress: (progress) {
            if (progress.verifiedFiles - previous >= 5000) {
              previous = progress.verifiedFiles;
              stderr.writeln('$label: $previous files verified');
            }
          },
        );
        final received = await completed.future;
        var actual = 0;
        await for (final item in output.list(
          recursive: true,
          followLinks: false,
        )) {
          if (item is File &&
              !item.path.contains(
                '${Platform.pathSeparator}.nshare-state${Platform.pathSeparator}',
              )) {
            actual++;
            if (label == 'many-files' && await item.length() != 0) {
              throw StateError('Unexpected file bytes');
            }
          }
        }
        if (actual != sent.files || received.files != sent.files) {
          throw StateError('File count mismatch');
        }
        if (label == 'large-file') {
          final destination = File(
            '${output.path}/${File(source).uri.pathSegments.last}',
          );
          if (await destination.length() != large ||
              await hashFile(destination) != await hashFile(File(source))) {
            throw StateError('Large file integrity failure');
          }
        }
        results.add({
          'workload': label,
          'files': sent.files,
          'originalBytes': sent.bytes,
          'networkPayloadBytes': sent.networkBytes,
          'elapsedMs': watch.elapsedMilliseconds,
          'processMaxRssBytes': ProcessInfo.maxRss,
          'verified': true,
        });
      } finally {
        await server.close();
        if (await output.exists()) await output.delete(recursive: true);
      }
    }

    if (count > 0) {
      final tree = Directory('${root.path}/many')..createSync();
      for (var i = 0; i < count; i++) {
        File('${tree.path}/file-${i.toString().padLeft(6, '0')}').createSync();
      }
      await transfer(tree.path, 'many-files', false);
      await tree.delete(recursive: true);
    }
    if (large > 0) {
      final file = File('${root.path}/large.bin');
      final writer = await file.open(mode: FileMode.write);
      await writer.truncate(large);
      await writer.close();
      await transfer(file.path, 'large-file', true);
      await file.delete();
    }
    final report = const JsonEncoder.withIndent('  ').convert({
      'scope': 'same-process loopback TLS; no physical-device claim',
      'results': results,
    });
    stdout.writeln(report);
    if (args['report'] != null) {
      await File(args['report'] as String).writeAsString('$report\n');
    }
  } finally {
    await root.delete(recursive: true);
  }
}
