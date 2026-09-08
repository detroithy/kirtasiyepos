import 'dart:math';

/// Mağaza-içi barkod üretici (EAN-13, 290-299 bandı).
/// Barkodsuz ürünlere (açık kalem, fotokopi vs.) raf etiketi basmak için.
String generateInternalBarcode({String prefix = '290'}) {
  assert(prefix.length == 3, 'prefix 3 hane olmalı');
  final r = Random.secure();
  final body = List.generate(9, (_) => r.nextInt(10)).join();
  final twelve = '$prefix$body';
  return '$twelve${_checkDigit(twelve)}';
}

/// EAN-13 kontrol hanesi.
int _checkDigit(String twelve) {
  var sum = 0;
  for (var i = 0; i < 12; i++) {
    final d = int.parse(twelve[i]);
    sum += (i % 2 == 0) ? d : d * 3;
  }
  return (10 - (sum % 10)) % 10;
}

bool isValidEan13(String code) {
  if (code.length != 13 || int.tryParse(code) == null) return false;
  return _checkDigit(code.substring(0, 12)) == int.parse(code[12]);
}
