import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:nshare/nshare.dart';

void main() {
  group('Hashing - DigestAccumulator', () {
    test('DigestAccumulator initializes with empty events list', () {
      final accumulator = DigestAccumulator();
      expect(accumulator.events, isEmpty);
    });

    test('DigestAccumulator.add() appends digest to events', () {
      final accumulator = DigestAccumulator();
      final digest1 = md5.convert([1, 2, 3]);
      final digest2 = md5.convert([4, 5, 6]);
      
      accumulator.add(digest1);
      expect(accumulator.events.length, equals(1));
      expect(accumulator.events[0], equals(digest1));
      
      accumulator.add(digest2);
      expect(accumulator.events.length, equals(2));
      expect(accumulator.events[1], equals(digest2));
    });

    test('DigestAccumulator.add() with multiple digests maintains order', () {
      final accumulator = DigestAccumulator();
      final digests = <Digest>[];
      
      for (int i = 0; i < 10; i++) {
        final digest = md5.convert([i]);
        digests.add(digest);
        accumulator.add(digest);
      }
      
      expect(accumulator.events.length, equals(10));
      for (int i = 0; i < 10; i++) {
        expect(accumulator.events[i], equals(digests[i]));
      }
    });

    test('DigestAccumulator.close() does nothing', () {
      final accumulator = DigestAccumulator();
      final digest = md5.convert([1, 2, 3]);
      
      accumulator.add(digest);
      accumulator.close();
      
      expect(accumulator.events.length, equals(1));
      expect(accumulator.events[0], equals(digest));
    });

    test('DigestAccumulator can be used as Sink<Digest>', () {
      final accumulator = DigestAccumulator();
      final digest = md5.convert([]);
      
      // Test interface compliance
      Sink<Digest> sink = accumulator;
      sink.add(digest);
      sink.close();
      
      expect(accumulator.events.length, equals(1));
    });

    test('DigestAccumulator with MD5 conversion pipeline', () {
      final accumulator = DigestAccumulator();
      final input = md5.startChunkedConversion(accumulator);
      
      input.add([1, 2, 3]);
      input.add([4, 5, 6]);
      input.close();
      
      expect(accumulator.events.length, equals(1));
      expect(accumulator.events[0], isNotNull);
    });

    test('DigestAccumulator with multiple chunked conversions', () {
      final accumulator = DigestAccumulator();
      
      // First conversion
      final input1 = md5.startChunkedConversion(accumulator);
      input1.add([1, 2, 3]);
      input1.close();
      
      // Second conversion
      final input2 = md5.startChunkedConversion(accumulator);
      input2.add([4, 5, 6]);
      input2.close();
      
      expect(accumulator.events.length, equals(2));
    });

    test('DigestAccumulator events are immutable', () {
      final accumulator = DigestAccumulator();
      final digest = md5.convert([1, 2, 3]);
      
      accumulator.add(digest);
      final firstDigest = accumulator.events[0];
      
      accumulator.add(md5.convert([7, 8, 9]));
      
      expect(accumulator.events[0], equals(firstDigest));
    });

    test('DigestAccumulator with empty data', () {
      final accumulator = DigestAccumulator();
      final emptyDigest = md5.convert([]);
      
      accumulator.add(emptyDigest);
      
      expect(accumulator.events.length, equals(1));
      expect(accumulator.events[0].toString(), equals('d41d8cd98f00b204e9800998ecf8427e'));
    });
  });

  group('MD5 Hashing Integration', () {
    test('Can hash empty data', () {
      final accumulator = DigestAccumulator();
      final input = md5.startChunkedConversion(accumulator);
      input.close();
      
      expect(accumulator.events.length, equals(1));
      expect(accumulator.events[0].toString(), equals('d41d8cd98f00b204e9800998ecf8427e'));
    });

    test('Can hash small data in one chunk', () {
      final accumulator = DigestAccumulator();
      final input = md5.startChunkedConversion(accumulator);
      
      input.add([72, 101, 108, 108, 111]); // "Hello"
      input.close();
      
      expect(accumulator.events.length, equals(1));
      expect(accumulator.events[0].toString(), equals('8b1a9953c4611296a827abf8c47804d7'));
    });

    test('Can hash data split across multiple chunks', () {
      final accumulator = DigestAccumulator();
      final input = md5.startChunkedConversion(accumulator);
      
      input.add([72]); // H
      input.add([101]); // e
      input.add([108]); // l
      input.add([108]); // l
      input.add([111]); // o
      input.close();
      
      expect(accumulator.events.length, equals(1));
      expect(accumulator.events[0].toString(), equals('8b1a9953c4611296a827abf8c47804d7'));
    });

    test('Large data hashing', () {
      final accumulator = DigestAccumulator();
      final input = md5.startChunkedConversion(accumulator);
      
      // Add 10KB of data
      final chunk = List<int>.generate(1024, (i) => i % 256);
      for (int i = 0; i < 10; i++) {
        input.add(chunk);
      }
      input.close();
      
      expect(accumulator.events.length, equals(1));
      expect(accumulator.events[0].toString().length, equals(32)); // MD5 hex length
    });
  });
}
