import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kirtasiye_app/core/database/app_db.dart';
import 'package:sqlite3/sqlite3.dart';

/// v1 şemasını ham SQL ile kurup v2 migrasyonunu tetikler.
/// Gerçek kullanıcı verisi (v1) kaybolmamalı, uuid'ler dolmalı.
void _createV1(File file) {
  final raw = sqlite3.open(file.path);
  void s(String sql) => raw.execute(sql);
  s('CREATE TABLE categories (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL UNIQUE)');
  s('CREATE TABLE suppliers (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, phone TEXT NULL)');
  s('CREATE TABLE products (id INTEGER PRIMARY KEY AUTOINCREMENT, barcode TEXT UNIQUE NULL, name TEXT NOT NULL, category_id INTEGER NULL, unit TEXT NOT NULL DEFAULT \'adet\', buy_price REAL NOT NULL DEFAULT 0.0, sell_price REAL NOT NULL DEFAULT 0.0, kdv_rate REAL NOT NULL DEFAULT 0.0, stock REAL NOT NULL DEFAULT 0.0, critical_level REAL NOT NULL DEFAULT 0.0, supplier_id INTEGER NULL, created_at INTEGER NOT NULL DEFAULT 0, updated_at INTEGER NOT NULL DEFAULT 0, sync_status INTEGER NOT NULL DEFAULT 0)');
  s('CREATE TABLE stock_movements (id INTEGER PRIMARY KEY AUTOINCREMENT, product_id INTEGER NOT NULL, type TEXT NOT NULL, qty REAL NOT NULL, prev_stock REAL NOT NULL, new_stock REAL NOT NULL, note TEXT NULL, date INTEGER NOT NULL DEFAULT 0)');
  s('CREATE TABLE sales (id INTEGER PRIMARY KEY AUTOINCREMENT, receipt_no TEXT NOT NULL UNIQUE, date INTEGER NOT NULL DEFAULT 0, total REAL NOT NULL DEFAULT 0.0, kdv_total REAL NOT NULL DEFAULT 0.0, profit_total REAL NOT NULL DEFAULT 0.0, discount REAL NOT NULL DEFAULT 0.0, payment_type TEXT NOT NULL DEFAULT \'nakit\', item_count INTEGER NOT NULL DEFAULT 0)');
  s('CREATE TABLE sale_items (id INTEGER PRIMARY KEY AUTOINCREMENT, sale_id INTEGER NOT NULL, product_id INTEGER NULL, barcode TEXT NULL, name TEXT NOT NULL, qty REAL NOT NULL, unit_price REAL NOT NULL, kdv_rate REAL NOT NULL DEFAULT 0.0, kdv_amount REAL NOT NULL DEFAULT 0.0, buy_price_snapshot REAL NOT NULL DEFAULT 0.0, profit REAL NOT NULL DEFAULT 0.0)');
  s('CREATE TABLE expenses (id INTEGER PRIMARY KEY AUTOINCREMENT, date INTEGER NOT NULL DEFAULT 0, category TEXT NOT NULL, amount REAL NOT NULL, note TEXT NULL)');
  s("INSERT INTO categories (name) VALUES ('Defter')");
  s("INSERT INTO products (name, sell_price, stock) VALUES ('Test Kalem', 15.0, 100.0)");
  s("INSERT INTO sales (receipt_no, total) VALUES ('FS-eski-1', 30.0)");
  s("INSERT INTO sale_items (sale_id, name, qty, unit_price) VALUES (1, 'Test Kalem', 2.0, 15.0)");
  s('PRAGMA user_version = 1');
  raw.close();
}
void main() {
  test('v1 -> v2 migrasyonu veriyi korur, uuid doldurur', () async {
    final file =
        File('${Directory.systemTemp.path}/kirtasiye_migtest.db');
    if (file.existsSync()) file.deleteSync();
    _createV1(file);

    final db = AppDb.forTest(NativeDatabase(file));
    // Migrasyon açılışta koşar:
    final products = await db.select(db.products).get();
    expect(products.length, 1);
    expect(products.single.name, 'Test Kalem');
    expect(products.single.stock, 100.0);
    expect(products.single.uuid.isNotEmpty, true);
    expect(products.single.originDevice, 'K1');

    final items = await db.select(db.saleItems).get();
    expect(items.length, 1);
    expect(items.single.uuid.isNotEmpty, true);
    expect(items.single.saleUuid.isNotEmpty, true);

    final sales = await db.select(db.sales).get();
    expect(sales.single.uuid, items.single.saleUuid);
    // v3: eski nakit fiş ödenmiş sayılır:
    expect(sales.single.paid, 30.0);
    expect(sales.single.cashAmount, 30.0);
    expect(sales.single.customer, '');

    // Yeni tablolar hazır:
    expect(await db.pendingCount(), 0);
    expect(await db.lastPulled('sales'), isNull);

    // Migrasyon sonrası yazma akışı çalışır:
    await db.adjustStock(        productId: products.single.id,
        qtyChange: 5,
        type: 'giris',
        note: 'test');
    expect(await db.pendingCount(), 2); // hareket + ürün
    // v4 defter tablosu da hazır:
    final sup = await db.insertSupplier(name: 'Test Toptan');
    await db.insertLedgerEntry(
        supplierId: sup.id, kind: 'alim', amount: 500);
    expect(await db.supplierBalance(sup.id), 500);
    // v5 POS cihaz kolonları boş gelir:
    expect(sales.single.approvalCode, '');
    expect(sales.single.fiscalNo, '');
    expect(sales.single.posStatus, '');
    await db.close();
    if (file.existsSync()) file.deleteSync();
  });
}
