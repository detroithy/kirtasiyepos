import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app.dart';
import '../../core/database/app_db.dart';
import '../../core/sync/cloud.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/money.dart';

/// Tedarikçiler + borç defteri.
/// Bakiye = alımlar - ödemeler (pozitif = tedarikçiye borç).
class SuppliersScreen extends ConsumerStatefulWidget {
  const SuppliersScreen({super.key});

  @override
  ConsumerState<SuppliersScreen> createState() => _SuppliersScreenState();
}

class _SuppliersScreenState extends ConsumerState<SuppliersScreen> {
  @override
  Widget build(BuildContext context) {
    final db = ref.watch(dbProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('KırtasiyePOS • Tedarikçiler')),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: PosColors.navy,
        foregroundColor: Colors.white,
        onPressed: () => _supplierDialog(context, db),
        icon: const Icon(Icons.add),
        label: const Text('Yeni Tedarikçi'),
      ),
      body: FutureBuilder<List<Supplier>>(
        future: db.allSuppliers(),
        builder: (_, snap) {
          if (snap.hasError) {
            return Center(
                child: Text('Yüklenemedi: ${snap.error}',
                    style: const TextStyle(color: Colors.red)));
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final list = snap.data!;
          if (list.isEmpty) {
            return const Center(
                child: Text(
                    'Tedarikçi yok.\nToptancını ekle, alım/ödeme işle.'));
          }
          return Column(
            children: [
              FutureBuilder<double>(
                future: db.totalSupplierDebt(),
                builder: (_, ds) => Card(
                  margin: const EdgeInsets.all(12),
                  color: (ds.data ?? 0) > 0
                      ? PosColors.critBg
                      : PosColors.okBg,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        const Expanded(
                          child: Text('TOPLAM TEDARİKÇİ BORCU',
                              style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 0.5))),
                        Text(money(ds.data ?? 0),
                            style: TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.w800,
                                color: (ds.data ?? 0) > 0
                                    ? PosColors.critTx
                                    : PosColors.okTx)),
                      ],
                    ),
                  ),
                ),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: list.length,
                  itemBuilder: (_, i) {
                    final s = list[i];
                    return FutureBuilder<double>(
                      future: db.supplierBalance(s.id),
                      builder: (_, bs) {
                        final b = bs.data ?? 0;
                        return Card(
                          margin: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 4),
                          child: ListTile(
                            leading: const Icon(
                                Icons.local_shipping),
                            title: Text(s.name),
                            subtitle: Text(s.phone ?? 'telefon yok'),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Column(
                                  mainAxisAlignment:
                                      MainAxisAlignment.center,
                                  crossAxisAlignment:
                                      CrossAxisAlignment.end,
                                  children: [
                                    const Text('BORÇ',
                                        style: TextStyle(
                                            fontSize: 10,
                                            color: Colors.grey)),
                                    Text(money(b),
                                        style: TextStyle(
                                            fontWeight:
                                                FontWeight.bold,
                                            fontSize: 16,
                                            color: b > 0
                                                ? PosColors.critTx
                                                : PosColors.okTx)),
                                  ],
                                ),
                                IconButton(
                                  icon: const Icon(Icons.edit,
                                      size: 20),
                                  onPressed: () =>
                                      _supplierDialog(
                                          context, db,
                                          supplier: s),
                                ),
                              ],
                            ),
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) =>
                                      SupplierDetailScreen(
                                          supplier: s)),
                            ).then((_) => setState(() {})),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _supplierDialog(BuildContext context, AppDb db,
      {Supplier? supplier}) async {
    final name = TextEditingController(text: supplier?.name ?? '');
    final phone = TextEditingController(text: supplier?.phone ?? '');
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title:
            Text(supplier == null ? 'Yeni Tedarikçi' : 'Düzenle'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              autofocus: true,
              decoration: const InputDecoration(
                  labelText: 'Ad * (örn. Gipta Toptan)',
                  border: OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: phone,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                  labelText: 'Telefon',
                  border: OutlineInputBorder()),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Vazgeç')),
          FilledButton(
            onPressed: () async {
              if (name.text.trim().isEmpty) return;
              try {
                if (supplier == null) {
                  await db.insertSupplier(
                    name: name.text.trim(),
                    phone: phone.text.trim().isEmpty
                        ? null
                        : phone.text.trim(),
                  );
                } else {
                  await db.updateSupplier(
                    supplier.id,
                    name: name.text.trim(),
                    phone: phone.text.trim().isEmpty
                        ? null
                        : phone.text.trim(),
                  );
                }
                Cloud.instance.refreshPending();
                if (ctx.mounted) Navigator.pop(ctx);
                setState(() {});
              } catch (e) {
                if (ctx.mounted) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                      SnackBar(content: Text('Hata: $e')));
                }
              }
            },
            child: const Text('Kaydet'),
          ),
        ],
      ),
    );
  }
}

/// Tedarikçi detayı: defter satırları + alım/ödeme girişi.
class SupplierDetailScreen extends ConsumerStatefulWidget {
  final Supplier supplier;
  const SupplierDetailScreen({super.key, required this.supplier});

  @override
  ConsumerState<SupplierDetailScreen> createState() =>
      _SupplierDetailScreenState();
}

class _SupplierDetailScreenState
    extends ConsumerState<SupplierDetailScreen>
    with SyncRefreshMixin {
  @override
  Widget build(BuildContext context) {
    final db = ref.watch(dbProvider);
    final s = widget.supplier;
    return Scaffold(
      appBar: AppBar(title: Text(s.name)),
      body: Column(
        children: [
          FutureBuilder<double>(
            future: db.supplierBalance(s.id),
            builder: (_, bs) {
              final b = bs.data ?? 0;
              return Card(
                margin: const EdgeInsets.all(12),
                color: b > 0 ? PosColors.critBg : PosColors.okBg,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                            b > 0
                                ? 'GÜNCEL BORÇ'
                                : (b < 0 ? 'AVANS' : 'HESAP KAPALI'),
                            style: const TextStyle(
                                fontWeight: FontWeight.bold)),
                      ),
                      Text(money(b.abs()),
                          style: TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.w800,
                              color: b > 0
                                  ? PosColors.critTx
                                  : PosColors.okTx)),
                    ],
                  ),
                ),
              );
            },
          ),
          Expanded(
            child: FutureBuilder<List<LedgerEntry>>(
              future: db.ledgerFor(s.id),
              builder: (_, snap) {
                if (!snap.hasData) {
                  return const Center(
                      child: CircularProgressIndicator());
                }
                final list = snap.data!;
                if (list.isEmpty) {
                  return const Center(
                      child: Text('Kayıt yok.'));
                }
                return ListView.builder(
                  itemCount: list.length,
                  itemBuilder: (_, i) {
                    final e = list[i];
                    final isAlim = e.kind == 'alim';
                    return ListTile(
                      leading: Icon(
                        isAlim
                            ? Icons.arrow_downward
                            : Icons.arrow_upward,
                        color: isAlim
                            ? Colors.red
                            : Colors.green,
                      ),
                      title: Text(e.note?.isNotEmpty == true
                          ? e.note!
                          : (isAlim ? 'Mal alımı' : 'Ödeme')),
                      subtitle: Text(fdate(e.date)),
                      trailing: Text(
                        '${isAlim ? '+' : '-'}${money(e.amount)}',
                        style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: isAlim
                                ? Colors.red
                                : Colors.green),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: () =>
                        _entryDialog(context, db, 'alim'),
                    icon: const Icon(Icons.add_shopping_cart),
                    label: const Text('Mal Alımı (Borç+)'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: PosColors.okTx,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: () =>
                        _entryDialog(context, db, 'odeme'),
                    icon: const Icon(Icons.payments),
                    label: const Text('Ödeme Yap (Borç-)'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _entryDialog(
      BuildContext context, AppDb db, String kind) async {
    final amount = TextEditingController();
    final note = TextEditingController();
    final isAlim = kind == 'alim';
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isAlim ? 'Mal Alımı' : 'Ödeme Yap'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: amount,
              autofocus: true,
              keyboardType:
                  const TextInputType.numberWithOptions(
                      decimal: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(
                    RegExp(r'[0-9,.]'))
              ],
              decoration: const InputDecoration(
                  labelText: 'Tutar ₺ *',
                  border: OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: note,
              decoration: InputDecoration(
                  labelText: isAlim
                      ? 'Not (örn. 12 koli A4)'
                      : 'Not (örn. havale)',
                  border: const OutlineInputBorder()),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Vazgeç')),
          FilledButton(
            onPressed: () async {
              final a = parseTr(amount.text);
              if (a <= 0) return;
              try {
                await db.insertLedgerEntry(
                  supplierId: widget.supplier.id,
                  kind: kind,
                  amount: a,
                  note: note.text.trim().isEmpty
                      ? null
                      : note.text.trim(),
                );
                Cloud.instance.refreshPending();
                if (ctx.mounted) Navigator.pop(ctx);
                setState(() {});
              } catch (e) {
                if (ctx.mounted) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                      SnackBar(content: Text('Hata: $e')));
                }
              }
            },
            child: const Text('Kaydet'),
          ),
        ],
      ),
    );
  }
}
