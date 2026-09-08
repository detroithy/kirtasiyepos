import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app.dart';
import '../../core/database/app_db.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/barcode_gen.dart';
import '../../core/utils/money.dart';
import '../../core/widgets/stock_badge.dart';
import '../sales/pos_print.dart';
import 'hizli_kayit_screen.dart';

class ProductsScreen extends ConsumerWidget {
  const ProductsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final db = ref.watch(dbProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('KırtasiyePOS • Stok & Ürünler'),
        actions: [
          FilledButton.tonalIcon(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => const HizliKayitScreen()),
            ),
            icon: const Icon(Icons.bolt, size: 18),
            label: const Text('Hızlı Kayıt'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: PosColors.navy,
        foregroundColor: Colors.white,
        onPressed: () => _productDialog(context, db),
        icon: const Icon(Icons.add),
        label: const Text('Yeni Ürün'),
      ),
      body: StreamBuilder<List<Product>>(
        stream: db.watchProducts(),
        builder: (_, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final list = snap.data!;
          if (list.isEmpty) {
            return const Center(child: Text('Henüz ürün yok.'));
          }
          return ListView.builder(
            itemCount: list.length,
            itemBuilder: (_, i) {
              final p = list[i];
              return Card(
                margin:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: ListTile(
                  title: Text(p.name),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                          '${p.barcode ?? 'barkodsuz'} • Alış: ${money(p.buyPrice)} • ${p.unit}'),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 6,
                        children: [
                          StockBadge(
                              stock: p.stock,
                              critical: p.criticalLevel),
                          KdvBadge(rate: p.kdvRate),
                        ],
                      ),
                    ],
                  ),
                  isThreeLine: true,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(money(p.sellPrice),
                          style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16)),
                      PopupMenuButton<String>(
                        icon: const Icon(Icons.more_vert),
                        onSelected: (v) {
                          if (v == 'edit') {
                            _productDialog(context, db,
                                product: p);
                          } else if (v == 'label') {
                            _printLabel(context, p);
                          } else if (v == 'delete') {
                            _delete(context, db, p);
                          }
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(
                              value: 'edit',
                              child: Text('Düzenle')),
                          PopupMenuItem(
                              value: 'label',
                              child: Text('Etiket Bas')),
                          PopupMenuItem(
                              value: 'delete',
                              child: Text('Sil',
                                  style: TextStyle(
                                      color: Colors.red))),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _printLabel(BuildContext context, Product p) async {
    if (p.barcode == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Önce barkod ekleyin (Düzenle > Üret)')));
      return;
    }
    try {
      await printLabel(
        name: p.name,
        barcode: p.barcode!,
        price: p.sellPrice,
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Yazdırma hatası: $e')));
      }
    }
  }

  Future<void> _delete(BuildContext context, AppDb db, Product p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Ürünü sil?'),
        content: Text('${p.name}\nSatış geçmişi korunur.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Vazgeç')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Sil')),
        ],
      ),
    );
    if (ok == true) {
      await (db.delete(db.products)..where((t) => t.id.equals(p.id))).go();
    }
  }

  Future<void> _productDialog(BuildContext context, AppDb db,
      {Product? product}) async {
    final name = TextEditingController(text: product?.name ?? '');
    final barcode = TextEditingController(text: product?.barcode ?? '');
    final buy =
        TextEditingController(text: product?.buyPrice.toString() ?? '');
    final sell =
        TextEditingController(text: product?.sellPrice.toString() ?? '');
    final stock =
        TextEditingController(text: product?.stock.toString() ?? '0');
    final critical = TextEditingController(
        text: product?.criticalLevel.toString() ?? '5');
    double kdv = product?.kdvRate ?? 20;
    final cats = await db.allCategories();
    int? catId = product?.categoryId;

    if (!context.mounted) return;
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title:
              Text(product == null ? 'Yeni Ürün' : 'Ürünü Düzenle'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                    controller: name,
                    decoration: const InputDecoration(
                        labelText: 'Ürün adı *', border: OutlineInputBorder())),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                          controller: barcode,
                          decoration: const InputDecoration(
                              labelText: 'Barkod (boş olabilir)',
                              border: OutlineInputBorder(),
                              hintText:
                                  'Okuyucuyla okut veya üret')),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.tonalIcon(
                      onPressed: () async {
                        // Eşsiz olana kadar üret.
                        var code = generateInternalBarcode();
                        for (var i = 0;
                            i < 5 &&
                                await db.findByBarcode(code) !=
                                    null;
                            i++) {
                          code = generateInternalBarcode();
                        }
                        barcode.text = code;
                        setD(() {});
                      },
                      icon: const Icon(Icons.auto_awesome, size: 18),
                      label: const Text('Üret'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                        child: TextField(
                            controller: buy,
                            keyboardType:
                                const TextInputType.numberWithOptions(
                                    decimal: true),
                            inputFormatters: [
                              FilteringTextInputFormatter.allow(
                                  RegExp(r'[0-9,.]'))
                            ],
                            decoration: const InputDecoration(
                                labelText: 'Alış ₺',
                                border: OutlineInputBorder()))),
                    const SizedBox(width: 8),
                    Expanded(
                        child: TextField(
                            controller: sell,
                            keyboardType:
                                const TextInputType.numberWithOptions(
                                    decimal: true),
                            inputFormatters: [
                              FilteringTextInputFormatter.allow(
                                  RegExp(r'[0-9,.]'))
                            ],
                            decoration: const InputDecoration(
                                labelText: 'Satış ₺ (KDV dahil)',
                                border: OutlineInputBorder()))),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                        child: TextField(
                            controller: stock,
                            keyboardType:
                                const TextInputType.numberWithOptions(
                                    decimal: true),
                            decoration: const InputDecoration(
                                labelText: 'Stok',
                                border: OutlineInputBorder()))),
                    const SizedBox(width: 8),
                    Expanded(
                        child: TextField(
                            controller: critical,
                            keyboardType:
                                const TextInputType.numberWithOptions(
                                    decimal: true),
                            decoration: const InputDecoration(
                                labelText: 'Kritik seviye',
                                border: OutlineInputBorder()))),
                  ],
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<double>(
                  initialValue: kdv,
                  decoration: const InputDecoration(
                      labelText: 'KDV', border: OutlineInputBorder()),
                  items: kdvOranlari
                      .map((o) => DropdownMenuItem(
                          value: o, child: Text(kdvEtiket(o))))
                      .toList(),
                  onChanged: (v) => setD(() => kdv = v ?? 20),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<int?>(
                  initialValue: catId,
                  decoration: const InputDecoration(
                      labelText: 'Kategori',
                      border: OutlineInputBorder()),
                  items: [
                    const DropdownMenuItem(
                        value: null, child: Text('Yok')),
                    ...cats.map((c) => DropdownMenuItem(
                        value: c.id, child: Text(c.name))),
                  ],
                  onChanged: (v) => setD(() => catId = v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Vazgeç')),
            FilledButton(
              onPressed: () async {
                if (name.text.trim().isEmpty) return;
                double num(String s) =>
                    double.tryParse(s.replaceAll(',', '.')) ?? 0;
                final comp = ProductsCompanion(
                  name: drift.Value(name.text.trim()),
                  barcode: drift.Value(
                      barcode.text.trim().isEmpty ? null : barcode.text.trim()),
                  buyPrice: drift.Value(num(buy.text)),
                  sellPrice: drift.Value(num(sell.text)),
                  stock: drift.Value(num(stock.text)),
                  criticalLevel: drift.Value(num(critical.text)),
                  kdvRate: drift.Value(kdv),
                  categoryId: drift.Value(catId),
                  updatedAt: drift.Value(DateTime.now()),
                  syncStatus: const drift.Value(1),
                );
                try {
                  if (product == null) {
                    await db.into(db.products).insert(comp);
                  } else {
                    await (db.update(db.products)
                          ..where((t) => t.id.equals(product.id)))
                        .write(comp);
                  }
                  if (ctx.mounted) Navigator.pop(ctx);
                } catch (e) {
                  if (ctx.mounted) {
                    ScaffoldMessenger.of(ctx).showSnackBar(
                        SnackBar(content: Text('Kayıt hatası: $e')));
                  }
                }
              },
              child: const Text('Kaydet'),
            ),
          ],
        ),
      ),
    );
  }
}
