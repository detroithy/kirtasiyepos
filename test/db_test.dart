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
          uuid: newUuid(),
          saleUuid: const drift.Value(''),
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

  test('satış kuyruğa yazar (senkron outbox)', () async {
    final p = (await db.searchProducts('Kurşun Kalem')).single;
    await db.completeSale(
      items: [
        SaleItemsCompanion.insert(
          saleId: 0,
          productId: drift.Value(p.id),
          name: p.name,
          qty: 1,
          unitPrice: p.sellPrice,
          kdvRate: drift.Value(p.kdvRate),
          kdvAmount: drift.Value(kdvTutar(p.sellPrice, p.kdvRate)),
          buyPriceSnapshot: drift.Value(p.buyPrice),
          profit: drift.Value(1),
          uuid: newUuid(),
          saleUuid: const drift.Value(''),
        ),
      ],
      total: p.sellPrice,
      kdvTotal: 1,
      profitTotal: 1,
    );
    // 1 satış + 1 satır + 1 hareket + 1 ürün güncellemesi
    expect(await db.pendingCount(), 4);
    final ops = await db.pendingOps();
    expect(ops.map((o) => o.entity).toSet(),
        {'sales', 'sale_items', 'stock_movements', 'products'});
  });

  test('parçalı + cari + tahsilat akışı', () async {
    final p = (await db.searchProducts('Kurşun Kalem')).single;

    Future<int> sell({
      required String type,
      required double total,
      double cash = 0,
      double card = 0,
      String customer = '',
    }) async {
      final r = await db.completeSale(
        items: [
          SaleItemsCompanion.insert(
            saleId: 0,
            productId: drift.Value(p.id),
            name: p.name,
            qty: 2,
            unitPrice: 15,
            kdvRate: drift.Value(20),
            kdvAmount: drift.Value(5),
            buyPriceSnapshot: drift.Value(8),
            profit: drift.Value(9),
            uuid: newUuid(),
            saleUuid: const drift.Value(''),
          ),
        ],
        total: total,
        kdvTotal: 5,
        profitTotal: 9,
        paymentType: type,
        cashAmount: cash,
        cardAmount: card,
        customer: customer,
      );
      return r.id;
    }

    // Parçalı: 10 nakit + 20 kart
    await sell(type: 'parcali', total: 30, cash: 10, card: 20);
    // Cari: Ahmet'e 30 veresiye
    final cariId =
        await sell(type: 'cari', total: 30, customer: 'Ahmet');

    final r = await db.rangeSummary(
      DateTime.now().subtract(const Duration(days: 1)),
      DateTime.now(),
    );
    expect(r.payTotals['nakit'], 10);
    expect(r.payTotals['kart'], 20);
    expect(r.payTotals['cari'], 30);
    expect(r.payCounts['parcali'], 1);
    expect(r.payCounts['cari'], 1);

    // Borç defteri + kısmi tahsilat:
    expect(await db.openDebtsTotal(), 30);
    await db.collectDebt(saleId: cariId, amount: 12);
    expect(await db.openDebtsTotal(), 18);
    final debts = await db.openDebts();
    expect(debts.single.paid, 12);

    // Uzak tahsilat LWW ile gelir:
    final local =
        await (db.select(db.sales)..where((t) => t.id.equals(cariId)))
            .getSingle();
    await db.applySaleDoc(
      {
        ...db.salePayload(local),
        'paid': 30.0,
        'updated_at':
            DateTime.now().add(const Duration(minutes: 5)).toIso8601String(),
      },
      [],
    );
    final after =
        await (db.select(db.sales)..where((t) => t.id.equals(cariId)))
            .getSingle();
    expect(after.paid, 30);
    expect(await db.openDebtsTotal(), 0);
  });

  test('yumuşak silme listeden düşürür', () async {
    final p = (await db.searchProducts('Kurşun Kalem')).single;
    await db.softDeleteProduct(p.id);
    expect(await db.searchProducts('Kurşun Kalem'), isEmpty);
    expect(await db.findByBarcode(p.barcode ?? 'yok'), isNull);
    final all = await db.select(db.products).get();
    expect(all.length, 3); // satır durur, bayrak değişir
    expect(await db.pendingCount(), greaterThan(0));
  });
}
