import 'dart:async';

import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/database/app_db.dart';
import '../../core/sync/cloud.dart';
import '../../core/utils/money.dart';

/// Hızlı ürün kartı: barkod hazır gelir, sadece ad + fiyat yazılır.
/// POS ve Hızlı Kayıt ekranı ortak kullanır. Kaydedilen ürünü döner.
Future<Product?> showQuickAddSheet(
    BuildContext context, AppDb db, String barcode) async {
  final name = TextEditingController();
  final sell = TextEditingController();
  final buy = TextEditingController();
  final stock = TextEditingController(text: '0');
  double kdv = 20;
  int? catId;
  final cats = await db.allCategories();

  if (!context.mounted) return null;
  return showModalBottomSheet<Product>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setD) => Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.bolt, color: Colors.amber),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('Hızlı Ekle: $barcode',
                        style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16)),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: name,
                autofocus: true,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                    labelText: 'Ürün adı *',
                    border: OutlineInputBorder()),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
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
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                          labelText: 'Satış ₺ * (KDV dahil)',
                          border: OutlineInputBorder()),
                    ),
                  ),
                  const SizedBox(width: 8),
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
                          border: OutlineInputBorder()),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<double>(
                      initialValue: kdv,
                      decoration: const InputDecoration(
                          labelText: 'KDV',
                          border: OutlineInputBorder()),
                      items: kdvOranlari
                          .map((o) => DropdownMenuItem(
                              value: o,
                              child: Text(kdvEtiket(o))))
                          .toList(),
                      onChanged: (v) => setD(() => kdv = v ?? 20),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: stock,
                      keyboardType:
                          const TextInputType.numberWithOptions(
                              decimal: true),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(
                            RegExp(r'[0-9,.]'))
                      ],
                      decoration: const InputDecoration(
                          labelText: 'Açılış stoğu',
                          border: OutlineInputBorder()),
                    ),
                  ),
                ],
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
              const SizedBox(height: 12),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                    minimumSize:
                        const Size.fromHeight(48)),
                onPressed: () async {
                  if (name.text.trim().isEmpty) return;
                  double num(String s) => parseTr(s);
                  if (num(sell.text) <= 0) return;
                  try {
                    final created =
                        await db.insertProduct(
                      ProductsCompanion.insert(
                        barcode: drift.Value(barcode),
                        name: name.text.trim(),
                        categoryId: drift.Value(catId),
                        buyPrice:
                            drift.Value(num(buy.text)),
                        sellPrice:
                            drift.Value(num(sell.text)),
                        kdvRate: drift.Value(kdv),
                        stock:
                            drift.Value(num(stock.text)),
                        uuid: newUuid(),
                      ),
                    );
                    if (ctx.mounted) {
                      Navigator.pop(ctx, created);
                      // Karşı ekrana anlık düşsün:
                      unawaited(Cloud.instance.syncNow());
                    }
                  } catch (e) {
                    if (ctx.mounted) {
                      ScaffoldMessenger.of(ctx).showSnackBar(
                          SnackBar(
                              content: Text(
                                  'Kayıt hatası: $e')));
                    }
                  }
                },
                icon: const Icon(Icons.check),
                label: const Text('Kaydet ve Devam Et'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
