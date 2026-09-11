import 'package:drift/drift.dart' as drift show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kirtasiye_app/core/database/app_db.dart';

void main() {
  test('sepet: ekle birleştirir, adet güncellenir, silinir', () async {
    final db = AppDb.forTest(NativeDatabase.memory());
    await db.ensureSeed();
    final p = (await db.searchProducts('Kurşun Kalem')).single;

    await db.cartAdd(
      productId: p.id,
      productUuid: p.uuid,
      name: p.name,
      unitPrice: p.sellPrice,
      kdvRate: p.kdvRate,
      buyPrice: p.buyPrice,
    );
    await db.cartAdd(
      productId: p.id,
      productUuid: p.uuid,
      name: p.name,
      unitPrice: p.sellPrice,
      kdvRate: p.kdvRate,
      buyPrice: p.buyPrice,
    );
    var lines = await db.cartRows();
    expect(lines.length, 1);
    expect(lines.single.qty, 2);

    // Hizmet satırı ada göre birleşir:
    await db.cartAdd(name: 'S/B Çıktı (A4)', unitPrice: 2.5);
    await db.cartAdd(name: 'S/B Çıktı (A4)', unitPrice: 2.5);
    lines = await db.cartRows();
    expect(lines.length, 2);
    final svc =
        lines.firstWhere((l) => l.productId == null);
    expect(svc.qty, 2);
    expect(svc.productUuid, '');

    await db.cartSetQty(svc.uuid, 5);
    lines = await db.cartRows();
    expect(
        lines.firstWhere((l) => l.uuid == svc.uuid).qty, 5);

    // Sıfırlanınca satır düşer (soft delete):
    await db.cartSetQty(svc.uuid, 0);
    lines = await db.cartRows();
    expect(lines.length, 1);

    // Kuyrukta izler durur (senkron için):
    expect(await db.pendingCount(), greaterThan(0));
    await db.close();
  });

  test('sepet satışta boşalır, stok snapshot ile düşer', () async {
    final db = AppDb.forTest(NativeDatabase.memory());
    await db.ensureSeed();
    final p = (await db.searchProducts('Kurşun Kalem')).single;
    final stock0 = p.stock;
    await db.cartAdd(
      productId: p.id,
      productUuid: p.uuid,
      name: p.name,
      unitPrice: p.sellPrice,
      kdvRate: p.kdvRate,
      buyPrice: p.buyPrice,
    );
    final lines = await db.cartRows();
    final l = lines.single;
    await db.completeSale(
      items: [
        SaleItemsCompanion.insert(
          saleId: 0,
          productId: drift.Value(l.productId),
          name: l.name,
          qty: l.qty,
          unitPrice: l.unitPrice,
          kdvRate: drift.Value(l.kdvRate),
          kdvAmount: drift.Value(2.5),
          buyPriceSnapshot: drift.Value(l.buyPrice),
          profit: drift.Value(4.5),
          uuid: newUuid(),
          saleUuid: const drift.Value(''),
        ),
      ],
      total: 15,
      kdvTotal: 2.5,
      profitTotal: 4.5,
    );
    await db.cartClear();
    expect(await db.cartRows(), isEmpty);
    final after = await (db.select(db.products)
          ..where((t) => t.id.equals(p.id)))
        .getSingle();
    expect(after.stock, stock0 - 1);
    await db.close();
  });

  test('uzak sepet satırı birleşir, sil bayrağı saygı görür',
      () async {
    final db = AppDb.forTest(NativeDatabase.memory());
    await db.ensureSeed();
    final now = DateTime.now().toIso8601String();
    Map<String, dynamic> row(String uuid, double qty,
        {bool del = false, String? ts}) {
      return {
        'uuid': uuid,
        'product_id': null,
        'product_uuid': '',
        'barcode': null,
        'name': 'Fotokopi',
        'qty': qty,
        'unit_price': 5.0,
        'kdv_rate': 20.0,
        'buy_price': 0.0,
        'device_code': 'K2',
        'updated_at': ts ?? now,
        'is_deleted': del,
      };
    }

    await db.applyCartLine(row('u1', 3));
    expect((await db.cartRows()).single.qty, 3);
    // Eski damgalı güncelleme ezemez (LWW):
    await db.applyCartLine(row('u1', 9,
        ts: DateTime.now()
            .subtract(const Duration(hours: 1))
            .toIso8601String()));
    expect((await db.cartRows()).single.qty, 3);
    // Yeni damgalı güncelleme ezer:
    await db.applyCartLine(row('u1', 7,
        ts: DateTime.now()
            .add(const Duration(minutes: 1))
            .toIso8601String()));
    expect((await db.cartRows()).single.qty, 7);
    // Sil bayrağı satırı listeden düşürür:
    await db.applyCartLine(row('u1', 7,
        del: true,
        ts: DateTime.now()
            .add(const Duration(minutes: 2))
            .toIso8601String()));
    expect(await db.cartRows(), isEmpty);
    await db.close();
  });
}
