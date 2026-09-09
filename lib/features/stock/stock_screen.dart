import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app.dart';
import '../../core/database/app_db.dart';
import '../../core/sync/cloud.dart';
import '../../core/utils/money.dart';
import 'suppliers_screen.dart';

/// Stok merkezi: TÜM ürünler listelenir, giriş/çıkış/sayım yapılır,
/// kritikler rozetle belli olur, geçmiş ayrı sekmede.
class StockScreen extends ConsumerStatefulWidget {
  /// HomeShell sekmeye dönüldüğünde true olur (geçmiş tazelenir).
  final bool active;
  const StockScreen({super.key, this.active = true});

  @override
  ConsumerState<StockScreen> createState() => _StockScreenState();
}

class _StockScreenState extends ConsumerState<StockScreen>
    with SyncRefreshMixin {
  bool _showHistory = false;
  bool _onlyCritical = false;
  String _query = '';
  final _searchCtrl = TextEditingController();

  @override
  void didUpdateWidget(covariant StockScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active && mounted) setState(() {});
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final db = ref.watch(dbProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('KırtasiyePOS • Stok Takibi'),
        actions: [
          IconButton(
            tooltip: 'Tedarikçiler (borç defteri)',
            icon: const Icon(Icons.local_shipping),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => const SuppliersScreen()),
            ),
          ),
          Row(
            children: [
              const Text('Geçmiş'),
              Switch(
                  value: _showHistory,
                  onChanged: (v) => setState(() => _showHistory = v)),
            ],
          ),
        ],
      ),
      body: _showHistory ? _history(db) : _allProducts(db),
    );
  }

  // ---------- TÜM ÜRÜNLER ----------
  Widget _allProducts(AppDb db) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: TextField(
            controller: _searchCtrl,
            decoration: const InputDecoration(
              labelText: 'Ürün / barkod ara',
              prefixIcon: Icon(Icons.search),
              border: OutlineInputBorder(),
            ),
            onChanged: (v) =>
                setState(() => _query = v.trim().toLowerCase()),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              FilterChip(
                label: const Text('Tümü'),
                selected: !_onlyCritical,
                onSelected: (_) => setState(() => _onlyCritical = false),
              ),
              const SizedBox(width: 8),
              FilterChip(
                label: const Text('Sadece kritik'),
                selected: _onlyCritical,
                onSelected: (_) => setState(() => _onlyCritical = true),
              ),
            ],
          ),
        ),
        Expanded(
          child: StreamBuilder<List<Product>>(
            stream: db.watchProducts(),
            builder: (_, snap) {
              if (!snap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              var list = snap.data!;
              if (_onlyCritical) {
                list = list
                    .where((p) => p.stock <= p.criticalLevel)
                    .toList();
              }
              if (_query.isNotEmpty) {
                list = list
                    .where((p) =>
                        p.name.toLowerCase().contains(_query) ||
                        (p.barcode?.contains(_query) ?? false))
                    .toList();
              }
              if (list.isEmpty) {
                return const Center(
                    child: Text('Gösterilecek ürün yok.'));
              }
              final criticalCount = snap.data!
                  .where((p) => p.stock <= p.criticalLevel)
                  .length;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (criticalCount > 0)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                      child: Text(
                        '⚠ $criticalCount ürün kritik seviyede!',
                        style: TextStyle(
                            color: Colors.red.shade700,
                            fontWeight: FontWeight.bold),
                      ),
                    ),
                  Expanded(
                    child: ListView.builder(
                      itemCount: list.length,
                      itemBuilder: (_, i) {
                        final p = list[i];
                        final low = p.stock <= p.criticalLevel;
                        return Card(
                          margin: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 4),
                          child: ListTile(
                            leading: Icon(
                              low
                                  ? Icons.warning
                                  : Icons.inventory_2,
                              color: low ? Colors.red : null,
                            ),
                            title: Text(p.name),
                            subtitle: Text(
                              'Stok: ${fmtQty(p.stock)} ${p.unit} • Kritik: ${fmtQty(p.criticalLevel)}'
                              '${low ? '  • KRİTİK!' : ''}',
                              style: TextStyle(
                                  color: low ? Colors.red.shade700 : null,
                                  fontWeight:
                                      low ? FontWeight.bold : null),
                            ),
                            trailing: PopupMenuButton<String>(
                              icon: const Icon(Icons.more_vert),
                              onSelected: (t) =>
                                  _adjustDialog(context, db, p, t),
                              itemBuilder: (_) => const [
                                PopupMenuItem(
                                    value: 'giris',
                                    child: Text('Stok Girişi (+)')),
                                PopupMenuItem(
                                    value: 'cikis',
                                    child:
                                        Text('Stok Çıkışı (fire/zayi −)')),
                                PopupMenuItem(
                                    value: 'sayim',
                                    child:
                                        Text('Sayım (stoğu eşitle)')),
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
        ),
      ],
    );
  }

  Future<void> _adjustDialog(
      BuildContext context, AppDb db, Product p, String type) async {
    final titles = {
      'giris': 'Stok Girişi',
      'cikis': 'Stok Çıkışı (fire / zayi / kullanım)',
      'sayim': 'Sayım Düzeltme',
    };
    final labels = {
      'giris': 'Giren miktar',
      'cikis': 'Çıkan miktar',
      'sayim': 'Sayılan (gerçek) stok',
    };
    final qty = TextEditingController();
    final note = TextEditingController(text: type == 'giris' ? 'Alım' : '');
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${titles[type]}: ${p.name}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Mevcut stok: ${fmtQty(p.stock)} ${p.unit}'),
            const SizedBox(height: 8),
            TextField(
              controller: qty,
              autofocus: true,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9,.]'))
              ],
              decoration: InputDecoration(
                  labelText: labels[type],
                  border: const OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: note,
              decoration: const InputDecoration(
                  labelText: 'Not (tedarikçi / fatura / neden)',
                  border: OutlineInputBorder()),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Vazgeç')),
          FilledButton(
            onPressed: () async {
              final q =
                  double.tryParse(qty.text.replaceAll(',', '.')) ?? -1;
              if (q < 0) return;
              try {
                if (type == 'sayim') {
                  await db.adjustStock(
                      productId: p.id,
                      qtyChange: q,
                      type: 'sayim',
                      note: note.text.isEmpty ? null : note.text);
                } else if (type == 'cikis') {
                  if (p.stock - q < 0) {
                    throw 'Stok negatife düşer! Mevcut: ${fmtQty(p.stock)}';
                  }
                  await db.adjustStock(
                      productId: p.id,
                      qtyChange: -q,
                      type: 'cikis',
                      note: note.text.isEmpty ? null : note.text);
                } else {
                  await db.adjustStock(
                      productId: p.id,
                      qtyChange: q,
                      type: 'giris',
                      note: note.text.isEmpty ? null : note.text);
                }
                if (ctx.mounted) Navigator.pop(ctx);
              } catch (e) {
                if (ctx.mounted) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                      SnackBar(content: Text('Hata: $e')));
                }
              }
            },
            child: const Text('Kaydet'),
          ),
        ],
      ),
    );
  }

  // ---------- HAREKET GEÇMİŞİ ----------
  Widget _history(AppDb db) {
    return FutureBuilder<List<StockMovement>>(
      future: (db.select(db.stockMovements)
            ..orderBy([(t) => drift.OrderingTerm.desc(t.date)])
            ..limit(200))
          .get(),
      builder: (_, snap) {
        if (snap.hasError) {
          return Center(
              child: Text('Yüklenemedi: ${snap.error}',
                  style: const TextStyle(color: Colors.red)));
        }
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final list = snap.data!;
        if (list.isEmpty) {
          return const Center(child: Text('Hareket yok.'));
        }
        return FutureBuilder<Map<int, String>>(
          future: _productNames(db, list.map((m) => m.productId).toSet()),
          builder: (_, ns) {
            final names = ns.data ?? {};
            return ListView.builder(
              itemCount: list.length,
              itemBuilder: (_, i) {
                final m = list[i];
                return ListTile(
                  leading: Icon(
                    m.qty >= 0
                        ? Icons.arrow_downward
                        : Icons.arrow_upward,
                    color: m.qty >= 0 ? Colors.green : Colors.orange,
                  ),
                  title: Text(names[m.productId] ??
                      'Ürün #${m.productId}'),
                  subtitle: Text('${m.type} • ${fdate(m.date)}'
                      '${m.note != null && m.note!.isNotEmpty ? ' • ${m.note}' : ''}'),
                  trailing: Text(
                    '${m.qty > 0 ? '+' : ''}${fmtQty(m.qty)} (${fmtQty(m.prevStock)}→${fmtQty(m.newStock)})',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  Future<Map<int, String>> _productNames(AppDb db, Set<int> ids) async {
    if (ids.isEmpty) return {};
    final rows = await (db.select(db.products)
          ..where((t) => t.id.isIn(ids.toList())))
        .get();
    return {for (final r in rows) r.id: r.name};
  }
}
