import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app.dart';
import '../../core/database/app_db.dart';
import '../../core/sync/cloud.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/money.dart';
import '../../core/widgets/kpi_card.dart';

class DashboardScreen extends ConsumerStatefulWidget {
  /// HomeShell sekmeye dönüldüğünde true olur (veri tazelenir).
  final bool active;
  const DashboardScreen({super.key, this.active = true});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen>
    with SyncRefreshMixin {
  DateTime _day = DateTime.now();

  @override
  void didUpdateWidget(covariant DashboardScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active && mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final db = ref.watch(dbProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('KırtasiyePOS • Günlük Özet'),
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
            icon: const Icon(Icons.today),
            tooltip: 'Bugün',
            onPressed: () => setState(() => _day = DateTime.now()),
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
                      label: 'GÜNLÜK BRÜT CİRO',
                      value: money(s.total),
                      icon: Icons.payments,
                      color: PosColors.navy,
                      sub: '${s.receipts} fiş'),
                  KpiCard(
                      label: 'TAHAKKUK EDEN KDV',
                      value: money(s.kdv),
                      icon: Icons.percent,
                      color: PosColors.amber),
                  KpiCard(
                      label: 'ÜRÜN KARI',
                      value: money(s.profit),
                      icon: Icons.trending_up,
                      color: PosColors.okTx),
                  KpiCard(
                      label: 'GİDER',
                      value: money(s.expenses),
                      icon: Icons.money_off,
                      color: PosColors.critTx),
                ],
              ),
              const SizedBox(height: 8),
              if (s.returns > 0)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    child: Row(
                      children: [
                        const Icon(Icons.assignment_return,
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
                                fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ),
                ),
              if (s.returns > 0) const SizedBox(height: 8),
              Card(
                color: PosColors.navy,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text('NET KAR',
                            style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 1)),
                      ),
                      Flexible(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerRight,
                          child: Text(money(s.netProfit),
                              maxLines: 1,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 26,
                                  fontWeight: FontWeight.w800,
                                  fontFeatures: [
                                    FontFeature.tabularFigures()
                                  ])),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 48,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: PosColors.amber,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(6)),
                  ),
                  onPressed: () => _expenseDialog(context, db),
                  icon: const Icon(Icons.add),
                  label: const Text('Gider Ekle (kira, elektrik...)',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _expenseDialog(BuildContext context, AppDb db) async {
    final amount = TextEditingController();
    final note = TextEditingController();
    String cat = 'Kira';
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Gider Ekle'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                initialValue: cat,
                items: const [
                  'Kira',
                  'Elektrik',
                  'Su',
                  'İnternet',
                  'Personel',
                  'Vergi/Harç',
                  'Diğer'
                ]
                    .map((e) =>
                        DropdownMenuItem(value: e, child: Text(e)))
                    .toList(),
                onChanged: (v) => setD(() => cat = v ?? 'Diğer'),
                decoration: const InputDecoration(
                    labelText: 'Kategori', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: amount,
                keyboardType: const TextInputType.numberWithOptions(
                    decimal: true),
                decoration: const InputDecoration(
                    labelText: 'Tutar ₺', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: note,
                decoration: const InputDecoration(
                    labelText: 'Not', border: OutlineInputBorder()),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Vazgeç')),
            FilledButton(
              onPressed: () async {
                final a = parseTr(amount.text);
                if (a <= 0) return;
                await db.insertExpense(
                  ExpensesCompanion.insert(
                    date: drift.Value(_day),
                    category: cat,
                    amount: a,
                    note: drift.Value(
                        note.text.isEmpty ? null : note.text),
                    uuid: newUuid(),
                  ),
                );
                if (ctx.mounted) Navigator.pop(ctx);
                setState(() {});
              },
              child: const Text('Kaydet'),
            ),
          ],
        ),
      ),
    );
  }
}
