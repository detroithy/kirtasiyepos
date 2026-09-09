import 'dart:io';

import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../app.dart';
import '../../core/database/app_db.dart';
import '../../core/utils/money.dart';

/// Veri Aktarım: tabloları Excel'in açtığı CSV'ye döker.
/// Dosyalar Belgeler/kirtasiye altına tarihli kaydedilir.
class DataExportScreen extends ConsumerStatefulWidget {
  const DataExportScreen({super.key});

  @override
  ConsumerState<DataExportScreen> createState() =>
      _DataExportScreenState();
}

class _DataExportScreenState
    extends ConsumerState<DataExportScreen> {
  bool _busy = false;
  String? _last;

  Future<String> _dir() async {
    final d = await getApplicationDocumentsDirectory();
    final dir = Directory('${d.path}/kirtasiye');
    await dir.create(recursive: true);
    return dir.path;
  }

  String _stamp() => DateTime.now()
      .toIso8601String()
      .replaceAll(':', '-')
      .substring(0, 16);

  Future<void> _save(String name, String content) async {
    final f = File('${await _dir()}/${name}_${_stamp()}.csv');
    await f.writeAsString('﻿$content'); // BOM: Excel Türkçe için
    if (mounted) {
      setState(() => _last = f.path);
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Kaydedildi: ${f.path}')));
    }
  }

  Future<void> _run(Future<void> Function(AppDb) fn) async {
    setState(() => _busy = true);
    try {
      await fn(ref.read(dbProvider));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Hata: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final jobs = [
      ('Ürünler', Icons.inventory_2, _exportProducts),
      ('Stok Hareketleri', Icons.warehouse, _exportMovements),
      ('Giderler', Icons.money_off, _exportExpenses),
      ('Tedarikçi Defteri', Icons.local_shipping, _exportLedger),
      ('Tedarikçiler', Icons.business, _exportSuppliers),
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('Veri Aktarım (CSV)')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          if (_last != null)
            Card(
              child: ListTile(
                leading: const Icon(Icons.check_circle,
                    color: Colors.green),
                title: const Text('Son dosya'),
                subtitle: Text(_last!,
                    style: const TextStyle(fontSize: 12)),
              ),
            ),
          ...jobs.map((j) => Card(
                child: ListTile(
                  leading: Icon(j.$2),
                  title: Text(j.$1),
                  trailing: _busy
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2))
                      : const Icon(Icons.download),
                  onTap: _busy ? null : () => _run(j.$3),
                ),
              )),
        ],
      ),
    );
  }

  Future<void> _exportProducts(AppDb db) async {
    final list = await db.watchProducts().first;
    final b = StringBuffer('Barkod;Ad;Birim;Alis;Satis;KDV;Stok;Kritik\n');
    for (final p in list) {
      b.writeln(
          '${p.barcode ?? ''};${p.name};${p.unit};${p.buyPrice};${p.sellPrice};${p.kdvRate};${p.stock};${p.criticalLevel}');
    }
    await _save('urunler', b.toString());
  }

  Future<void> _exportMovements(AppDb db) async {
    final movs = await (db.select(db.stockMovements)
          ..orderBy([(t) => drift.OrderingTerm.desc(t.date)])
          ..limit(2000))
        .get();
    final names = <int, String>{};
    final b = StringBuffer('Tarih;Urun;Tip;Miktar;Onceki;Yeni;Not\n');
    for (final m in movs) {
      names[m.productId] ??=
          await db.productName(m.productId) ?? '#${m.productId}';
      b.writeln(
          '${fdate(m.date)};${names[m.productId]};${m.type};${m.qty};${m.prevStock};${m.newStock};${m.note ?? ''}');
    }
    await _save('stok_hareket', b.toString());
  }

  Future<void> _exportExpenses(AppDb db) async {
    final list = await (db.select(db.expenses)
          ..orderBy([(t) => drift.OrderingTerm.desc(t.date)]))
        .get();
    final b = StringBuffer('Tarih;Kategori;Tutar;Not\n');
    for (final e in list) {
      b.writeln(
          '${fdate(e.date)};${e.category};${e.amount};${e.note ?? ''}');
    }
    await _save('giderler', b.toString());
  }

  Future<void> _exportLedger(AppDb db) async {
    final list = await db.recentLedgerEntries(limit: 2000);
    final names = <int, String>{};
    final b =
        StringBuffer('Tarih;Tedarikci;Tur;Tutar;Not\n');
    for (final l in list) {
      names[l.supplierId] ??=
          await db.supplierName(l.supplierId) ??
              '#${l.supplierId}';
      b.writeln(
          '${fdate(l.date)};${names[l.supplierId]};${l.kind};${l.amount};${l.note ?? ''}');
    }
    await _save('tedarikci_defter', b.toString());
  }

  Future<void> _exportSuppliers(AppDb db) async {
    final list = await db.allSuppliers();
    final b = StringBuffer('Ad;Telefon;Bakiye\n');
    for (final s in list) {
      b.writeln(
          '${s.name};${s.phone ?? ''};${await db.supplierBalance(s.id)}');
    }
    await _save('tedarikciler', b.toString());
  }
}
