import 'package:nshare/core.dart';
import 'package:test/test.dart';

void main() {
  test('cancellation is idempotent and observable by adapters', () async {
    final token = CancellationToken();
    expect(token.isCancelled, isFalse);
    token.cancel();
    token.cancel();
    await token.whenCancelled;
    expect(token.check, throwsA(isA<NshareException>()));
  });
}
