import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

part 'app_db.g.dart';

/// Kategoriler (Defter, Kalem, Kağıt...)
class Categories extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text().unique()();
}

/// Tedarikçiler (toptancılar)
class Suppliers extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
  TextColumn get phone => text().nullable()();
}

/// Ürünler. Satış fiyatı KDV DAHİL etikettir (TR perakende adeti).
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
  // Faz-2 senkron hazırlığı: 0=temiz, 1=bekleyen
  IntColumn get syncStatus => integer().withDefault(const Constant(0))();
}

/// Stok hareketleri (giriş/çıkış/sayım/satış/iade)
class StockMovements extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get productId => integer().references(Products, #id)();
  TextColumn get type => text()(); // giris, cikis, sayim, satis, iade
  RealColumn get qty => real()();
  RealColumn get prevStock => real()();
  RealColumn get newStock => real()();
  TextColumn get note => text().nullable()();
  DateTimeColumn get date => dateTime().withDefault(currentDateAndTime)();
}

/// Satış fişleri. Tutarlar KDV dahil, kar alış-snapshot ile hesaplanır.
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
}

/// Satış satırları (alış fiyatı snapshot'lı -> sonradan fiyat değişse kar bozulmaz)
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
}

/// Giderler (kira, elektrik...) -> gerçek net kar için
class Expenses extends Table {
  IntColumn get id => integer().autoIncrement()();
  DateTimeColumn get date => dateTime().withDefault(currentDateAndTime)();
  TextColumn get category => text()();
  RealColumn get amount => real()();
  TextColumn get note => text().nullable()();
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
  ],
)
class AppDb extends _$AppDb {
  AppDb() : super(_open());

  /// Testler için bellek DB'si: AppDb.forTest(NativeDatabase.memory())
  AppDb.forTest(super.e);

  @override
  int get schemaVersion => 1;

  // ---------- Yardımcı sorgular ----------

  Future<Product?> findByBarcode(String barcode) {
    return (select(products)..where((t) => t.barcode.equals(barcode)))
        .getSingleOrNull();
  }

  Future<List<Product>> searchProducts(String q) {
    final like = '%$q%';
    return (select(products)
          ..where((t) => t.name.like(like) | t.barcode.like(like))
          ..orderBy([(t) => OrderingTerm(expression: t.name)])
          ..limit(50))
        .get();
  }

  Stream<List<Product>> watchProducts() {
    return (select(products)
          ..orderBy([(t) => OrderingTerm(expression: t.name)]))
        .watch();
  }

  Stream<List<Product>> watchCriticalStock() {
    return (select(products)
          ..where((t) => t.stock.isSmallerOrEqual(t.criticalLevel))
          ..orderBy([(t) => OrderingTerm(expression: t.stock)]))
        .watch();
  }

  Future<List<Category>> allCategories() => select(categories).get();

  /// Satışı tek transaction'da işle: fiş + satırlar + stok düş + hareket yaz.
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
      final receiptNo =
          'FS-${DateTime.now().millisecondsSinceEpoch}-${count + 1}';
      final saleId = await into(sales).insert(SalesCompanion.insert(
        receiptNo: receiptNo,
        total: Value(total),
        kdvTotal: Value(kdvTotal),
        profitTotal: Value(profitTotal),
        discount: Value(discount),
        paymentType: Value(paymentType),
        itemCount: Value(items.length),
      ));
      for (final item in items) {
        await into(saleItems).insert(item.copyWith(saleId: Value(saleId)));
        final pid = item.productId.value;
        final qty = item.qty.value;
        if (pid != null) {
          final prod =
              await (select(products)..where((t) => t.id.equals(pid)))
                  .getSingle();
          final newStock = prod.stock - qty;
          await (update(products)..where((t) => t.id.equals(pid))).write(
            ProductsCompanion(
              stock: Value(newStock),
              updatedAt: Value(DateTime.now()),
              syncStatus: const Value(1),
            ),
          );
          await into(stockMovements).insert(StockMovementsCompanion.insert(
            productId: pid,
            type: 'satis',
            qty: -qty,
            prevStock: prod.stock,
            newStock: newStock,
            note: Value(receiptNo),
          ));
        }
      }
      return SaleResult(id: saleId, receiptNo: receiptNo);
    });
  }

  /// Stok girişi / sayım düzeltme.
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
      await into(stockMovements).insert(StockMovementsCompanion.insert(
        productId: productId,
        type: type,
        qty: type == 'sayim' ? newStock - prod.stock : qtyChange,
        prevStock: prod.stock,
        newStock: newStock,
        note: Value(note),
      ));
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
    final defter = await into(categories)
        .insert(CategoriesCompanion.insert(name: 'Defter'));
    final kalem =
        await into(categories).insert(CategoriesCompanion.insert(name: 'Kalem'));
    final kagit = await into(categories)
        .insert(CategoriesCompanion.insert(name: 'Kağıt'));
    await into(products).insert(ProductsCompanion.insert(
      barcode: const Value('868000000001'),
      name: 'Çizgili Defter A4 80 Yaprak',
      categoryId: Value(defter),
      buyPrice: const Value(45),
      sellPrice: const Value(75),
      kdvRate: const Value(10),
      stock: const Value(50),
      criticalLevel: const Value(10),
    ));
    await into(products).insert(ProductsCompanion.insert(
      name: 'Kurşun Kalem HB',
      categoryId: Value(kalem),
      buyPrice: const Value(8),
      sellPrice: const Value(15),
      kdvRate: const Value(20),
      stock: const Value(200),
      criticalLevel: const Value(20),
    ));
    await into(products).insert(ProductsCompanion.insert(
      name: 'Fotokopi Kağıdı A4 80gr (500)',
      categoryId: Value(kagit),
      buyPrice: const Value(180),
      sellPrice: const Value(250),
      kdvRate: const Value(20),
      stock: const Value(30),
      criticalLevel: const Value(5),
    ));
  }
}

/// Satış sonucu: fiş id + fiş no (fiş yazdırmak için).
class SaleResult {
  final int id;
  final String receiptNo;
  const SaleResult({required this.id, required this.receiptNo});
}

class DaySummary {  final double total, kdv, profit, expenses;
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
