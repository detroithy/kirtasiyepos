import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../core/utils/money.dart';

/// Satış fişi satır modeli (POS sepetinden alınır).
class ReceiptLine {  final String name;
  final double qty;
  final double unitPrice;
  final double kdvRate;
  const ReceiptLine({
    required this.name,
    required this.qty,
    required this.unitPrice,
    required this.kdvRate,
  });
}

String _payText(String type, String customer) {
  return switch (type) {
    'kart' => 'Odeme: Kredi Karti',
    'parcali' => 'Odeme: Parcali (Nakit+Kart)',
    'cari' =>
      'Odeme: Cari${customer.isNotEmpty ? ' ($customer)' : ''}',
    _ => 'Odeme: Nakit',
  };
}

/// 80mm termal fiş PDF'i + yazdırma.
Future<void> printReceipt({
  required String receiptNo,
  required DateTime date,
  required List<ReceiptLine> lines,
  required double total,
  required double kdvTotal,
  required double profitTotal,
  required String paymentType,
  double paid = 0,
  double cash = 0,
  double card = 0,
  String customer = '',
  double discount = 0,
}) async {
  final doc = pw.Document();
  final mono = pw.TextStyle(font: pw.Font.courier(), fontSize: 9);
  final monoB =
      pw.TextStyle(font: pw.Font.courierBold(), fontSize: 10);
  final center = pw.TextAlign.center;

  // KDV kırılımı (indirim orantılı düşer — kayıtla aynı matematik):
  final subtotal =
      lines.fold(0.0, (s, l) => s + l.unitPrice * l.qty);
  final factor = subtotal > 0
      ? ((subtotal - discount.clamp(0, subtotal)) / subtotal)
      : 1.0;
  final kdvMap = <double, double>{};
  for (final l in lines) {
    kdvMap[l.kdvRate] = (kdvMap[l.kdvRate] ?? 0) +
        kdvTutar(l.unitPrice, l.kdvRate) * l.qty * factor;
  }

  doc.addPage(
    pw.Page(
      pageFormat: PdfPageFormat(
        80 * PdfPageFormat.mm,
        double.infinity,
        marginAll: 4 * PdfPageFormat.mm,
      ),
      build: (_) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          pw.Text('KIRTASIYEPOS', style: monoB, textAlign: center),
          pw.Text('Satis Fisi', style: mono, textAlign: center),
          pw.SizedBox(height: 4),
          pw.Text('Fis No: $receiptNo', style: mono),
          pw.Text('Tarih: ${fdate(date)}', style: mono),
          pw.Divider(),
          ...lines.map((l) => pw.Column(
                crossAxisAlignment:
                    pw.CrossAxisAlignment.stretch,
                children: [
                  pw.Text(l.name, style: mono),
                  pw.Row(
                    mainAxisAlignment:
                        pw.MainAxisAlignment.spaceBetween,
                    children: [
                      pw.Text(
                          '${fmtQty(l.qty)} x ${money(l.unitPrice)}',
                          style: mono),
                      pw.Text(
                          money(l.unitPrice * l.qty), style: mono),
                    ],
                  ),
                ],
              )),
          pw.Divider(),
          if (discount > 0)
            pw.Row(
                mainAxisAlignment:
                    pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text('Indirim', style: mono),
                  pw.Text('-${money(discount)}', style: mono),
                ]),
          pw.Row(
              mainAxisAlignment:
                  pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Text('TOPLAM', style: monoB),
                pw.Text(money(total), style: monoB),
              ]),
          ...kdvMap.entries.map((e) => pw.Row(
                mainAxisAlignment:
                    pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text('KDV ${kdvEtiket(e.key)}', style: mono),
                  pw.Text(money(e.value), style: mono),
                ],
              )),
          pw.Row(
              mainAxisAlignment:
                  pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Text(_payText(paymentType, customer),
                    style: mono),
              ]),
          if (paymentType == 'parcali') ...[
            pw.Row(
                mainAxisAlignment:
                    pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text('Nakit: ${money(cash)}',
                      style: mono),
                  pw.Text('Kart: ${money(card)}',
                      style: mono),
                ]),
          ],
          if (paid > 0)
            pw.Row(
                mainAxisAlignment:
                    pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text('Alinan: ${money(paid)}', style: mono),
                  pw.Text('Ustu: ${money(paid - total)}',
                      style: mono),
                ]),
          pw.SizedBox(height: 6),
          pw.BarcodeWidget(
            barcode: pw.Barcode.code128(),
            data: receiptNo,
            width: double.infinity,
            height: 40,
          ),
          pw.SizedBox(height: 4),
          pw.Text('Bizi tercih ettiginiz icin tesekkurler!',
              style: mono, textAlign: center),
        ],
      ),
    ),
  );
  await Printing.layoutPdf(
    onLayout: (_) async => doc.save(),
    name: 'fis_$receiptNo',
  );
}

/// Raf etiketi PDF'i: ürün adı + barkod + KDV dahil fiyat.
/// Etiket yazıcısı veya normal yazıcıdan basılabilir.
Future<void> printLabel({
  required String name,
  required String barcode,
  required double price,
}) async {
  final doc = pw.Document();
  final isEan = barcode.length == 13 && int.tryParse(barcode) != null;
  doc.addPage(
    pw.Page(
      pageFormat: PdfPageFormat.a4,
      build: (_) => pw.GridView(
        crossAxisCount: 3,
        childAspectRatio: 1.8,
        children: List.generate(
          12,
          (_) => pw.Container(
            margin: const pw.EdgeInsets.all(6),
            padding: const pw.EdgeInsets.all(8),
            decoration: pw.BoxDecoration(
                border: pw.Border.all(width: 1)),
            child: pw.Column(
              mainAxisAlignment:
                  pw.MainAxisAlignment.center,
              children: [
                pw.Text(name,
                    style: pw.TextStyle(
                        font: pw.Font.helveticaBold(),
                        fontSize: 10),
                    maxLines: 2),
                pw.SizedBox(height: 4),
                pw.BarcodeWidget(
                  barcode: isEan
                      ? pw.Barcode.ean13()
                      : pw.Barcode.code128(),
                  data: barcode,
                  width: 140,
                  height: 40,
                ),
                pw.SizedBox(height: 2),
                pw.Text(barcode,
                    style: pw.TextStyle(
                        font: pw.Font.courier(),
                        fontSize: 8)),
                pw.Text(money(price),
                    style: pw.TextStyle(
                        font: pw.Font.helveticaBold(),
                        fontSize: 14)),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await Printing.layoutPdf(
    onLayout: (_) async => doc.save(),
    name: 'etiket_$barcode',
  );
}
