import 'dart:io';
import 'package:test/test.dart';

Future<ProcessResult> cli(List<String> args) => Process.run(
  Platform.resolvedExecutable,
  ['run', 'bin/nshare.dart', ...args],
);
void main() {
  test('help does not start a receiver', () async {
    final result = await cli([]);
    expect(result.exitCode, 0);
    expect(result.stdout, contains('Usage:'));
  });
  test('show-ip lists interfaces independently', () async {
    final result = await cli(['--show-ip', '--include-loopback']);
    expect(result.exitCode, 0);
    expect(result.stdout, contains('127.0.0.1'));
    expect(result.stdout, contains('IPv4'));
  });
  test('unknown flags and conflicting standalone command fail', () async {
    expect((await cli(['--unknown'])).exitCode, 64);
    expect((await cli(['--show-ip', 'receive'])).exitCode, 64);
  });
}
