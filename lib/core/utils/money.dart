import 'package:intl/intl.dart';

/// TR para formatı: 1.234,56 ₺
final _tl = NumberFormat.currency(locale: 'tr_TR', symbol: '₺', decimalDigits: 2);
String money(double v) => _tl.format(v);

final _date = DateFormat('dd.MM.yyyy HH:mm', 'tr_TR');
String fdate(DateTime d) => _date.format(d);
String fday(DateTime d) => DateFormat('dd.MM.yyyy', 'tr_TR').format(d);

/// Etiket fiyatı KDV DAHİL kabul edilir (TR perakende adeti).
double kdvHaric(double dahilFiyat, double oran) => dahilFiyat / (1 + oran / 100);
double kdvTutar(double dahilFiyat, double oran) =>
    dahilFiyat - kdvHaric(dahilFiyat, oran);

/// Satır karı: (KDV hariç satış - alış) * adet. Alış KDV hariç kabul edilir.
double satirKar(double satisDahil, double alis, double oran, double adet) =>
    (kdvHaric(satisDahil, oran) - alis) * adet;

const List<double> kdvOranlari = [0, 1, 10, 20];
String kdvEtiket(double oran) =>
    '%${oran.toStringAsFixed(oran == oran.roundToDouble() ? 0 : 2)}';

/// Stok adedi formatı: 50 -> "50", 2.5 -> "2.5"
String fmtQty(double v) =>
    v.truncateToDouble() == v ? v.toInt().toString() : v.toString();
