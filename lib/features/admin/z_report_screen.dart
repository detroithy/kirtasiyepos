import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../app.dart';
import '../../core/database/app_db.dart';
import '../../core/sync/cloud.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/money.dart';
import '../../core/widgets/kpi_card.dart';

/// Gün Sonu (Z): günün ciro/KDV/kar/ödeme özeti + fiş listesi + baskı.
class ZReportScreen extends ConsumerStatefulWidget {
  const ZReportScreen({super.key});

  @override
  ConsumerState<ZReportScreen> createState() => _ZReportScreenState();
}

class _ZReportScreenState extends ConsumerState<ZReportScreen>
    with SyncRefreshMixin {
  DateTime _day = DateTime.now();

  @override
  Widget build(BuildContext context) {
    final db = ref.watch(dbProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Gün Sonu (Z Raporu)'),
        actions: [
          IconButton(
            icon: const Icon(Icons.chevron_left),
            onPressed: () => setState(
                () => _day = _day.subtract(const Duration(days: 1))),
          ),
          Center(
              child: Text(fday(_day),
                  style: const TextStyle(fontWeight: FontWeight.bold))),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            onPressed: () =>
                setState(() => _day = _day.add(const Duration(days: 1))),
          ),
          IconButton(
            tooltip: 'Yazdır',
            icon: const Icon(Icons.print),
            onPressed: () => _print(db),
          ),
        ],
      ),
      body: FutureBuilder<DaySummary>(
        future: db.daySummary(_day),
        builder: (_, snap) {
          if (snap.hasError) {
            return Center(
                child: Text('Yüklenemedi: ${snap.error}',
                    style: const TextStyle(color: Colors.red)));
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final s = snap.data!;
          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              GridView.count(
                crossAxisCount: 2,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                childAspectRatio: 1.35,
                children: [
                  KpiCard(
                      label: 'BRÜT CİRO',
                      value: money(s.total),
                      icon: Icons.payments,
                      color: PosColors.navy,
                      sub: '${s.receipts} fiş'),
                  KpiCard(
                      label: 'KDV',
                      value: money(s.kdv),
                      icon: Icons.percent,
                      color: PosColors.amber),
                  KpiCard(
                      label: 'ÜRÜN KARI',
                      value: money(s.profit),
                      icon: Icons.trending_up,
                      color: PosColors.okTx),
                  KpiCard(
                      label: 'NET KAR',
                      value: money(s.netProfit),
                      icon: Icons.account_balance_wallet,
                      color: s.netProfit >= 0
                          ? PosColors.navy
                          : PosColors.critTx,
                      sub: 'Gider: ${money(s.expenses)}'),
                ],
              ),
              const SizedBox(height: 12),
              const Text('Fişler',
                  style: TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 6),
              FutureBuilder<List<Sale>>(
                future: db.salesOnDay(_day),
                builder: (_, fs) {
                  if (!fs.hasData) {
                    return const Center(
                        child: CircularProgressIndicator());
                  }
                  if (fs.data!.isEmpty) {
                    return const Card(
                        child: Padding(
                            padding: EdgeInsets.all(16),
                            child: Text('Bu gün fiş yok.')));
                  }
                  return Card(
                    child: Column(
                      children: fs.data!
                          .map((r) => ListTile(
                                dense: true,
                                title: Text(r.receiptNo,
                                    style: const TextStyle(
                                        fontFamily: 'monospace',
                                        fontSize: 13)),
                                subtitle: Text(
                                    '${fdate(r.date)} • ${_payTr(r.paymentType)}${r.customer.isNotEmpty ? ' • ${r.customer}' : ''}${r.discount > 0 ? ' • indirim ${money(r.discount)}' : ''}'),
                                trailing: Text(money(r.total),
                                    style: const TextStyle(
                                        fontWeight:
                                            FontWeight.bold)),
                              ))
                          .toList(),
                    ),
                  );
                },
              ),
            ],
          );
        },
      ),
    );
  }

  String _payTr(String p) => switch (p) {
        'kart' => 'Kart',
        'parcali' => 'Parçalı',
        'cari' => 'Cari',
        _ => 'Nakit',
      };

  Future<void> _print(AppDb db) async {
    try {
      final s = await db.daySummary(_day);
      final receipts = await db.salesOnDay(_day);
      final doc = pw.Document();
      final mono = pw.TextStyle(font: pw.Font.courier(), fontSize: 9);
      final monoB =
          pw.TextStyle(font: pw.Font.courierBold(), fontSize: 10);
      final center = pw.TextAlign.center;
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
              pw.Text('GUN SONU Z RAPORU', style: monoB, textAlign: center),
              pw.Text('Tarih: ${fday(_day)}', style: mono, textAlign: center),
              pw.Divider(),
              pw.Row(
                  mainAxisAlignment:
                      pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text('Brut ciro', style: mono),
                    pw.Text(money(s.total), style: mono),
                  ]),
              pw.Row(
                  mainAxisAlignment:
                      pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text('KDV toplam', style: mono),
                    pw.Text(money(s.kdv), style: mono),
                  ]),
              pw.Row(
                  mainAxisAlignment:
                      pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text('Urun kari', style: mono),
                    pw.Text(money(s.profit), style: mono),
                  ]),
              pw.Row(
                  mainAxisAlignment:
                      pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text('Gider', style: mono),
                    pw.Text(money(s.expenses), style: mono),
                  ]),
              pw.Row(
                  mainAxisAlignment:
                      pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text('NET KAR', style: monoB),
                    pw.Text(money(s.netProfit), style: monoB),
                  ]),
              pw.Divider(),
              pw.Text('Fis sayisi: ${s.receipts}', style: mono),
              ...receipts.map((r) => pw.Row(
                    mainAxisAlignment:
                        pw.MainAxisAlignment.spaceBetween,
                    children: [
                      pw.Text(r.receiptNo, style: mono),
                      pw.Text(money(r.total), style: mono),
                    ],
                  )),
              pw.SizedBox(height: 6),
              pw.Text('HAYIRLI ISLER', style: mono, textAlign: center),
            ],
          ),
        ),
      );
      await Printing.layoutPdf(
        onLayout: (_) async => doc.save(),
        name: 'z_${fday(_day)}',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Yazdırma hatası: $e')));
      }
    }
  }
}
