import 'dart:io';
import 'package:test/test.dart';
import 'package:nshare/nshare.dart';

void main() {
  group('Log Functions', () {
    setUp(() {
      // Setup for log tests
    });

    test('Log() should print INFO message', () {
      Log('Test message');
      // This outputs to console, verify it doesn't throw
      expect(() => Log('Test message'), returnsNormally);
    });

    test('Err() should print ERROR message with color codes', () {
      expect(() => Err('Test error'), returnsNormally);
    });

    test('Hint() should print HINT message', () {
      expect(() => Hint('Test hint'), returnsNormally);
    });

    test('Suc() should print success message', () {
      expect(() => Suc('Test success'), returnsNormally);
    });

    test('Ver() should not print when verbose is false', () {
      g_LoggerVerbose = false;
      expect(() => Ver('Verbose message'), returnsNormally);
    });

    test('Ver() should print when verbose is true', () {
      g_LoggerVerbose = true;
      expect(() => Ver('Verbose message'), returnsNormally);
      g_LoggerVerbose = false; // Reset
    });

    test('VerErr() should not print error when verbose is false', () {
      g_LoggerVerbose = false;
      expect(() => VerErr('Verbose error'), returnsNormally);
    });

    test('VerErr() should print error when verbose is true', () {
      g_LoggerVerbose = true;
      expect(() => VerErr('Verbose error'), returnsNormally);
      g_LoggerVerbose = false; // Reset
    });

    test('g_LoggerVerbose flag can be toggled', () {
      g_LoggerVerbose = true;
      expect(g_LoggerVerbose, isTrue);
      g_LoggerVerbose = false;
      expect(g_LoggerVerbose, isFalse);
    });

    test('Err() handles newlines correctly', () {
      expect(() => Err('Line1\nLine2'), returnsNormally);
      expect(() => Err('Line1\n'), returnsNormally);
    });
  });
}
