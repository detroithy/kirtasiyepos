import 'dart:convert';

import 'package:drift/drift.dart' as drift show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kirtasiye_app/core/database/app_db.dart';

void main() {
  test('tohum uuid her cihazda aynı olur', () async {
    final a = AppDb.forTest(NativeDatabase.memory());
    final b = AppDb.forTest(NativeDatabase.memory());
    await a.ensureSeed();
    await b.ensureSeed();
    final ua = (await a.select(a.products).get()).map((p) => p.uuid).toList()
      ..sort();
    final ub = (await b.select(b.products).get()).map((p) => p.uuid).toList()
      ..sort();
    expect(ua, ub);
    await a.close();
    await b.close();
  });

  test('aynı barkodlu uzak ürün birleşir, çift kayıt olmaz', () async {
    final db = AppDb.forTest(NativeDatabase.memory());
    await db.ensureSeed();
    // Yerel kayıt (başka uuid ile aynı barkod):
    final local = await db.insertProduct(ProductsCompanion.insert(
      barcode: const drift.Value('999001'),
      name: 'Test Ürünü',
      sellPrice: const drift.Value(50),
      uuid: newUuid(),
    ));
    await db.dropOps((await db.pendingOps()).map((o) => o.id).toList());

    final remoteUuid = newUuid();
    await db.applyProduct({
      'uuid': remoteUuid,
      'barcode': '999001',
      'name': 'Test Ürünü',
      'category_uuid': null,
      'unit': 'adet',
      'buy_price': 30.0,
      'sell_price': 55.0,
      'kdv_rate': 20.0,
      'stock': 9.0,
      'critical_level': 2.0,
      'supplier_uuid': null,
      'created_at': DateTime.now().toIso8601String(),
      'updated_at':
          DateTime.now().add(const Duration(minutes: 1)).toIso8601String(),
      'origin_device': 'K2',
      'is_deleted': false,
    });

    final all = await db.select(db.products).get();
    final twins =
        all.where((p) => p.barcode == '999001').toList();
    expect(twins.length, 1);
    expect(twins.single.uuid, remoteUuid);
    expect(twins.single.sellPrice, 55.0);

    // Eski uuid için sil bayraklı mezar taşı kuyrukta:
    final ops = await db.pendingOps();
    final tombs = ops.where((o) => o.rowUuid == local.uuid).toList();
    expect(tombs.length, 1);
    final payload =
        jsonDecode(tombs.single.payload) as Map<String, dynamic>;
    expect(payload['is_deleted'], true);
    await db.close();
  });

  test('requeueAll tüm satırları kuyruğa kurar', () async {
    final db = AppDb.forTest(NativeDatabase.memory());
    await db.ensureSeed();
    expect(await db.pendingCount(), 0);
    final n = await db.requeueAll();
    // 3 kategori + 3 ürün:
    expect(n, 6);
    expect(await db.pendingCount(), 6);
    await db.close();
  });
}
