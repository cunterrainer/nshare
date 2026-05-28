import 'package:test/test.dart';
import 'package:nshare/nshare.dart';

void main() {
  group('NshareConfig - Constructor', () {
    test('NshareConfig can be instantiated with all parameters', () {
      final config = NshareConfig(
        mode: ProgramMode.sender,
        port: 8080,
        discoveryPort: 1970,
        bindPort: 1971,
        fileName: 'test.txt',
        ipAddress: '192.168.1.1',
        verifyWrittenFiles: true,
        keepFilesMode: KeepFilesMode.keep,
        skipLookup: false,
        verbose: true,
        timer: true,
      );

      expect(config.mode, equals(ProgramMode.sender));
      expect(config.port, equals(8080));
      expect(config.discoveryPort, equals(1970));
      expect(config.bindPort, equals(1971));
      expect(config.fileName, equals('test.txt'));
      expect(config.ipAddress, equals('192.168.1.1'));
      expect(config.verifyWrittenFiles, isTrue);
      expect(config.keepFilesMode, equals(KeepFilesMode.keep));
      expect(config.skipLookup, isFalse);
      expect(config.verbose, isTrue);
      expect(config.timer, isTrue);
    });

    test('NshareConfig fields are mutable', () {
      final config = NshareConfig(
        mode: ProgramMode.none,
        port: 80,
        discoveryPort: 1970,
        bindPort: 1971,
        fileName: '',
        ipAddress: '',
        verifyWrittenFiles: false,
        keepFilesMode: KeepFilesMode.ask,
        skipLookup: false,
        verbose: false,
        timer: false,
      );

      config.mode = ProgramMode.receiver;
      expect(config.mode, equals(ProgramMode.receiver));

      config.port = 9000;
      expect(config.port, equals(9000));

      config.verbose = true;
      expect(config.verbose, isTrue);
    });
  });

  group('NshareConfig.defaults()', () {
    test('defaults() returns config with correct default values', () {
      final config = NshareConfig.defaults();

      expect(config.mode, equals(ProgramMode.none));
      expect(config.port, equals(80));
      expect(config.discoveryPort, equals(1970));
      expect(config.bindPort, equals(1971));
      expect(config.fileName, isEmpty);
      expect(config.ipAddress, isEmpty);
      expect(config.verifyWrittenFiles, isFalse);
      expect(config.keepFilesMode, equals(KeepFilesMode.ask));
      expect(config.skipLookup, isFalse);
      expect(config.verbose, isFalse);
      expect(config.timer, isFalse);
    });

    test('defaults() creates independent instances', () {
      final config1 = NshareConfig.defaults();
      final config2 = NshareConfig.defaults();

      config1.port = 5000;
      expect(config2.port, equals(80));
    });
  });

  group('NshareConfig.fromArgs()', () {
    test('fromArgs() with no arguments returns receiver with defaults', () {
      final config = NshareConfig.fromArgs([]);

      expect(config, isNotNull);
      expect(config!.mode, equals(ProgramMode.receiver));
    });

    test('fromArgs() with --help returns null', () {
      final config = NshareConfig.fromArgs(['--help']);
      expect(config, isNull);
    });

    test('fromArgs() with -h returns null', () {
      final config = NshareConfig.fromArgs(['-h']);
      expect(config, isNull);
    });

    test('fromArgs() sets verbose flag', () {
      final config = NshareConfig.fromArgs(['--verbose']);
      expect(config!.verbose, isTrue);
    });

    test('fromArgs() sets verbose flag with -v', () {
      final config = NshareConfig.fromArgs(['-v']);
      expect(config!.verbose, isTrue);
    });

    test('fromArgs() sets skip lookup flag', () {
      final config = NshareConfig.fromArgs(['--skip']);
      expect(config!.skipLookup, isTrue);
    });

    test('fromArgs() sets timer flag', () {
      final config = NshareConfig.fromArgs(['--timer']);
      expect(config!.timer, isTrue);
    });

    test('fromArgs() sets input file and sender mode', () {
      final config = NshareConfig.fromArgs(['--input=myfile.txt']);
      expect(config!.fileName, equals('myfile.txt'));
      expect(config.mode, equals(ProgramMode.sender));
    });

    test('fromArgs() sets input file with -i', () {
      final config = NshareConfig.fromArgs(['-i=document.pdf']);
      expect(config!.fileName, equals('document.pdf'));
      expect(config.mode, equals(ProgramMode.sender));
    });

    test('fromArgs() sets output file and receiver mode', () {
      final config = NshareConfig.fromArgs(['--output=received.txt']);
      expect(config!.fileName, equals('received.txt'));
      expect(config.mode, equals(ProgramMode.receiver));
    });

    test('fromArgs() sets output file with -o', () {
      final config = NshareConfig.fromArgs(['-o=data.bin']);
      expect(config!.fileName, equals('data.bin'));
      expect(config.mode, equals(ProgramMode.receiver));
    });

    test('fromArgs() sets IP address for sender', () {
      final config = NshareConfig.fromArgs(['--input=file.txt', '--ip=192.168.1.100']);
      expect(config!.ipAddress, equals('192.168.1.100'));
    });

    test('fromArgs() sets port', () {
      final config = NshareConfig.fromArgs(['--port=5000']);
      expect(config!.port, equals(5000));
    });

    test('fromArgs() sets discovery port', () {
      final config = NshareConfig.fromArgs(['--discovery=2000']);
      expect(config!.discoveryPort, equals(2000));
    });

    test('fromArgs() sets bind port', () {
      final config = NshareConfig.fromArgs(['--bind=2001']);
      expect(config!.bindPort, equals(2001));
    });

    test('fromArgs() sets keep-all flag for receiver', () {
      final config = NshareConfig.fromArgs(['--output=file.txt', '--keep-all']);
      expect(config!.keepFilesMode, equals(KeepFilesMode.keep));
    });

    test('fromArgs() sets keep-all flag with -ka', () {
      final config = NshareConfig.fromArgs(['-o=file.txt', '-ka']);
      expect(config!.keepFilesMode, equals(KeepFilesMode.keep));
    });

    test('fromArgs() sets keep-none flag for receiver', () {
      final config = NshareConfig.fromArgs(['--output=file.txt', '--keep-none']);
      expect(config!.keepFilesMode, equals(KeepFilesMode.delete));
    });

    test('fromArgs() sets keep-none flag with -kn', () {
      final config = NshareConfig.fromArgs(['-o=file.txt', '-kn']);
      expect(config!.keepFilesMode, equals(KeepFilesMode.delete));
    });

    test('fromArgs() sets verify written files flag', () {
      final config = NshareConfig.fromArgs(['--output=file.txt', '--check']);
      expect(config!.verifyWrittenFiles, isTrue);
    });

    test('fromArgs() sets verify written files flag with -c', () {
      final config = NshareConfig.fromArgs(['-o=file.txt', '-c']);
      expect(config!.verifyWrittenFiles, isTrue);
    });

    test('fromArgs() throws on invalid mode combination', () {
      expect(
        () => NshareConfig.fromArgs(['--input=file.txt', '--output=file2.txt']),
        throwsA(anything),
      );
    });

    test('fromArgs() throws on invalid port', () {
      expect(
        () => NshareConfig.fromArgs(['--port=notanumber']),
        throwsA(anything),
      );
    });

    test('fromArgs() throws on missing port value', () {
      expect(
        () => NshareConfig.fromArgs(['--port=']),
        throwsA(anything),
      );
    });

    test('fromArgs() throws on unknown option', () {
      expect(
        () => NshareConfig.fromArgs(['--unknown=value']),
        throwsA(anything),
      );
    });

    test('fromArgs() case insensitive flag matching', () {
      final config = NshareConfig.fromArgs(['--VERBOSE', '--INPUT=file.txt']);
      expect(config!.verbose, isTrue);
      expect(config.fileName, equals('file.txt'));
    });

    test('fromArgs() with multiple flags', () {
      final config = NshareConfig.fromArgs([
        '--verbose',
        '--timer',
        '--skip',
        '--input=myfile.zip',
        '--port=8080',
      ]);

      expect(config!.verbose, isTrue);
      expect(config.timer, isTrue);
      expect(config.skipLookup, isTrue);
      expect(config.fileName, equals('myfile.zip'));
      expect(config.port, equals(8080));
      expect(config.mode, equals(ProgramMode.sender));
    });

    test('fromArgs() receiver mode is default when no input/output specified', () {
      final config = NshareConfig.fromArgs(['--verbose']);
      expect(config!.mode, equals(ProgramMode.receiver));
    });
  });

  group('NshareConfig.printConfig()', () {
    test('printConfig() does not throw', () {
      final config = NshareConfig.defaults();
      expect(() => config.printConfig(), returnsNormally);
    });

    test('printConfig() with sender mode', () {
      final config = NshareConfig(
        mode: ProgramMode.sender,
        port: 80,
        discoveryPort: 1970,
        bindPort: 1971,
        fileName: 'test.txt',
        ipAddress: '192.168.1.1',
        verifyWrittenFiles: false,
        keepFilesMode: KeepFilesMode.ask,
        skipLookup: false,
        verbose: false,
        timer: false,
      );

      expect(() => config.printConfig(), returnsNormally);
    });

    test('printConfig() with receiver mode', () {
      final config = NshareConfig(
        mode: ProgramMode.receiver,
        port: 80,
        discoveryPort: 1970,
        bindPort: 1971,
        fileName: 'received.txt',
        ipAddress: '',
        verifyWrittenFiles: true,
        keepFilesMode: KeepFilesMode.keep,
        skipLookup: false,
        verbose: false,
        timer: false,
      );

      expect(() => config.printConfig(), returnsNormally);
    });
  });

  group('ProgramMode enum', () {
    test('ProgramMode has required values', () {
      expect(ProgramMode.values.length, equals(3));
      expect(ProgramMode.values, contains(ProgramMode.none));
      expect(ProgramMode.values, contains(ProgramMode.sender));
      expect(ProgramMode.values, contains(ProgramMode.receiver));
    });
  });

  group('KeepFilesMode enum', () {
    test('KeepFilesMode has required values', () {
      expect(KeepFilesMode.values.length, equals(3));
      expect(KeepFilesMode.values, contains(KeepFilesMode.ask));
      expect(KeepFilesMode.values, contains(KeepFilesMode.keep));
      expect(KeepFilesMode.values, contains(KeepFilesMode.delete));
    });
  });
}
