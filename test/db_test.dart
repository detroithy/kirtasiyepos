import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kirtasiye_app/core/database/app_db.dart';
import 'package:kirtasiye_app/core/utils/money.dart';

void main() {
  late AppDb db;

  setUp(() async {
    db = AppDb.forTest(NativeDatabase.memory());
    await db.ensureSeed();
  });

  tearDown(() => db.close());

  test('seed 3 örnek ürün ekler', () async {
    final products = await db.select(db.products).get();
    expect(products.length, 3);
  });

  test('boş aralık raporu çökmez', () async {
    final s = await db.rangeSummary(
      DateTime(2001, 1, 1),
      DateTime(2001, 1, 31),
    );
    expect(s.total, 0);
    expect(s.receipts, 0);
    expect(s.kdvBreakdown, isEmpty);
  });

  test('satış: stok düşer, fiş + kar doğru yazılır', () async {
    final p =
        (await db.searchProducts('Kurşun Kalem')).single; // alış 8, satış 15, kdv 20
    final qty = 2.0;
    final kdv = kdvTutar(p.sellPrice, p.kdvRate) * qty;
    final kar = satirKar(p.sellPrice, p.buyPrice, p.kdvRate, qty);

    await db.completeSale(
      items: [
        SaleItemsCompanion.insert(
          saleId: 0,
          productId: drift.Value(p.id),
          name: p.name,
          qty: qty,
          unitPrice: p.sellPrice,
          kdvRate: drift.Value(p.kdvRate),
          kdvAmount: drift.Value(kdv),
          buyPriceSnapshot: drift.Value(p.buyPrice),
          profit: drift.Value(kar),
        ),
      ],
      total: p.sellPrice * qty,
      kdvTotal: kdv,
      profitTotal: kar,
      paymentType: 'nakit',
    );

    final after =
        await (db.select(db.products)..where((t) => t.id.equals(p.id)))
            .getSingle();
    expect(after.stock, p.stock - qty);

    final today = await db.daySummary(DateTime.now());
    expect(today.receipts, 1);
    expect(today.total, p.sellPrice * qty);
    expect(today.kdv, kdv);
    expect(today.profit, kar);

    final r = await db.rangeSummary(
      DateTime.now().subtract(const Duration(days: 1)),
      DateTime.now(),
    );
    expect(r.receipts, 1);
    // kdvAmount adetli saklanır -> kırılım tek kat olmalı
    expect(r.kdvBreakdown[p.kdvRate]!.kdv, kdv);
    expect(r.payTotals['nakit'], p.sellPrice * qty);
  });
}
