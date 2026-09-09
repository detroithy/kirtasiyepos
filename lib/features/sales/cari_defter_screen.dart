import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app.dart';
import '../../core/database/app_db.dart';
import '../../core/sync/cloud.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/money.dart';

/// Cari (veresiye) defteri: açık fişler + tahsilat.
/// Ciro satış gününe yazılmıştır; tahsilat ciroyu iki kez saymaz.
class CariDefterScreen extends ConsumerStatefulWidget {
  /// Pushtan açılışta true (veri tazelenir).
  final bool active;
  const CariDefterScreen({super.key, this.active = true});

  @override
  ConsumerState<CariDefterScreen> createState() =>
      _CariDefterScreenState();
}

class _CariDefterScreenState
    extends ConsumerState<CariDefterScreen> with SyncRefreshMixin {
  void _reload() => setState(() {});

  @override
  void didUpdateWidget(covariant CariDefterScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final db = ref.watch(dbProvider);
    return Scaffold(
      appBar:
          AppBar(title: const Text('KırtasiyePOS • Cari Defter')),
      body: FutureBuilder<List<Sale>>(
        future: db.openDebts(),
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
          final list = snap.data!;
          final total = list.fold(
              0.0, (s, r) => s + (r.total - r.paid));
          return Column(
            children: [
              Card(
                margin: const EdgeInsets.all(12),
                color: PosColors.critBg,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text('TOPLAM AÇIK VERESİYE',
                            style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: PosColors.critTx)),
                      ),
                      Text(money(total),
                          style: const TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.w800,
                              color: PosColors.critTx)),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: list.isEmpty
                    ? const Center(
                        child: Text('Açık veresiye yok.'))
                    : ListView.builder(
                        itemCount: list.length,
                        itemBuilder: (_, i) {
                          final s = list[i];
                          final kalan = s.total - s.paid;
                          return Card(
                            margin:
                                const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 4),
                            child: ListTile(
                              title: Text(
                                  s.customer.isEmpty
                                      ? '(isimsiz)'
                                      : s.customer,
                                  style: const TextStyle(
                                      fontWeight:
                                          FontWeight.bold)),
                              subtitle: Text(
                                  '${s.receiptNo} • ${fday(s.date)}\nÖdenen ${money(s.paid)} / Toplam ${money(s.total)}'),
                              isThreeLine: true,
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Column(
                                    mainAxisAlignment:
                                        MainAxisAlignment
                                            .center,
                                    crossAxisAlignment:
                                        CrossAxisAlignment
                                            .end,
                                    children: [
                                      const Text('KALAN',
                                          style: TextStyle(
                                              fontSize: 10,
                                              color: Colors
                                                  .grey)),
                                      Text(money(kalan),
                                          style: const TextStyle(
                                              fontWeight:
                                                  FontWeight
                                                      .bold,
                                              fontSize: 16,
                                              color: PosColors
                                                  .critTx)),
                                    ],
                                  ),
                                  const SizedBox(width: 8),
                                  FilledButton.tonal(
                                    onPressed: () =>
                                        _collectDialog(
                                            context, db, s),
                                    child:
                                        const Text('Tahsil Et'),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _collectDialog(
      BuildContext context, AppDb db, Sale s) async {
    final kalan = s.total - s.paid;
    final ctrl =
        TextEditingController(text: kalan.toString());
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
            '${s.customer.isEmpty ? '(isimsiz)' : s.customer} • Kalan ${money(kalan)}'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType:
              const TextInputType.numberWithOptions(
                  decimal: true),
          inputFormatters: [
            FilteringTextInputFormatter.allow(
                RegExp(r'[0-9,.]'))
          ],
          decoration: const InputDecoration(
              labelText: 'Tahsil edilen ₺',
              border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Vazgeç')),
          FilledButton(
            onPressed: () {
              final a = double.tryParse(
                      ctrl.text.replaceAll(',', '.')) ??
                  0;
              if (a <= 0) return;
              Navigator.pop(ctx, true);
              _doCollect(db, s.id, a.clamp(0, kalan));
            },
            child: const Text('Kaydet'),
          ),
        ],
      ),
    );
    if (ok == true) _reload();
  }

  Future<void> _doCollect(AppDb db, int saleId, double amount) async {
    try {
      await db.collectDebt(saleId: saleId, amount: amount);
      Cloud.instance.refreshPending();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Hata: $e')));
      }
    }
  }
}
