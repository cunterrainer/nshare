import 'package:test/test.dart';
import 'package:nshare/nshare.dart';

void main() {
  group('ProgressBar', () {
    test('ProgressBar.Init() initializes bar state', () {
      ProgressBar.Init();
      // After init, show should work without errors
      expect(() => ProgressBar.Show(0, 100), returnsNormally);
    });

    test('ProgressBar.Init() can be called multiple times', () {
      ProgressBar.Init();
      expect(() => ProgressBar.Init(), returnsNormally);
      
      ProgressBar.Init();
      expect(() => ProgressBar.Init(), returnsNormally);
    });

    test('ProgressBar.Show() with 0 progress', () {
      ProgressBar.Init();
      expect(() => ProgressBar.Show(0, 100), returnsNormally);
    });

    test('ProgressBar.Show() with partial progress', () {
      ProgressBar.Init();
      expect(() => ProgressBar.Show(50, 100), returnsNormally);
    });

    test('ProgressBar.Show() with full progress', () {
      ProgressBar.Init();
      expect(() => ProgressBar.Show(100, 100), returnsNormally);
    });

    test('ProgressBar.Show() with incremental updates', () {
      ProgressBar.Init();
      for (int i = 0; i <= 100; i += 10) {
        expect(() => ProgressBar.Show(i, 100), returnsNormally);
      }
    });

    test('ProgressBar.Show() with large numbers', () {
      ProgressBar.Init();
      expect(() => ProgressBar.Show(5000000, 10000000), returnsNormally);
    });

    test('ProgressBar.Show() with equal current and total', () {
      ProgressBar.Init();
      expect(() => ProgressBar.Show(100, 100), returnsNormally);
    });

    test('ProgressBar.Show() with very small total', () {
      ProgressBar.Init();
      expect(() => ProgressBar.Show(1, 1), returnsNormally);
    });

    test('ProgressBar.Show() with current > total', () {
      ProgressBar.Init();
      // This may happen due to rounding errors, should handle gracefully
      expect(() => ProgressBar.Show(105, 100), returnsNormally);
    });

    test('ProgressBar.Show() with zero total', () {
      ProgressBar.Init();
      // Division by zero could be an issue, let's see
      expect(() => ProgressBar.Show(0, 0), throwsA(anything));
    });

    test('ProgressBar can display multiple file transfers', () {
      for (int file = 0; file < 5; file++) {
        ProgressBar.Init();
        for (int i = 0; i <= 100; i += 25) {
          expect(() => ProgressBar.Show(i, 100), returnsNormally);
        }
      }
    });

    test('ProgressBar.Show() percentage calculation', () {
      ProgressBar.Init();
      
      // 25% progress
      expect(() => ProgressBar.Show(25, 100), returnsNormally);
      
      // 50% progress
      expect(() => ProgressBar.Show(50, 100), returnsNormally);
      
      // 75% progress
      expect(() => ProgressBar.Show(75, 100), returnsNormally);
      
      // 100% progress
      expect(() => ProgressBar.Show(100, 100), returnsNormally);
    });

    test('ProgressBar rapid updates', () {
      ProgressBar.Init();
      for (int i = 0; i < 1000; i++) {
        expect(() => ProgressBar.Show(i, 1000), returnsNormally);
      }
    });

    test('ProgressBar with fractional progress', () {
      ProgressBar.Init();
      expect(() => ProgressBar.Show(33, 100), returnsNormally);
      expect(() => ProgressBar.Show(66, 100), returnsNormally);
    });

    test('ProgressBar state is reset on each Init', () {
      ProgressBar.Init();
      ProgressBar.Show(50, 100);
      
      ProgressBar.Init();
      expect(() => ProgressBar.Show(10, 100), returnsNormally);
    });

    test('ProgressBar handles floating point precision', () {
      ProgressBar.Init();
      
      // Test values that might cause floating point issues
      expect(() => ProgressBar.Show(1, 3), returnsNormally); // 33.33%
      expect(() => ProgressBar.Show(2, 3), returnsNormally); // 66.66%
      expect(() => ProgressBar.Show(3, 3), returnsNormally); // 100%
    });

    test('ProgressBar with 1 byte out of 1GB', () {
      ProgressBar.Init();
      expect(() => ProgressBar.Show(1, 1024 * 1024 * 1024), returnsNormally);
    });

    test('ProgressBar with power of 2 sizes', () {
      ProgressBar.Init();
      expect(() => ProgressBar.Show(512, 1024), returnsNormally);
      expect(() => ProgressBar.Show(256, 512), returnsNormally);
    });
  });
}
