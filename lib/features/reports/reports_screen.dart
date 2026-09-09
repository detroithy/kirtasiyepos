import 'dart:io';

import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../app.dart';
import '../../core/database/app_db.dart';
import '../../core/sync/cloud.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/money.dart';
import '../../core/widgets/kpi_card.dart';
import 'charts_section.dart';

/// Mali Raporlar: aralık seçimi, KPI'lar, KDV matris tablosu,
/// ödeme dağılımı, CSV aktarım.
class ReportsScreen extends ConsumerStatefulWidget {
  /// HomeShell sekmeye dönüldüğünde true olur (veri tazelenir).
  final bool active;
  const ReportsScreen({super.key, this.active = true});

  @override
  ConsumerState<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends ConsumerState<ReportsScreen>
    with SyncRefreshMixin {
  DateTime _start = DateTime.now().subtract(const Duration(days: 30));
  DateTime _end = DateTime.now();

  @override
  void didUpdateWidget(covariant ReportsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active && mounted) setState(() {});
  }

  Future<void> _pick(bool isStart) async {
    final d = await showDatePicker(
      context: context,
      initialDate: isStart ? _start : _end,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (d != null) {
      setState(() {
        if (isStart) {
          _start = d;
        } else {
          _end = d;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final db = ref.watch(dbProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('KırtasiyePOS • Mali Raporlar')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _pick(true),
                    icon: const Icon(Icons.date_range, size: 18),
                    label: Text(fday(_start)),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 6),
                  child: Text('→'),
                ),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _pick(false),
                    icon: const Icon(Icons.date_range, size: 18),
                    label: Text(fday(_end)),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: FutureBuilder<RangeSummary>(
              future: db.rangeSummary(_start, _end),
              builder: (_, snap) {
                if (snap.hasError) {
                  return Center(
                      child: Text('Yüklenemedi: ${snap.error}',
                          style:
                              const TextStyle(color: Colors.red)));
                }
                if (!snap.hasData) {
                  return const Center(
                      child: CircularProgressIndicator());
                }
                final s = snap.data!;
                return ListView(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  children: [
                    GridView.count(
                      crossAxisCount: 2,
                      shrinkWrap: true,
                      physics:
                          const NeverScrollableScrollPhysics(),
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 8,
                      childAspectRatio: 1.35,
                      children: [
                        KpiCard(
                            label: 'TOPLAM CİRO',
                            value: money(s.total),
                            icon: Icons.payments,
                            color: PosColors.navy,
                            sub: '${s.receipts} fiş'),
                        KpiCard(
                            label: 'NET KAR',
                            value: money(s.netProfit),
                            icon: Icons.trending_up,
                            color: PosColors.okTx,
                            sub:
                                'Kar ${money(s.profit)} • Gider ${money(s.expenses)}'),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (s.returns > 0)
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 12),
                          child: Row(
                            children: [
                              const Icon(
                                  Icons.assignment_return,
                                  color: Colors.grey),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                    'İadeler (${s.returnsCount} fiş) cirodan düşüldü',
                                    style: const TextStyle(
                                        color: Colors.grey)),
                              ),
                              Text('-${money(s.returns)}',
                                  style: const TextStyle(
                                      fontWeight:
                                          FontWeight.bold)),
                            ],
                          ),
                        ),
                      ),
                    if (s.returns > 0) const SizedBox(height: 12),
                    if (s.change != 0)
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 12),
                          child: Row(
                            children: [
                              const Icon(Icons.change_circle,
                                  color: Colors.grey),
                              const SizedBox(width: 8),
                              const Expanded(
                                child: Text(
                                    'Verilen para üstü (kârı etkilemez)',
                                    style: TextStyle(
                                        color: Colors.grey)),
                              ),
                              Text(money(s.change),
                                  style: const TextStyle(
                                      fontWeight:
                                          FontWeight.bold)),
                            ],
                          ),
                        ),
                      ),
                    if (s.change != 0) const SizedBox(height: 12),
                    _sectionTitle('KDV Oranlarına Göre Dağılım'),
                    const SizedBox(height: 6),
                    Card(
                      child: s.kdvBreakdown.isEmpty
                          ? const Padding(
                              padding: EdgeInsets.all(16),
                              child: Text(
                                  'Bu aralıkta satış yok.'))
                          : SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: DataTable(
                                headingTextStyle: const TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    color: PosColors.ink2),
                                columns: const [
                                  DataColumn(
                                      label: Text('KDV ORANI')),
                                  DataColumn(
                                      numeric: true,
                                      label:
                                          Text('MATRAH (KDV HARİÇ)')),
                                  DataColumn(
                                      numeric: true,
                                      label: Text(
                                          'HESAPLANAN KDV')),
                                  DataColumn(
                                      numeric: true,
                                      label: Text(
                                          'KDV DAHİL TOPLAM')),
                                ],
                                rows: [
                                  ...s.kdvBreakdown.entries.map((e) {
                                    final rate = e.key;
                                    final sl = e.value;
                                    return DataRow(cells: [
                                      DataCell(Text(
                                          kdvEtiket(rate),
                                          style: const TextStyle(
                                              fontWeight:
                                                  FontWeight.bold))),
                                      DataCell(
                                          Text(money(sl.matrah))),
                                      DataCell(
                                          Text(money(sl.kdv))),
                                      DataCell(Text(money(
                                          sl.matrah + sl.kdv),
                                          style: const TextStyle(
                                              fontWeight:
                                                  FontWeight.bold))),
                                    ]);
                                  }),
                                  DataRow(
                                    color:
                                        WidgetStateProperty.all(
                                            PosColors.infoBg),
                                    cells: [
                                      const DataCell(Text(
                                          'Genel Toplam',
                                          style: TextStyle(
                                              fontWeight:
                                                  FontWeight.bold))),
                                      DataCell(Text(money(s
                                          .kdvBreakdown.values
                                          .fold<double>(
                                              0,
                                              (a, b) =>
                                                  a + b.matrah)),
                                          style: const TextStyle(
                                              fontWeight:
                                                  FontWeight.bold))),
                                      DataCell(Text(money(s.kdv),
                                          style: const TextStyle(
                                              fontWeight:
                                                  FontWeight.bold,
                                              color:
                                                  PosColors.amberDark))),
                                      DataCell(Text(money(s.total),
                                          style: const TextStyle(
                                              fontWeight:
                                                  FontWeight.bold))),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                    ),
                    const SizedBox(height: 12),
                    _sectionTitle('Ödeme Yöntemleri Dağılımı'),
                    const SizedBox(height: 6),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: (s.payTotals.isEmpty &&
                                    s.payCounts.isEmpty)
                            ? const Text('Satış yok.')
                            : Column(
                                children: [
                                  _payBar(s),
                                  const SizedBox(height: 8),
                                  ..._payRows(s),
                                ],
                              ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    ChartsSection(
                        db: db, start: _start, end: _end),
                    const SizedBox(height: 12),
                    FilledButton.tonalIcon(
                      onPressed: () => _exportCsv(context, db),
                      icon: const Icon(Icons.download),
                      label: const Text(
                          'CSV Olarak Kaydet (Excel açar)'),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String t) => Text(t,
      style: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w700,
          color: PosColors.navy));

  Color _payColor(String type) => switch (type) {
        'kart' => PosColors.navy,
        'cari' => PosColors.critTx,
        'parcali' => PosColors.royal,
        _ => PosColors.amber,
      };

  String _payLabel(String type) => switch (type) {
        'kart' => 'Kredi Kartı',
        'cari' => 'Cari (açık veresiye)',
        'parcali' => 'Parçalı fiş',
        _ => 'Nakit',
      };

  /// Tutar + adet satırları (parçalı adedi de görünür).
  List<Widget> _payRows(RangeSummary s) {
    final keys = {...s.payTotals.keys, ...s.payCounts.keys};
    return keys.map((k) {
      final value = s.payTotals[k] ?? 0;
      final count = s.payCounts[k] ?? 0;
      final pct =
          s.total > 0 ? value / s.total * 100 : 0.0;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: _payColor(k),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
                child: Text(
                    '${_payLabel(k)} • $count işlem (%${pct.toStringAsFixed(1)})')),
            Text(money(value),
                style:
                    const TextStyle(fontWeight: FontWeight.bold)),
          ],
        ),
      );
    }).toList();
  }

  Widget _payBar(RangeSummary s) {
    final sum =
        s.payTotals.values.fold(0.0, (a, b) => a + b);
    if (sum <= 0) return const SizedBox.shrink();
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: Row(
        children: s.payTotals.entries.map((e) {
          final flex =
              (e.value / sum * 1000).round().clamp(1, 1000);
          return Expanded(
            flex: flex,
            child: Container(height: 10, color: _payColor(e.key)),
          );
        }).toList(),
      ),
    );
  }

  Future<void> _exportCsv(BuildContext context, AppDb db) async {
    try {
      final sales = await (db.select(db.sales)
            ..where((t) => t.date.isBetweenValues(
                _start, _end.add(const Duration(days: 1))))
            ..orderBy([(t) => drift.OrderingTerm.asc(t.date)]))
          .get();
      final buf = StringBuffer(
          'FisNo;Tarih;Toplam;KDV;Kar;Indirim;Odeme;Musteri;Nakit;Kart;Tahsil;ParaUstu\n');
      for (final s in sales) {
        buf.writeln(
            '${s.receiptNo};${fdate(s.date)};${s.total};${s.kdvTotal};${s.profitTotal};${s.discount};${s.paymentType};${s.customer};${s.cashAmount};${s.cardAmount};${s.paid};${s.changeAmount}');
      }
      final dir = await getApplicationDocumentsDirectory();
      final file = File(
          '${dir.path}/kirtasiye/satis_${fday(_start)}_${fday(_end)}.csv');
      await file.parent.create(recursive: true);
      await file.writeAsString('﻿$buf'); // BOM: Excel Türkçe için
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Kaydedildi: ${file.path}')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Aktarım hatası: $e')));
      }
    }
  }
}
