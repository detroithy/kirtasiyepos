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

  test('normalizeSeeds eski tohum uuidlerini sabitler', () async {
    final db = AppDb.forTest(NativeDatabase.memory());
    // Eski sürümden kalma rastgele uuid'li tohumlar:
    final catId = await db
        .into(db.categories)
        .insert(CategoriesCompanion.insert(
          name: 'Defter',
          uuid: newUuid(),
        ));
    final prodId = await db
        .into(db.products)
        .insert(ProductsCompanion.insert(
          barcode: const drift.Value('868000000001'),
          name: 'Çizgili Defter A4 80 Yaprak',
          categoryId: drift.Value(catId),
          sellPrice: const drift.Value(75),
          uuid: newUuid(),
        ));
    await db.normalizeSeeds();
    final cat = await (db.select(db.categories)
          ..where((t) => t.id.equals(catId)))
        .getSingle();
    final prod = await (db.select(db.products)
          ..where((t) => t.id.equals(prodId)))
        .getSingle();
    expect(cat.uuid, seedUuid('category', 'Defter'));
    expect(prod.uuid,
        seedUuid('product', 'Çizgili Defter A4 80 Yaprak'));
    await db.close();
  });

  test('kategori çekişte ada göre birleşir (yerel UNIQUE patlamaz)',
      () async {
    final db = AppDb.forTest(NativeDatabase.memory());
    await db.into(db.categories).insert(
        CategoriesCompanion.insert(
            name: 'Defter', uuid: newUuid()));
    // Bulut başka uuid ile aynı adı gönderir:
    await db.applyCategory({
      'uuid': newUuid(),
      'name': 'Defter',
      'updated_at': DateTime.now()
          .add(const Duration(minutes: 1))
          .toIso8601String(),
    });
    final all = await db.select(db.categories).get();
    expect(all.where((c) => c.name == 'Defter').length, 1);
    await db.close();
  });

  test('adoptCategoryUuid ürünleri yeni satıra taşır', () async {    final db = AppDb.forTest(NativeDatabase.memory());
    final c1 = await db
        .into(db.categories)
        .insert(CategoriesCompanion.insert(
          name: 'Defter',
          uuid: newUuid(),
        ));
    final c2 = await db
        .into(db.categories)
        .insert(CategoriesCompanion.insert(
          name: 'Eski',
          uuid: newUuid(),
        ));
    await db.insertProduct(ProductsCompanion.insert(
      name: 'X',
      categoryId: drift.Value(c2),
      sellPrice: const drift.Value(10),
      uuid: newUuid(),
    ));
    final u1 = (await (db.select(db.categories)
              ..where((t) => t.id.equals(c1)))
            .getSingle())
        .uuid;
    final u2 = (await (db.select(db.categories)
              ..where((t) => t.id.equals(c2)))
            .getSingle())
        .uuid;
    // c2 satırı u1 kimliğini benimser:
    await db.adoptCategoryUuid(u2, u1);
    final cats = await db.select(db.categories).get();
    expect(cats.length, 1);
    expect(cats.single.uuid, u1);
    final prods = await db.select(db.products).get();
    expect(prods.single.categoryId, c2);
    await db.close();
  });

  test('refreshProductOp bayat referansı canlı satırdan onarır',
      () async {
    final db = AppDb.forTest(NativeDatabase.memory());
    await db.ensureSeed();
    final p =
        (await db.searchProducts('Kurşun Kalem')).single;
    // Bayat payload: olmayan kategori uuid'si (senkron öncesi hali):
    await db.enqueue(
      table: 'products',
      rowUuid: p.uuid,
      payload: {
        ...(await db.productPayload(p)),
        'category_uuid': 'ölü-uuid-1234',
      },
    );
    var ops = await db.pendingOps();
    expect(ops.length, 1);
    expect(await db.refreshProductOp(ops.single), true);
    ops = await db.pendingOps();
    expect(ops.length, 1);
    final fixed =
        jsonDecode(ops.single.payload) as Map<String, dynamic>;
    expect(fixed['category_uuid'],
        (await db.productByUuid(p.uuid)) == null
            ? null
            : await _catOf(db, p.id));
    await db.close();
  });

  test('refreshProductOp öksüz opu düşürür', () async {
    final db = AppDb.forTest(NativeDatabase.memory());
    await db.ensureSeed();
    await db.enqueue(
      table: 'products',
      rowUuid: 'olmayan-uuid',
      payload: {'uuid': 'olmayan-uuid'},
    );
    final ops = await db.pendingOps();
    expect(ops.length, 1);
    expect(await db.refreshProductOp(ops.single), true);
    expect(await db.pendingCount(), 0);
    await db.close();
  });
}

Future<String?> _catOf(AppDb db, int productId) async {
  final p = await (db.select(db.products)
        ..where((t) => t.id.equals(productId)))
      .getSingle();
  if (p.categoryId == null) return null;
  final c = await (db.select(db.categories)
        ..where((t) => t.id.equals(p.categoryId!)))
      .getSingleOrNull();
  return c?.uuid;
}
