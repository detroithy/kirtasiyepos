import 'package:flutter_test/flutter_test.dart';
import 'package:kirtasiye_app/core/utils/money.dart';

void main() {
  test('TR sayı ayrıştırma', () {
    // Binlik nokta:
    expect(tryParseTr('5.000'), 5000);
    expect(tryParseTr('1.250'), 1250);
    expect(tryParseTr('1.250.000'), 1250000);
    // Binlik + ondalık:
    expect(tryParseTr('1.250,50'), 1250.5);
    expect(tryParseTr('  2.500,75  '), 2500.75);
    // Sadece virgül (ondalık):
    expect(tryParseTr('1250,50'), 1250.5);
    // Sadece nokta (ondalık):
    expect(tryParseTr('1250.50'), 1250.5);
    expect(tryParseTr('12.5'), 12.5);
    // Düz sayı:
    expect(tryParseTr('5000'), 5000);
    expect(tryParseTr('0'), 0);
    // Bozuk:
    expect(tryParseTr(''), isNull);
    expect(tryParseTr('abc'), isNull);
    expect(tryParseTr('12,34,56'), isNull);
    // Varsayılan:
    expect(parseTr('5.000'), 5000);
    expect(parseTr('bozuk', 7), 7);
  });

  test('moneyCompact eksen etiketi', () {
    expect(moneyCompact(500), '500');
    expect(moneyCompact(1500), '1,5 B');
    expect(moneyCompact(25000), '25 B');
    expect(moneyCompact(-800), '-800');
    expect(moneyCompact(0), '0');
  });
}
