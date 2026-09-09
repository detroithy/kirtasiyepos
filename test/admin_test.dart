import 'package:flutter_test/flutter_test.dart';
import 'package:kirtasiye_app/features/admin/bulk_price_screen.dart';

void main() {
  test('applyPercent kuruş yuvarlar', () {
    expect(applyPercent(100, 10), 110);
    expect(applyPercent(100, -10), 90);
    expect(applyPercent(15, 10), 16.5);
    expect(applyPercent(99.99, 5), 104.99);
    expect(applyPercent(50, 0), 50);
  });
}
