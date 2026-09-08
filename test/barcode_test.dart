import 'package:flutter_test/flutter_test.dart';
import 'package:kirtasiye_app/core/utils/barcode_gen.dart';

void main() {
  test('üretilen dahili barkodlar geçerli EAN-13', () {
    for (var i = 0; i < 50; i++) {
      final c = generateInternalBarcode();
      expect(c.length, 13);
      expect(c.startsWith('290'), true);
      expect(isValidEan13(c), true);
    }
  });

  test('bilinen EAN-13 doğrulanır, bozuk reddedilir', () {
    expect(isValidEan13('8680000000013'), true);
    expect(isValidEan13('8680000000014'), false);
    expect(isValidEan13('123'), false);
  });
}
