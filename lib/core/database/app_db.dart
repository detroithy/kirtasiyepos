import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

part 'app_db.g.dart';

final _uuidGen = Uuid();
String newUuid() => _uuidGen.v4();

/// Kategoriler (Defter, Kalem, Kağıt...)
class Categories extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text().unique()();
  // --- Faz-3 senkron ---
  TextColumn get uuid => text().unique()();
  DateTimeColumn get updatedAt =>
      dateTime().withDefault(currentDateAndTime)();
}

/// Tedarikçiler (toptancılar)
class Suppliers extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
  TextColumn get phone => text().nullable()();
  // --- Faz-3 senkron ---
  TextColumn get uuid => text().unique()();
  DateTimeColumn get updatedAt =>
      dateTime().withDefault(currentDateAndTime)();
}

/// Ürünler. Satış fiyatı KDV DAHİL etikettir (TR perakende adeti).
/// Stok, hareket deltalarından türetilir; iki cihaz arası mutlak
/// stok değeri taşınmaz (delta-commute kuralı).
class Products extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get barcode => text().nullable().unique()();
  TextColumn get name => text()();
  IntColumn get categoryId =>
      integer().nullable().references(Categories, #id)();
  TextColumn get unit => text().withDefault(const Constant('adet'))();
  RealColumn get buyPrice => real().withDefault(const Constant(0))();
  RealColumn get sellPrice => real().withDefault(const Constant(0))();
  RealColumn get kdvRate => real().withDefault(const Constant(20))();
  RealColumn get stock => real().withDefault(const Constant(0))();
  RealColumn get criticalLevel => real().withDefault(const Constant(5))();
  IntColumn get supplierId =>
      integer().nullable().references(Suppliers, #id)();
  DateTimeColumn get createdAt =>
      dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt =>
      dateTime().withDefault(currentDateAndTime)();
  IntColumn get syncStatus => integer().withDefault(const Constant(0))();
  // --- Faz-3 senkron ---
  TextColumn get uuid => text().unique()();
  TextColumn get originDevice =>
      text().withDefault(const Constant('K1'))();
  BoolColumn get isDeleted =>
      boolean().withDefault(const Constant(false))();
}

/// Stok hareketleri: DEĞİŞMEZ kayıtlar (append-only).
/// Uzak hareketler delta olarak uygulanır (uuid ile bir-ke$-uygulama).
class StockMovements extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get productId => integer().references(Products, #id)();
  TextColumn get type => text()(); // giris, cikis, sayim, satis, iade
  RealColumn get qty => real()();
  RealColumn get prevStock => real()();
  RealColumn get newStock => real()();
  TextColumn get note => text().nullable()();
  DateTimeColumn get date => dateTime().withDefault(currentDateAndTime)();
  // --- Faz-3 senkron ---
  TextColumn get uuid => text().unique()();
}

/// Satış fişleri: DEĞİŞMEZ. Kar alış-snapshot ile hesaplanır.
class Sales extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get receiptNo => text().unique()();
  DateTimeColumn get date => dateTime().withDefault(currentDateAndTime)();
  RealColumn get total => real().withDefault(const Constant(0))();
  RealColumn get kdvTotal => real().withDefault(const Constant(0))();
  RealColumn get profitTotal => real().withDefault(const Constant(0))();
  RealColumn get discount => real().withDefault(const Constant(0))();
  TextColumn get paymentType => text().withDefault(const Constant('nakit'))();
  IntColumn get itemCount => integer().withDefault(const Constant(0))();
  // --- Faz-3 senkron ---
  TextColumn get uuid => text().unique()();
  TextColumn get originDevice =>
      text().withDefault(const Constant('K1'))();
}

/// Satış satırları: DEĞİŞMEZ (alış snapshot'lı).
class SaleItems extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get saleId => integer().references(Sales, #id)();
  IntColumn get productId => integer().nullable().references(Products, #id)();
  TextColumn get barcode => text().nullable()();
  TextColumn get name => text()();
  RealColumn get qty => real()();
  RealColumn get unitPrice => real()();
  RealColumn get kdvRate => real().withDefault(const Constant(20))();
  RealColumn get kdvAmount => real().withDefault(const Constant(0))();
  RealColumn get buyPriceSnapshot => real().withDefault(const Constant(0))();
  RealColumn get profit => real().withDefault(const Constant(0))();
  // --- Faz-3 senkron ---
  TextColumn get uuid => text().unique()();
  TextColumn get saleUuid => text().withDefault(const Constant(''))();
}

/// Giderler: DEĞİŞMEZ (eklenir, düzenlenmez).
class Expenses extends Table {
  IntColumn get id => integer().autoIncrement()();
  DateTimeColumn get date => dateTime().withDefault(currentDateAndTime)();
  TextColumn get category => text()();
  RealColumn get amount => real()();
  TextColumn get note => text().nullable()();
  // --- Faz-3 senkron ---
  TextColumn get uuid => text().unique()();
  DateTimeColumn get updatedAt =>
      dateTime().withDefault(currentDateAndTime)();
}

/// Giden kutusu (outbox): internet yokken biriken buluta gidecek satırlar.
/// Başarıyla push'lanan satır silinir.
@DataClassName('QueuedOp')
class SyncQueue extends Table {
  IntColumn get id => integer().autoIncrement()();
  DateTimeColumn get createdAt =>
      dateTime().withDefault(currentDateAndTime)();
  TextColumn get entity => text()();
  TextColumn get rowUuid => text()();
  TextColumn get payload => text()(); // JSON
  IntColumn get attempts => integer().withDefault(const Constant(0))();
}

/// Çekme imleçleri: her zamanlı tabloda son çekilen kayıt zamanı (ISO).
@DataClassName('PullCursor')
class SyncState extends Table {
  TextColumn get entity => text()();
  TextColumn get lastPulledAt => text().nullable()();

  @override
  Set<Column> get primaryKey => {entity};
}

@DriftDatabase(
  tables: [
    Categories,
    Suppliers,
    Products,
    StockMovements,
    Sales,
    SaleItems,
    Expenses,
    SyncQueue,
    SyncState,
  ],
)
class AppDb extends _$AppDb {
  AppDb() : super(_open());

  /// Testler için bellek DB'si: AppDb.forTest(NativeDatabase.memory())
  AppDb.forTest(super.e);

  /// Bu cihazın kodu (K1/K2...). Açılışta ayarlardan yüklenir.
  String deviceCode = 'K1';

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async => m.createAll(),
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            // SQLite ADD COLUMN kısıtları (UNIQUE yasak, non-constant
            // default yasak) yüzünden tüm yeni kolonlar ham SQL ile:
            // - uuid: NULL eklenir, doldurulur, sonra UNIQUE index
            // - tarihler: sabit 0 default, sonra now() doldurulur
            // - metin/bayrak: sabit default'lu
            Future<void> add(String sql) => customStatement(sql);
            await add(
                'ALTER TABLE categories ADD COLUMN updated_at INTEGER NOT NULL DEFAULT 0');
            await add('ALTER TABLE categories ADD COLUMN uuid TEXT');
            await add(
                'ALTER TABLE suppliers ADD COLUMN updated_at INTEGER NOT NULL DEFAULT 0');
            await add('ALTER TABLE suppliers ADD COLUMN uuid TEXT');
            await add(
                'ALTER TABLE products ADD COLUMN origin_device TEXT NOT NULL DEFAULT \'K1\'');
            await add(
                'ALTER TABLE products ADD COLUMN is_deleted INTEGER NOT NULL DEFAULT 0');
            await add('ALTER TABLE products ADD COLUMN uuid TEXT');
            await add(
                'ALTER TABLE sales ADD COLUMN origin_device TEXT NOT NULL DEFAULT \'K1\'');
            await add('ALTER TABLE sales ADD COLUMN uuid TEXT');
            await add(
                'ALTER TABLE sale_items ADD COLUMN sale_uuid TEXT NOT NULL DEFAULT \'\'');
            await add('ALTER TABLE sale_items ADD COLUMN uuid TEXT');
            await add('ALTER TABLE stock_movements ADD COLUMN uuid TEXT');
            await add(
                'ALTER TABLE expenses ADD COLUMN updated_at INTEGER NOT NULL DEFAULT 0');
            await add('ALTER TABLE expenses ADD COLUMN uuid TEXT');
            await m.createTable(syncQueue);
            await m.createTable(syncState);
            await _backfillV2();
            const uuidTables = [
              'categories',
              'suppliers',
              'products',
              'stock_movements',
              'sales',
              'sale_items',
              'expenses',
            ];
            for (final t in uuidTables) {
              await customStatement(
                  'CREATE UNIQUE INDEX ${t}_uuid ON $t(uuid)');
            }
          }
        },
      );

  /// v1 satırlarına uuid üret + satırların sale_uuid'sini doldur.
  Future<void> _backfillV2() async {
    const tables = [
      'categories',
      'suppliers',
      'products',
      'stock_movements',
      'sales',
      'sale_items',
      'expenses',
    ];
    for (final t in tables) {
      final ids = await customSelect(
        'SELECT id FROM $t WHERE uuid IS NULL',
        readsFrom: {},
      ).map((r) => r.read<int>('id')).get();
      for (final id in ids) {
        await customStatement(
            "UPDATE $t SET uuid = '${newUuid()}' WHERE id = $id");
      }
    }
    await customStatement(
        'UPDATE sale_items SET sale_uuid = (SELECT uuid FROM sales WHERE sales.id = sale_items.sale_id)');
    // Eski satırların tarihleri: drift saniye saklar (strftime %s).
    for (final t in ['categories', 'suppliers', 'expenses']) {
      await customStatement(
          "UPDATE $t SET updated_at = strftime('%s','now') WHERE updated_at = 0");
    }
  }

  // ================= SYNC: kuyruk =================

  /// Satırı giden kutusuna ekle. Transaction içinde çağrılırsa
  /// aynı transaction'a katılır (drift zone kuralı).
  Future<void> enqueue({
    required String table,
    required String rowUuid,
    required Map<String, dynamic> payload,
  }) {
    return into(syncQueue).insert(SyncQueueCompanion.insert(
      entity: table,
      rowUuid: rowUuid,
      payload: jsonEncode(payload),
    ));
  }

  Future<List<QueuedOp>> pendingOps({int limit = 200}) {
    return (select(syncQueue)
          ..orderBy([(t) => OrderingTerm.asc(t.id)])
          ..limit(limit))
        .get();
  }

  Future<int> pendingCount() async {
    final c = await (selectOnly(syncQueue)
          ..addColumns([syncQueue.id.count()]))
        .map((r) => r.read(syncQueue.id.count()) ?? 0)
        .getSingle();
    return c;
  }

  Future<void> dropOps(List<int> ids) {
    return (delete(syncQueue)..where((t) => t.id.isIn(ids))).go();
  }

  Future<void> bumpAttempts(int id) async {
    final row = await (select(syncQueue)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    if (row == null) return;
    await (update(syncQueue)..where((t) => t.id.equals(id)))
        .write(SyncQueueCompanion(attempts: Value(row.attempts + 1)));
  }

  Future<DateTime?> lastPulled(String table) async {
    final row = await (select(syncState)
          ..where((t) => t.entity.equals(table)))
        .getSingleOrNull();
    final v = row?.lastPulledAt;
    return v == null ? null : DateTime.tryParse(v);
  }

  Future<void> savePulled(String table, DateTime at) {
    return into(syncState).insertOnConflictUpdate(
      SyncStateCompanion.insert(
        entity: table,
        lastPulledAt: Value(at.toIso8601String()),
      ),
    );
  }

  // ================= SYNC: payload üreticiler =================

  Future<Map<String, dynamic>> productPayload(Product p) async {
    String? catUuid;
    if (p.categoryId != null) {
      final c = await (select(categories)
            ..where((t) => t.id.equals(p.categoryId!)))
          .getSingleOrNull();
      catUuid = c?.uuid;
    }
    String? supUuid;
    if (p.supplierId != null) {
      final s = await (select(suppliers)
            ..where((t) => t.id.equals(p.supplierId!)))
          .getSingleOrNull();
      supUuid = s?.uuid;
    }
    return {
      'uuid': p.uuid,
      'barcode': p.barcode,
      'name': p.name,
      'category_uuid': catUuid,
      'unit': p.unit,
      'buy_price': p.buyPrice,
      'sell_price': p.sellPrice,
      'kdv_rate': p.kdvRate,
      'stock': p.stock,
      'critical_level': p.criticalLevel,
      'supplier_uuid': supUuid,
      'created_at': p.createdAt.toIso8601String(),
      'updated_at': p.updatedAt.toIso8601String(),
      'origin_device': p.originDevice,
      'is_deleted': p.isDeleted,
    };
  }

  Map<String, dynamic> salePayload(Sale s) => {
        'uuid': s.uuid,
        'receipt_no': s.receiptNo,
        'date': s.date.toIso8601String(),
        'total': s.total,
        'kdv_total': s.kdvTotal,
        'profit_total': s.profitTotal,
        'discount': s.discount,
        'payment_type': s.paymentType,
        'item_count': s.itemCount,
        'origin_device': s.originDevice,
      };

  Map<String, dynamic> itemPayload(SaleItem i) => {
        'uuid': i.uuid,
        'sale_uuid': i.saleUuid,
        'product_uuid': null, // doldurulur (ürün silinmiş olabilir)
        'barcode': i.barcode,
        'name': i.name,
        'qty': i.qty,
        'unit_price': i.unitPrice,
        'kdv_rate': i.kdvRate,
        'kdv_amount': i.kdvAmount,
        'buy_price_snapshot': i.buyPriceSnapshot,
        'profit': i.profit,
      };

  Map<String, dynamic> movementPayload(StockMovement m) => {
        'uuid': m.uuid,
        'type': m.type,
        'qty': m.qty,
        'prev_stock': m.prevStock,
        'new_stock': m.newStock,
        'note': m.note,
        'date': m.date.toIso8601String(),
      };

  Map<String, dynamic> expensePayload(Expense e) => {
        'uuid': e.uuid,
        'date': e.date.toIso8601String(),
        'category': e.category,
        'amount': e.amount,
        'note': e.note,
        'updated_at': e.updatedAt.toIso8601String(),
      };

  Map<String, dynamic> categoryPayload(Category c) => {
        'uuid': c.uuid,
        'name': c.name,
        'updated_at': c.updatedAt.toIso8601String(),
      };

  // ================= SYNC: uzak uygula (pull) =================

  Future<int?> _categoryIdForUuid(String? uuid) async {
    if (uuid == null) return null;
    final c = await (select(categories)
          ..where((t) => t.uuid.equals(uuid)))
        .getSingleOrNull();
    return c?.id;
  }

  Future<int?> _supplierIdForUuid(String? uuid) async {    if (uuid == null) return null;
    final s = await (select(suppliers)
          ..where((t) => t.uuid.equals(uuid)))
        .getSingleOrNull();
    return s?.id;
  }

  Future<int?> _productIdForUuid(String? uuid) async {
    if (uuid == null) return null;
    final p = await (select(products)
          ..where((t) => t.uuid.equals(uuid)))
        .getSingleOrNull();
    return p?.id;
  }

  Future<void> applyCategory(Map<String, dynamic> m) async {
    final uuid = m['uuid'] as String;
    final remoteUpdated =
        DateTime.tryParse(m['updated_at'] as String? ?? '');
    final local = await (select(categories)
          ..where((t) => t.uuid.equals(uuid)))
        .getSingleOrNull();
    if (local == null) {
      await into(categories).insert(CategoriesCompanion.insert(
        name: m['name'] as String,
        uuid: uuid,
        updatedAt: Value(remoteUpdated ?? DateTime.now()),
      ));
    } else if (remoteUpdated != null &&
        remoteUpdated.isAfter(local.updatedAt)) {
      await (update(categories)..where((t) => t.id.equals(local.id)))
          .write(CategoriesCompanion(
        name: Value(m['name'] as String),
        updatedAt: Value(remoteUpdated),
      ));
    }
  }

  /// Tedarikçi LWW upsert (kategori ile aynı kural).
  Future<void> applySupplierLike(
      String uuid, Map<String, dynamic> m) async {
    final remoteUpdated =
        DateTime.tryParse(m['updated_at'] as String? ?? '');
    final local = await (select(suppliers)
          ..where((t) => t.uuid.equals(uuid)))
        .getSingleOrNull();
    if (local == null) {
      await into(suppliers).insert(SuppliersCompanion.insert(
        name: m['name'] as String,
        phone: Value(m['phone'] as String?),
        uuid: uuid,
        updatedAt: Value(remoteUpdated ?? DateTime.now()),
      ));
    } else if (remoteUpdated != null &&
        remoteUpdated.isAfter(local.updatedAt)) {
      await (update(suppliers)..where((t) => t.id.equals(local.id)))
          .write(SuppliersCompanion(
        name: Value(m['name'] as String),
        phone: Value(m['phone'] as String?),
        updatedAt: Value(remoteUpdated),
      ));
    }
  }

  /// Uzak ürünü uygula. Stok kuralı: ürün YENİYSE snapshot alınır,
  /// mevcutsa stok HARİÇ tüm alanlar güncellenir (stok deltalarla yürür).
  Future<void> applyProduct(Map<String, dynamic> m) async {
    final uuid = m['uuid'] as String;
    final remoteUpdated =
        DateTime.tryParse(m['updated_at'] as String? ?? '');
    final local = await (select(products)
          ..where((t) => t.uuid.equals(uuid)))
        .getSingleOrNull();
    final catId = await _categoryIdForUuid(m['category_uuid'] as String?);
    final supId = await _supplierIdForUuid(m['supplier_uuid'] as String?);
    double d(dynamic v) => (v as num?)?.toDouble() ?? 0;
    if (local == null) {
      await into(products).insert(ProductsCompanion.insert(
        barcode: Value(m['barcode'] as String?),
        name: m['name'] as String,
        categoryId: Value(catId),
        unit: Value(m['unit'] as String? ?? 'adet'),
        buyPrice: Value(d(m['buy_price'])),
        sellPrice: Value(d(m['sell_price'])),
        kdvRate: Value(d(m['kdv_rate'])),
        stock: Value(d(m['stock'])),
        criticalLevel: Value(d(m['critical_level'])),
        supplierId: Value(supId),
        createdAt: Value(
            DateTime.tryParse(m['created_at'] as String? ?? '') ??
                DateTime.now()),
        updatedAt: Value(remoteUpdated ?? DateTime.now()),
        uuid: uuid,
        originDevice: Value(m['origin_device'] as String? ?? '?'),
        isDeleted: Value(m['is_deleted'] as bool? ?? false),
      ));
      return;
    }
    if (remoteUpdated != null && remoteUpdated.isAfter(local.updatedAt)) {
      await (update(products)..where((t) => t.id.equals(local.id)))
          .write(ProductsCompanion(
        barcode: Value(m['barcode'] as String?),
        name: Value(m['name'] as String),
        categoryId: Value(catId),
        unit: Value(m['unit'] as String? ?? 'adet'),
        buyPrice: Value(d(m['buy_price'])),
        sellPrice: Value(d(m['sell_price'])),
        kdvRate: Value(d(m['kdv_rate'])),
        // stock: BİLEREK YOK — delta kuralı
        criticalLevel: Value(d(m['critical_level'])),
        supplierId: Value(supId),
        updatedAt: Value(remoteUpdated),
        isDeleted: Value(m['is_deleted'] as bool? ?? false),
        syncStatus: const Value(0),
      ));
    }
  }

  /// Uzak satışı (satırlarıyla) uygula. Varsa atla (değişmez kayıt).
  Future<void> applySaleDoc(
      Map<String, dynamic> s, List<Map<String, dynamic>> items) async {
    final uuid = s['uuid'] as String;
    final exists = await (select(sales)
          ..where((t) => t.uuid.equals(uuid)))
        .getSingleOrNull();
    if (exists != null) return;
    double d(dynamic v) => (v as num?)?.toDouble() ?? 0;
    final saleId = await into(sales).insert(SalesCompanion.insert(
      receiptNo: s['receipt_no'] as String,
      date: Value(
          DateTime.tryParse(s['date'] as String? ?? '') ?? DateTime.now()),
      total: Value(d(s['total'])),
      kdvTotal: Value(d(s['kdv_total'])),
      profitTotal: Value(d(s['profit_total'])),
      discount: Value(d(s['discount'])),
      paymentType: Value(s['payment_type'] as String? ?? 'nakit'),
      itemCount: Value((s['item_count'] as num?)?.toInt() ?? items.length),
      uuid: uuid,
      originDevice: Value(s['origin_device'] as String? ?? '?'),
    ));
    for (final m in items) {
      final itemUuid = m['uuid'] as String;
      final dup = await (select(saleItems)
            ..where((t) => t.uuid.equals(itemUuid)))
          .getSingleOrNull();
      if (dup != null) continue;
      await into(saleItems).insert(SaleItemsCompanion.insert(
        saleId: saleId,
        productId:
            Value(await _productIdForUuid(m['product_uuid'] as String?)),
        barcode: Value(m['barcode'] as String?),
        name: m['name'] as String,
        qty: d(m['qty']),
        unitPrice: d(m['unit_price']),
        kdvRate: Value(d(m['kdv_rate'])),
        kdvAmount: Value(d(m['kdv_amount'])),
        buyPriceSnapshot: Value(d(m['buy_price_snapshot'])),
        profit: Value(d(m['profit'])),
        uuid: itemUuid,
        saleUuid: Value(uuid),
      ));
    }
  }

  /// Uzak hareketi uygula. Ürün bu çekişten ÖNCE mevcutsa delta
  /// stoğa yansıtılır; yeni gelen ürünle birlikteyse snapshot
  /// zaten içerdiği için delta atlanır.
  Future<void> applyMovement(
      Map<String, dynamic> m, String productUuid) async {
    final uuid = m['uuid'] as String;
    final dup = await (select(stockMovements)
          ..where((t) => t.uuid.equals(uuid)))
        .getSingleOrNull();
    if (dup != null) return;
    final prod = await (select(products)
          ..where((t) => t.uuid.equals(productUuid)))
        .getSingleOrNull();
    if (prod == null) return; // ürün henüz gelmemiş, sonraki turda
    double d(dynamic v) => (v as num?)?.toDouble() ?? 0;
    final qty = d(m['qty']);
    final wasNew = _isProductNewInThisPull(prod.id);
    await into(stockMovements).insert(StockMovementsCompanion.insert(
      productId: prod.id,
      type: m['type'] as String,
      qty: qty,
      prevStock: prod.stock,
      newStock: wasNew ? prod.stock : prod.stock + qty,
      note: Value(m['note'] as String?),
      date: Value(
          DateTime.tryParse(m['date'] as String? ?? '') ?? DateTime.now()),
      uuid: uuid,
    ));
    if (!wasNew && qty != 0) {
      await (update(products)..where((t) => t.id.equals(prod.id))).write(
        ProductsCompanion(
          stock: Value(prod.stock + qty),
          updatedAt: Value(DateTime.now()),
        ),
      );
    }
  }

  /// Bu pull turunda yeni eklenen ürün id'leri (delta atlama kuralı).
  final Set<int> _freshProductIds = {};

  bool _isProductNewInThisPull(int id) => _freshProductIds.contains(id);

  void beginPullBatch() => _freshProductIds.clear();

  void markProductFresh(int id) => _freshProductIds.add(id);

  Future<void> applyExpense(Map<String, dynamic> m) async {
    final uuid = m['uuid'] as String;
    final dup = await (select(expenses)
          ..where((t) => t.uuid.equals(uuid)))
        .getSingleOrNull();
    if (dup != null) return;
    double d(dynamic v) => (v as num?)?.toDouble() ?? 0;
    await into(expenses).insert(ExpensesCompanion.insert(
      date: Value(
          DateTime.tryParse(m['date'] as String? ?? '') ?? DateTime.now()),
      category: m['category'] as String,
      amount: d(m['amount']),
      note: Value(m['note'] as String?),
      uuid: uuid,
      updatedAt: Value(
          DateTime.tryParse(m['updated_at'] as String? ?? '') ??
              DateTime.now()),
    ));
  }

  Future<Product?> productByUuid(String uuid) {
    return (select(products)..where((t) => t.uuid.equals(uuid)))
        .getSingleOrNull();
  }

  // ================= Sorgular =================

  SimpleSelectStatement<Products, Product> _liveProducts() {
    final q = select(products)
      ..where((t) => t.isDeleted.equals(false));
    return q;
  }

  Future<Product?> findByBarcode(String barcode) {
    return (_liveProducts()..where((t) => t.barcode.equals(barcode)))
        .getSingleOrNull();
  }

  Future<List<Product>> searchProducts(String q) {
    final like = '%$q%';
    return (_liveProducts()
          ..where((t) => t.name.like(like) | t.barcode.like(like))
          ..orderBy([(t) => OrderingTerm(expression: t.name)])
          ..limit(50))
        .get();
  }

  Stream<List<Product>> watchProducts() {
    return (_liveProducts()
          ..orderBy([(t) => OrderingTerm(expression: t.name)]))
        .watch();
  }

  Stream<List<Product>> watchCriticalStock() {
    return (_liveProducts()
          ..where((t) => t.stock.isSmallerOrEqual(t.criticalLevel))
          ..orderBy([(t) => OrderingTerm(expression: t.stock)]))
        .watch();
  }

  Future<List<Category>> allCategories() => select(categories).get();

  /// Ürünü yumuşak sil (uzaklara bayrak olarak yayılır).
  Future<void> softDeleteProduct(int productId) {
    return transaction(() async {
      final p = await (select(products)
            ..where((t) => t.id.equals(productId)))
          .getSingle();
      await (update(products)..where((t) => t.id.equals(productId)))
          .write(ProductsCompanion(
        isDeleted: const Value(true),
        updatedAt: Value(DateTime.now()),
        syncStatus: const Value(1),
      ));
      final fresh = p.copyWith(
          isDeleted: true, updatedAt: DateTime.now());
      await enqueue(
          table: 'products',
          rowUuid: p.uuid,
          payload: await productPayload(fresh));
    });
  }

  /// Satışı tek transaction'da işle: fiş + satırlar + stok düş + hareket
  /// + hepsini giden kutusuna yaz.
  Future<SaleResult> completeSale({
    required List<SaleItemsCompanion> items,
    required double total,
    required double kdvTotal,
    required double profitTotal,
    double discount = 0,
    String paymentType = 'nakit',
  }) {
    return transaction(() async {
      final count = await (selectOnly(sales)
            ..addColumns([sales.id.count()]))
          .map((r) => r.read(sales.id.count()) ?? 0)
          .getSingle();
      final saleUuid = newUuid();
      final receiptNo =
          '$deviceCode-FS-${DateTime.now().millisecondsSinceEpoch}-${count + 1}';
      final saleId = await into(sales).insert(SalesCompanion.insert(
        receiptNo: receiptNo,
        total: Value(total),
        kdvTotal: Value(kdvTotal),
        profitTotal: Value(profitTotal),
        discount: Value(discount),
        paymentType: Value(paymentType),
        itemCount: Value(items.length),
        uuid: saleUuid,
        originDevice: Value(deviceCode),
      ));
      final saleRow = await (select(sales)
            ..where((t) => t.id.equals(saleId)))
          .getSingle();
      await enqueue(
          table: 'sales', rowUuid: saleUuid, payload: salePayload(saleRow));
      for (final item in items) {
        final itemUuid =
            (item.uuid.present && item.uuid.value.isNotEmpty)
                ? item.uuid.value
                : newUuid();
        String? prodUuid;
        final pid = item.productId.value;
        if (pid != null) {
          final pr = await (select(products)
                ..where((t) => t.id.equals(pid)))
              .getSingleOrNull();
          prodUuid = pr?.uuid;
        }
        final rowId = await into(saleItems).insert(item.copyWith(
          saleId: Value(saleId),
          uuid: Value(itemUuid),
          saleUuid: Value(saleUuid),
        ));
        final row = await (select(saleItems)
              ..where((t) => t.id.equals(rowId)))
            .getSingle();
        final payload = itemPayload(row);
        payload['product_uuid'] = prodUuid;
        await enqueue(
            table: 'sale_items', rowUuid: itemUuid, payload: payload);
        if (pid != null) {
          final prod =
              await (select(products)..where((t) => t.id.equals(pid)))
                  .getSingle();
          final newStock = prod.stock - item.qty.value;
          await (update(products)..where((t) => t.id.equals(pid))).write(
            ProductsCompanion(
              stock: Value(newStock),
              updatedAt: Value(DateTime.now()),
              syncStatus: const Value(1),
            ),
          );
          final movUuid = newUuid();
          await into(stockMovements)
              .insert(StockMovementsCompanion.insert(
            productId: pid,
            type: 'satis',
            qty: -item.qty.value,
            prevStock: prod.stock,
            newStock: newStock,
            note: Value(receiptNo),
            uuid: movUuid,
          ));
          await enqueue(table: 'stock_movements', rowUuid: movUuid, payload: {
            'uuid': movUuid,
            'product_uuid': prod.uuid,
            'type': 'satis',
            'qty': -item.qty.value,
            'prev_stock': prod.stock,
            'new_stock': newStock,
            'note': receiptNo,
            'date': DateTime.now().toIso8601String(),
          });
          final updated = await (select(products)
                ..where((t) => t.id.equals(pid)))
              .getSingle();
          await enqueue(
              table: 'products',
              rowUuid: updated.uuid,
              payload: await productPayload(updated));
        }
      }
      return SaleResult(id: saleId, receiptNo: receiptNo);
    });
  }

  /// Stok girişi / çıkışı / sayım düzeltme + kuyruk.
  Future<void> adjustStock({
    required int productId,
    required double qtyChange,
    required String type,
    String? note,
  }) {
    return transaction(() async {
      final prod = await (select(products)..where((t) => t.id.equals(productId)))
          .getSingle();
      final newStock =
          type == 'sayim' ? qtyChange : prod.stock + qtyChange;
      await (update(products)..where((t) => t.id.equals(productId))).write(
        ProductsCompanion(
          stock: Value(newStock),
          updatedAt: Value(DateTime.now()),
          syncStatus: const Value(1),
        ),
      );
      final movUuid = newUuid();
      final delta = type == 'sayim' ? newStock - prod.stock : qtyChange;
      await into(stockMovements).insert(StockMovementsCompanion.insert(
        productId: productId,
        type: type,
        qty: delta,
        prevStock: prod.stock,
        newStock: newStock,
        note: Value(note),
        uuid: movUuid,
      ));
      await enqueue(table: 'stock_movements', rowUuid: movUuid, payload: {
        'uuid': movUuid,
        'product_uuid': prod.uuid,
        'type': type,
        'qty': delta,
        'prev_stock': prod.stock,
        'new_stock': newStock,
        'note': note,
        'date': DateTime.now().toIso8601String(),
      });
      final updated = await (select(products)
            ..where((t) => t.id.equals(productId)))
          .getSingle();
      await enqueue(
          table: 'products',
          rowUuid: updated.uuid,
          payload: await productPayload(updated));
    });
  }

  /// Yeni ürün (uuid + kuyruk dahil).
  Future<Product> insertProduct(ProductsCompanion comp) {
    return transaction(() async {
      final u = (comp.uuid.present && comp.uuid.value.isNotEmpty)
          ? comp.uuid.value
          : newUuid();
      final id = await into(products).insert(comp.copyWith(
        uuid: Value(u),
        originDevice: Value(deviceCode),
      ));
      final row =
          await (select(products)..where((t) => t.id.equals(id))).getSingle();
      await enqueue(
          table: 'products',
          rowUuid: row.uuid,
          payload: await productPayload(row));
      return row;
    });
  }

  /// Ürün güncelle (uuid + kuyruk dahil).
  Future<void> updateProduct(int id, ProductsCompanion comp) {
    return transaction(() async {
      await (update(products)..where((t) => t.id.equals(id))).write(
        comp.copyWith(
          updatedAt: Value(DateTime.now()),
          syncStatus: const Value(1),
        ),
      );
      final row =
          await (select(products)..where((t) => t.id.equals(id))).getSingle();
      await enqueue(
          table: 'products',
          rowUuid: row.uuid,
          payload: await productPayload(row));
    });
  }

  /// Gider ekle (uuid + kuyruk dahil).
  Future<void> insertExpense(ExpensesCompanion comp) {
    return transaction(() async {
      final u = (comp.uuid.present && comp.uuid.value.isNotEmpty)
          ? comp.uuid.value
          : newUuid();
      final id = await into(expenses).insert(comp.copyWith(
        uuid: Value(u),
      ));
      final row = await (select(expenses)
            ..where((t) => t.id.equals(id)))
          .getSingle();
      await enqueue(
          table: 'expenses',
          rowUuid: row.uuid,
          payload: expensePayload(row));
    });
  }

  /// Günlük özet: ciro, kdv, kar, fiş sayısı.
  Future<DaySummary> daySummary(DateTime day) async {
    final start = DateTime(day.year, day.month, day.day);
    final end = start.add(const Duration(days: 1));
    final rows = await (select(sales)
          ..where((t) => t.date.isBetweenValues(start, end)))
        .get();
    double total = 0, kdv = 0, profit = 0;
    for (final r in rows) {
      total += r.total;
      kdv += r.kdvTotal;
      profit += r.profitTotal;
    }
    final exps = await (select(expenses)
          ..where((t) => t.date.isBetweenValues(start, end)))
        .get();
    final expTotal = exps.fold<double>(0, (s, e) => s + e.amount);
    return DaySummary(
      total: total,
      kdv: kdv,
      profit: profit,
      expenses: expTotal,
      receipts: rows.length,
    );
  }

  /// Aralık özeti + KDV kırılımı.
  Future<RangeSummary> rangeSummary(DateTime start, DateTime end) async {
    final rows = await (select(sales)
          ..where((t) => t.date.isBetweenValues(start, end.nextDay())))
        .get();
    double total = 0, kdv = 0, profit = 0;
    for (final r in rows) {
      total += r.total;
      kdv += r.kdvTotal;
      profit += r.profitTotal;
    }
    final kdvBreak = <double, KdvSlice>{};
    final payTotals = <String, double>{};
    final payCounts = <String, int>{};
    for (final r in rows) {
      payTotals[r.paymentType] = (payTotals[r.paymentType] ?? 0) + r.total;
      payCounts[r.paymentType] = (payCounts[r.paymentType] ?? 0) + 1;
    }
    // Satış yoksa IN () sorgusu SQLite hatası verir — atla.
    if (rows.isNotEmpty) {
      final items = await (select(saleItems)
            ..where((t) => t.saleId.isIn(rows.map((r) => r.id).toList())))
          .get();
      for (final i in items) {
        // kdvAmount kayıt anında adetle çarpılmış tutulur.
        final slice = kdvBreak.putIfAbsent(i.kdvRate, KdvSlice.new);
        final lineTotal = i.unitPrice * i.qty;
        slice.kdv += i.kdvAmount;
        slice.matrah += lineTotal - i.kdvAmount;
      }
    }
    final exps = await (select(expenses)
          ..where((t) => t.date.isBetweenValues(start, end.nextDay())))
        .get();
    return RangeSummary(
      total: total,
      kdv: kdv,
      profit: profit,
      expenses: exps.fold<double>(0, (s, e) => s + e.amount),
      receipts: rows.length,
      kdvBreakdown: kdvBreak,
      payTotals: payTotals,
      payCounts: payCounts,
    );
  }

  /// İlk kurulum örnek verisi.
  Future<void> ensureSeed() async {
    final catCount = await (selectOnly(categories)
          ..addColumns([categories.id.count()]))
        .map((r) => r.read(categories.id.count()) ?? 0)
        .getSingle();
    if (catCount > 0) return;
    final defter = await into(categories).insert(
        CategoriesCompanion.insert(name: 'Defter', uuid: newUuid()));
    final kalem = await into(categories)
        .insert(CategoriesCompanion.insert(name: 'Kalem', uuid: newUuid()));
    final kagit = await into(categories)
        .insert(CategoriesCompanion.insert(name: 'Kağıt', uuid: newUuid()));
    await into(products).insert(ProductsCompanion.insert(
      barcode: const Value('868000000001'),
      name: 'Çizgili Defter A4 80 Yaprak',
      categoryId: Value(defter),
      buyPrice: const Value(45),
      sellPrice: const Value(75),
      kdvRate: const Value(10),
      stock: const Value(50),
      criticalLevel: const Value(10),
      uuid: newUuid(),
    ));
    await into(products).insert(ProductsCompanion.insert(
      name: 'Kurşun Kalem HB',
      categoryId: Value(kalem),
      buyPrice: const Value(8),
      sellPrice: const Value(15),
      kdvRate: const Value(20),
      stock: const Value(200),
      criticalLevel: const Value(20),
      uuid: newUuid(),
    ));
    await into(products).insert(ProductsCompanion.insert(
      name: 'Fotokopi Kağıdı A4 80gr (500)',
      categoryId: Value(kagit),
      buyPrice: const Value(180),
      sellPrice: const Value(250),
      kdvRate: const Value(20),
      stock: const Value(30),
      criticalLevel: const Value(5),
      uuid: newUuid(),
    ));
  }
}

/// Satış sonucu: fiş id + fiş no (fiş yazdırmak için).
class SaleResult {
  final int id;
  final String receiptNo;
  const SaleResult({required this.id, required this.receiptNo});
}

class DaySummary {
  final double total, kdv, profit, expenses;
  final int receipts;
  const DaySummary({
    required this.total,
    required this.kdv,
    required this.profit,
    required this.expenses,
    required this.receipts,
  });
  double get netProfit => profit - expenses;
}

class RangeSummary {
  final double total, kdv, profit, expenses;
  final int receipts;
  final Map<double, KdvSlice> kdvBreakdown;
  final Map<String, double> payTotals;
  final Map<String, int> payCounts;
  const RangeSummary({
    required this.total,
    required this.kdv,
    required this.profit,
    required this.expenses,
    required this.receipts,
    required this.kdvBreakdown,
    required this.payTotals,
    required this.payCounts,
  });
  double get netProfit => profit - expenses;
}

/// KDV oranı başına matrah (KDV hariç) + hesaplanan KDV.
class KdvSlice {
  double matrah;
  double kdv;
  KdvSlice({this.matrah = 0, this.kdv = 0});
}

extension _NextDay on DateTime {
  DateTime nextDay() => add(const Duration(days: 1));
}

LazyDatabase _open() {
  return LazyDatabase(() async {
    final dir = await getApplicationDocumentsDirectory();
    final dbDir = Directory(p.join(dir.path, 'kirtasiye'));
    await dbDir.create(recursive: true);
    final file = File(p.join(dbDir.path, 'kirtasiye.db'));
    return NativeDatabase.createInBackground(file);
  });
}
