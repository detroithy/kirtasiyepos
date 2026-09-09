import 'package:drift/drift.dart' as drift show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kirtasiye_app/core/database/app_db.dart';

void main() {
  test('hourlyBuckets saate dağıtır, iadeyi düşer', () async {
    final db = AppDb.forTest(NativeDatabase.memory());
    await db.ensureSeed();
    final p = (await db.searchProducts('Kurşun Kalem')).single;
    Future<void> sell(
        {required double qty,
        required double total,
        required DateTime at,
        String no = ''}) async {
      await db.completeSale(
        items: [
          SaleItemsCompanion.insert(
            saleId: 0,
            productId: drift.Value(p.id),
            name: p.name,
            qty: qty,
            unitPrice: 15,
            kdvRate: drift.Value(20),
            kdvAmount: drift.Value(2.5 * qty),
            buyPriceSnapshot: drift.Value(8),
            profit: drift.Value(4.5 * qty),
            uuid: newUuid(),
            saleUuid: const drift.Value(''),
          ),
        ],
        total: total,
        kdvTotal: 2.5 * qty,
        profitTotal: 4.5 * qty,
        receiptNo: no.isEmpty ? null : no,
      );
      // Tarihi sabitle:
      final s = await db.findSaleByReceipt(
          no.isEmpty ? '' : no);
      if (s != null) {
        await (db.update(db.sales)
              ..where((t) => t.id.equals(s.id)))
            .write(SalesCompanion(date: drift.Value(at)));
      }
    }

    final day = DateTime(2026, 5, 4);
    await sell(
        qty: 2,
        total: 30,
        at: DateTime(2026, 5, 4, 9, 15),
        no: 'K1-H1');
    await sell(
        qty: 1,
        total: 15,
        at: DateTime(2026, 5, 4, 9, 45),
        no: 'K1-H2');
    await sell(
        qty: 1,
        total: 15,
        at: DateTime(2026, 5, 4, 14, 5),
        no: 'K1-H3');
    await sell(
        qty: -1,
        total: -15,
        at: DateTime(2026, 5, 4, 16, 0),
        no: 'K1-H4');
    await sell(
        qty: 1, total: 15, at: DateTime(2026, 5, 5, 10), no: 'K1-H5');

    final buckets = hourlyBuckets(await db.salesOnDay(day), day);
    expect(buckets[9], 45);
    expect(buckets[14], 15);
    expect(buckets[16], -15);
    expect(buckets[10], 0); // ertesi gün düşmez
    expect(buckets.fold(0.0, (a, b) => a + b), 45);
    await db.close();
  });

  test('categoryRevenue kategoriye dağıtır, kdv hariç değil brüt', () async {
    final db = AppDb.forTest(NativeDatabase.memory());
    await db.ensureSeed();
    final kalem = (await db.searchProducts('Kurşun Kalem')).single;
    final defter =
        (await db.searchProducts('Çizgili Defter')).single;
    Future<void> sell(int pid, double qty, double unit) async {
      await db.completeSale(
        items: [
          SaleItemsCompanion.insert(
            saleId: 0,
            productId: drift.Value(pid),
            name: 'x',
            qty: qty,
            unitPrice: unit,
            kdvRate: drift.Value(20),
            kdvAmount: drift.Value(1),
            buyPriceSnapshot: drift.Value(1),
            profit: drift.Value(1),
            uuid: newUuid(),
            saleUuid: const drift.Value(''),
          ),
        ],
        total: qty * unit,
        kdvTotal: 1,
        profitTotal: 1,
      );
    }

    await sell(kalem.id, 2, 15); // Kalem: 30
    await sell(defter.id, 1, 75); // Defter: 75
    final now = DateTime.now();
    final map = await db.categoryRevenue(
      now.subtract(const Duration(days: 1)),
      now,
    );
    expect(map['Kalem'], 30);
    expect(map['Defter'], 75);
    await db.close();
  });

  test('last7Days 7 nokta döner, bugün dahil', () async {
    final db = AppDb.forTest(NativeDatabase.memory());
    await db.ensureSeed();
    final pts = await db.last7Days(now: DateTime(2026, 5, 10, 12));
    expect(pts.length, 7);
    expect(pts.last.day, DateTime(2026, 5, 10));
    expect(pts.first.day, DateTime(2026, 5, 4));
    await db.close();
  });
}
