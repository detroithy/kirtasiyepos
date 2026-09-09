import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app.dart';
import '../../core/database/app_db.dart';
import '../../core/sync/cloud.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/money.dart';

/// Yüzde -> yeni fiyat (test edilebilir saf fonksiyon).
double applyPercent(double price, double pct) {
  final v = price * (1 + pct / 100);
  return (v * 100).round() / 100;
}

/// Toplu Fiyat: kategoriye veya tüm mağazaya % zam/indirim.
/// Önizlemeli + onaylı; her satır kuyrukla senkrona girer.
class BulkPriceScreen extends ConsumerStatefulWidget {
  const BulkPriceScreen({super.key});

  @override
  ConsumerState<BulkPriceScreen> createState() => _BulkPriceScreenState();
}

class _BulkPriceScreenState extends ConsumerState<BulkPriceScreen> {
  int? _catId; // null = tümü
  final _pct = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _pct.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final db = ref.watch(dbProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Toplu Fiyat Güncelle')),
      body: FutureBuilder<List<Category>>(
        future: db.allCategories(),
        builder: (_, snap) {
          final cats = snap.data ?? [];
          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      DropdownButtonFormField<int?>(
                        initialValue: _catId,
                        decoration: const InputDecoration(
                            labelText: 'Kapsam',
                            border: OutlineInputBorder()),
                        items: [
                          const DropdownMenuItem(
                              value: null,
                              child: Text('Tüm ürünler')),
                          ...cats.map((c) => DropdownMenuItem(
                              value: c.id,
                              child: Text(c.name))),
                        ],
                        onChanged: (v) =>
                            setState(() => _catId = v),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _pct,
                        keyboardType:
                            const TextInputType.numberWithOptions(
                                decimal: true, signed: true),
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(
                              RegExp(r'[0-9,.\-]'))
                        ],
                        decoration: const InputDecoration(
                            labelText: 'Yüzde (+zam / -indirim)',
                            hintText: 'örn. 10 veya -5',
                            border: OutlineInputBorder()),
                        onChanged: (_) => setState(() {}),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        children: [
                          for (final p in ['+5', '+10', '-5', '-10'])
                            ActionChip(
                              label: Text('%$p'),
                              onPressed: () => setState(() =>
                                  _pct.text = p),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              FutureBuilder<List<Product>>(
                future: db
                    .watchProducts()
                    .first
                    .then((list) => _catId == null
                        ? list
                        : list
                            .where((p) =>
                                p.categoryId == _catId)
                            .toList()),
                builder: (_, ps) {
                  if (!ps.hasData) {
                    return const Center(
                        child: CircularProgressIndicator());
                  }
                  final list = ps.data!;
                  final pct = double.tryParse(
                          _pct.text.replaceAll(',', '.')) ??
                      0;
                  return Column(
                    crossAxisAlignment:
                        CrossAxisAlignment.stretch,
                    children: [
                      Card(
                        color: PosColors.infoBg,
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(
                            '${list.length} ürün etkilenecek'
                            '${pct != 0 ? ' • örnek: ${list.isEmpty ? '-' : '${list.first.name}: ${money(list.first.sellPrice)} → ${money(applyPercent(list.first.sellPrice, pct))}'}' : ''}',
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: PosColors.amber,
                          foregroundColor: Colors.white,
                          minimumSize:
                              const Size.fromHeight(48),
                        ),
                        onPressed: (list.isEmpty ||
                                pct == 0 ||
                                _busy)
                            ? null
                            : () => _apply(context, db, list,
                                pct),
                        icon: _busy
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child:
                                    CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white))
                            : const Icon(Icons.check),
                        label: Text(_busy
                            ? 'Uygulanıyor...'
                            : '%$pct Uygula (${list.length} ürün)'),
                      ),
                    ],
                  );
                },
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _apply(BuildContext context, AppDb db,
      List<Product> list, double pct) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Emin misin?'),
        content: Text(
            '${list.length} ürünün satış fiyatı %$pct değişecek. Bu işlem geri alınamaz, fiş geçmişi etkilenmez.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Vazgeç')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Uygula')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    setState(() => _busy = true);
    var n = 0;
    try {
      for (final p in list) {
        await db.updateProduct(
            p.id,
            ProductsCompanion(
              sellPrice: drift.Value(
                  applyPercent(p.sellPrice, pct)),
            ));
        n++;
      }
      Cloud.instance.refreshPending();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('$n ürün güncellendi.'),
            backgroundColor: Colors.green.shade700));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Hata: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
