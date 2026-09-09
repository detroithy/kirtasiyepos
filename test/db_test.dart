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

  test('hareket iki kez uygulanırsa stok bir kez düşer (idempotent)',
      () async {
    final p = (await db.searchProducts('Kurşun Kalem')).single;
    final m = {
      'uuid': newUuid(),
      'type': 'satis',
      'qty': -2.0,
      'prev_stock': p.stock,
      'new_stock': p.stock - 2,
      'note': 'uzak fiş',
      'date': DateTime.now().toIso8601String(),
    };
    await db.applyMovement(m, p.uuid);
    final s1 = await (db.select(db.products)
          ..where((t) => t.id.equals(p.id)))
        .getSingle();
    expect(s1.stock, p.stock - 2);
    await db.applyMovement(m, p.uuid); // örtüşmeli çekiş tekrarı
    final s2 = await (db.select(db.products)
          ..where((t) => t.id.equals(p.id)))
        .getSingle();
    expect(s2.stock, s1.stock);
    final movs = await db.select(db.stockMovements).get();
    expect(movs.length, 1);
  });

  test('indirim toplam/KDV/karı orantılı küçültür', () async {
    final p = (await db.searchProducts('Kurşun Kalem')).single;
    // 2 adet x 15 = 30 ara toplam, 6 indirim -> 24, faktör 0.8
    const qty = 2.0;
    const f = 0.8;
    final kdv = kdvTutar(p.sellPrice, p.kdvRate) * qty * f;
    final kar = satirKar(p.sellPrice, p.buyPrice, p.kdvRate, qty) * f;
    final r = await db.completeSale(
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
      total: 24,
      kdvTotal: kdv,
      profitTotal: kar,
      discount: 6,
    );
    final row = await (db.select(db.sales)
          ..where((t) => t.id.equals(r.id)))
        .getSingle();
    expect(row.total, 24);
    expect(row.discount, 6);
    expect(row.kdvTotal, kdv);
  });

  test('iade: stok döner, eksi fiş, ikinci iade engellenir', () async {
    final p = (await db.searchProducts('Kurşun Kalem')).single;
    final stock0 = p.stock;
    // 2 adet satış:
    final sale = await db.completeSale(
      items: [
        SaleItemsCompanion.insert(
          saleId: 0,
          productId: drift.Value(p.id),
          name: p.name,
          qty: 2,
          unitPrice: p.sellPrice,
          kdvRate: drift.Value(p.kdvRate),
          kdvAmount: drift.Value(5),
          buyPriceSnapshot: drift.Value(p.buyPrice),
          profit: drift.Value(9),
          uuid: newUuid(),
          saleUuid: const drift.Value(''),
        ),
      ],
      total: 30,
      kdvTotal: 5,
      profitTotal: 9,
      receiptNo: 'K1-0001',
    );
    expect(
        (await (db.select(db.products)
                  ..where((t) => t.id.equals(p.id)))
                .getSingle())
            .stock,
        stock0 - 2);

    // 1 adet iade:
    final items = await db.saleItemsFor(sale.id);
    final l = items.single;
    final retNo = await db.nextReturnReceiptNo('K1-0001');
    expect(retNo, 'İADE-K1-0001');
    await db.completeSale(
      items: [
        SaleItemsCompanion.insert(
          saleId: 0,
          productId: drift.Value(p.id),
          name: l.name,
          qty: -1,
          unitPrice: l.unitPrice,
          kdvRate: drift.Value(l.kdvRate),
          kdvAmount: drift.Value(-2.5),
          buyPriceSnapshot: drift.Value(l.buyPriceSnapshot),
          profit: drift.Value(-4.5),
          uuid: newUuid(),
          saleUuid: const drift.Value(''),
        ),
      ],
      total: -15,
      kdvTotal: -2.5,
      profitTotal: -4.5,
      receiptNo: retNo,
      movementType: 'iade',
      movementNote: 'K1-0001',
    );
    expect(
        (await (db.select(db.products)
                  ..where((t) => t.id.equals(p.id)))
                .getSingle())
            .stock,
        stock0 - 1);

    // İade takibi: 1 adet kullanıldı, 1 kaldı:
    final ret = await db.returnedQtyByProduct('K1-0001');
    expect(ret[p.id], 1);

    // İkinci iade no çakışmaz:
    expect(await db.nextReturnReceiptNo('K1-0001'),
        'İADE-K1-0001-2');

    // Günlük ciro netleşir (30 - 15):
    final day = await db.daySummary(DateTime.now());
    expect(day.total, 15);
    expect(day.receipts, 2);
  });
}
