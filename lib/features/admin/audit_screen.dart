import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app.dart';
import '../../core/database/app_db.dart';
import '../../core/sync/cloud.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/money.dart';

/// Denetim İzi: satış + stok hareket + gider + tedarikçi defteri
/// tek kronolojik akışta. Kasa/supervisor denetimi için.
class AuditScreen extends ConsumerStatefulWidget {
  const AuditScreen({super.key});

  @override
  ConsumerState<AuditScreen> createState() => _AuditScreenState();
}

enum _Kind { satis, stok, gider, tedarikci }

class _Row {
  final DateTime date;
  final _Kind kind;
  final String title;
  final String sub;
  final double amount;
  final bool negative;
  _Row(this.date, this.kind, this.title, this.sub, this.amount,
      this.negative);
}

class _AuditScreenState extends ConsumerState<AuditScreen>
    with SyncRefreshMixin {
  final Set<_Kind> _filter = {
    _Kind.satis,
    _Kind.stok,
    _Kind.gider,
    _Kind.tedarikci
  };

  @override
  Widget build(BuildContext context) {
    final db = ref.watch(dbProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Denetim İzi')),
      body: Column(
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(8),
            child: Row(
              children: _Kind.values.map((k) {
                final sel = _filter.contains(k);
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FilterChip(
                    label: Text(_label(k)),
                    selected: sel,
                    onSelected: (_) => setState(() {
                      sel ? _filter.remove(k) : _filter.add(k);
                    }),
                  ),
                );
              }).toList(),
            ),
          ),
          Expanded(
            child: FutureBuilder<List<_Row>>(
              future: _load(db),
              builder: (_, snap) {
                if (snap.hasError) {
                  return Center(
                      child: Text('Yüklenemedi: ${snap.error}',
                          style: const TextStyle(
                              color: Colors.red)));
                }
                if (!snap.hasData) {
                  return const Center(
                      child: CircularProgressIndicator());
                }
                final rows = snap.data!
                    .where((r) => _filter.contains(r.kind))
                    .toList();
                if (rows.isEmpty) {
                  return const Center(
                      child: Text('Kayıt yok.'));
                }
                return ListView.builder(
                  itemCount: rows.length,
                  itemBuilder: (_, i) {
                    final r = rows[i];
                    return ListTile(
                      dense: true,
                      leading: Icon(_icon(r.kind),
                          color: _color(r.kind), size: 20),
                      title: Text(r.title,
                          style: const TextStyle(fontSize: 14)),
                      subtitle: Text(
                          '${fdate(r.date)} • ${r.sub}',
                          style:
                              const TextStyle(fontSize: 12)),
                      trailing: Text(
                        '${r.negative ? '-' : '+'}${money(r.amount)}',
                        style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: r.negative
                                ? Colors.red.shade700
                                : Colors.green.shade700),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  String _label(_Kind k) => switch (k) {
        _Kind.satis => 'Satış',
        _Kind.stok => 'Stok',
        _Kind.gider => 'Gider',
        _Kind.tedarikci => 'Tedarikçi',
      };

  IconData _icon(_Kind k) => switch (k) {
        _Kind.satis => Icons.point_of_sale,
        _Kind.stok => Icons.warehouse,
        _Kind.gider => Icons.money_off,
        _Kind.tedarikci => Icons.local_shipping,
      };

  Color _color(_Kind k) => switch (k) {
        _Kind.satis => PosColors.navy,
        _Kind.stok => PosColors.royal,
        _Kind.gider => PosColors.critTx,
        _Kind.tedarikci => PosColors.amberDark,
      };

  Future<List<_Row>> _load(AppDb db) async {
    final out = <_Row>[];
    final sales = await (db.select(db.sales)
          ..orderBy([(t) => drift.OrderingTerm.desc(t.date)])
          ..limit(100))
        .get();
    for (final s in sales) {
      out.add(_Row(
          s.date,
          _Kind.satis,
          '${s.receiptNo} • ${_payTr(s.paymentType)}${s.customer.isNotEmpty ? ' • ${s.customer}' : ''}',
          '${s.itemCount} kalem${s.discount > 0 ? ' • indirim ${money(s.discount)}' : ''}',
          s.total,
          false));
    }
    final movs = await (db.select(db.stockMovements)
          ..orderBy([(t) => drift.OrderingTerm.desc(t.date)])
          ..limit(100))
        .get();
    final prodNames = <int, String>{};
    for (final m in movs) {
      prodNames[m.productId] ??=
          await db.productName(m.productId) ?? 'Ürün #${m.productId}';
      out.add(_Row(
          m.date,
          _Kind.stok,
          '${prodNames[m.productId]} • ${_typeTr(m.type)}',
          '${fmtQty(m.prevStock)}→${fmtQty(m.newStock)}${m.note?.isNotEmpty == true ? ' • ${m.note}' : ''}',
          0,
          false));
    }
    final exps = await (db.select(db.expenses)
          ..orderBy([(t) => drift.OrderingTerm.desc(t.date)])
          ..limit(100))
        .get();
    for (final e in exps) {
      out.add(_Row(e.date, _Kind.gider,
          '${e.category}${e.note?.isNotEmpty == true ? ' • ${e.note}' : ''}',
          'Gider', e.amount, true));
    }
    final leds = await db.recentLedgerEntries(limit: 100);
    final supNames = <int, String>{};
    for (final l in leds) {
      supNames[l.supplierId] ??=
          await db.supplierName(l.supplierId) ??
              'Tedarikçi #${l.supplierId}';
      out.add(_Row(
          l.date,
          _Kind.tedarikci,
          '${supNames[l.supplierId]} • ${l.kind == 'alim' ? 'Mal alımı' : 'Ödeme'}',
          l.note ?? '',
          l.amount,
          l.kind != 'alim'));
    }
    out.sort((a, b) => b.date.compareTo(a.date));
    return out.take(200).toList();
  }

  String _payTr(String p) => switch (p) {
        'kart' => 'Kart',
        'parcali' => 'Parçalı',
        'cari' => 'Cari',
        _ => 'Nakit',
      };

  String _typeTr(String t) => switch (t) {
        'giris' => 'Giriş',
        'cikis' => 'Çıkış',
        'sayim' => 'Sayım',
        'satis' => 'Satış',
        'iade' => 'İade',
        _ => t,
      };
}
