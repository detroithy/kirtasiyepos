import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app.dart';
import '../../core/database/app_db.dart';
import '../../core/sync/cloud.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/money.dart';

/// Cari (veresiye) defteri: açık fişler + tahsilat.
/// Ciro satış gününe yazılmıştır; tahsilat ciroyu iki kez saymaz.
class CariDefterScreen extends ConsumerStatefulWidget {
  /// Pushtan açılışta true (veri tazelenir).
  final bool active;
  const CariDefterScreen({super.key, this.active = true});

  @override
  ConsumerState<CariDefterScreen> createState() =>
      _CariDefterScreenState();
}

class _CariDefterScreenState
    extends ConsumerState<CariDefterScreen> with SyncRefreshMixin {
  void _reload() => setState(() {});

  @override
  void didUpdateWidget(covariant CariDefterScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final db = ref.watch(dbProvider);
    return Scaffold(
      appBar:
          AppBar(title: const Text('KırtasiyePOS • Cari Defter')),
      body: FutureBuilder<List<Sale>>(
        future: db.openDebts(),
        builder: (_, snap) {
          if (snap.hasError) {
            return Center(
                child: Text('Yüklenemedi: ${snap.error}',
                    style:
                        const TextStyle(color: Colors.red)));
          }
          if (!snap.hasData) {
            return const Center(
                child: CircularProgressIndicator());
          }
          final list = snap.data!;
          final total = list.fold(
              0.0, (s, r) => s + (r.total - r.paid));
          return Column(
            children: [
              Card(
                margin: const EdgeInsets.all(12),
                color: PosColors.critBg,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text('TOPLAM AÇIK VERESİYE',
                            style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: PosColors.critTx)),
                      ),
                      Text(money(total),
                          style: const TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.w800,
                              color: PosColors.critTx)),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: list.isEmpty
                    ? const Center(
                        child: Text('Açık veresiye yok.'))
                    : Builder(builder: (_) {
                        final groups =
                            <String, List<Sale>>{};
                        for (final s in list) {
                          final k = s.customer.isEmpty
                              ? '(isimsiz)'
                              : s.customer;
                          (groups[k] ??= []).add(s);
                        }
                        final names = groups.keys.toList()
                          ..sort();
                        return ListView.builder(
                          itemCount: names.length,
                          itemBuilder: (_, gi) {
                            final name = names[gi];
                            final gs = groups[name]!;
                            final gtotal = gs.fold(
                                0.0,
                                (s, r) =>
                                    s +
                                    (r.total - r.paid));
                            return Card(
                              margin:
                                  const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 4),
                              child: ExpansionTile(
                                leading: CircleAvatar(
                                  child: Text(name.isEmpty
                                      ? '?'
                                      : name[0]
                                          .toUpperCase()),
                                ),
                                title: Text(name,
                                    style: const TextStyle(
                                        fontWeight:
                                            FontWeight
                                                .bold)),
                                subtitle: Text(
                                    '${gs.length} açık fiş'),
                                trailing: Row(
                                  mainAxisSize:
                                      MainAxisSize.min,
                                  children: [
                                    Text(money(gtotal),
                                        style: const TextStyle(
                                            fontWeight:
                                                FontWeight
                                                    .bold,
                                            fontSize: 16,
                                            color: PosColors
                                                .critTx)),
                                    TextButton(
                                      onPressed: () =>
                                          _closeAll(
                                              context,
                                              db,
                                              name,
                                              gs),
                                      child: const Text(
                                          'Borcu Kapat'),
                                    ),
                                  ],
                                ),
                                children: gs.map((s) {
                                  final kalan =
                                      s.total - s.paid;
                                  return ListTile(
                                    dense: true,
                                    title: Text(
                                        '${s.receiptNo} • ${fday(s.date)}'),
                                    subtitle: Text(
                                        'Ödenen ${money(s.paid)} / Toplam ${money(s.total)}'),
                                    trailing: Row(
                                      mainAxisSize:
                                          MainAxisSize.min,
                                      children: [
                                        Text(money(kalan),
                                            style: const TextStyle(
                                                fontWeight:
                                                    FontWeight
                                                        .bold)),
                                        const SizedBox(
                                            width: 8),
                                        FilledButton.tonal(
                                          onPressed: () =>
                                              _collectDialog(
                                                  context,
                                                  db,
                                                  s),
                                          child: const Text(
                                              'Tahsil Et'),
                                        ),
                                      ],
                                    ),
                                  );
                                }).toList(),
                              ),
                            );
                          },
                        );
                      }),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _collectDialog(
      BuildContext context, AppDb db, Sale s) async {
    final kalan = s.total - s.paid;
    final ctrl =
        TextEditingController(text: kalan.toString());
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
            '${s.customer.isEmpty ? '(isimsiz)' : s.customer} • Kalan ${money(kalan)}'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType:
              const TextInputType.numberWithOptions(
                  decimal: true),
          inputFormatters: [
            FilteringTextInputFormatter.allow(
                RegExp(r'[0-9,.]'))
          ],
          decoration: const InputDecoration(
              labelText: 'Tahsil edilen ₺',
              border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Vazgeç')),
          FilledButton(
            onPressed: () {
              final a = parseTr(ctrl.text);
              if (a <= 0) return;
              Navigator.pop(ctx, true);
              _doCollect(db, s.id, a.clamp(0, kalan));
            },
            child: const Text('Kaydet'),
          ),
        ],
      ),
    );
    if (ok == true) _reload();
  }

  /// Kişinin tüm açık fişlerini tek seferde kapatır.
  Future<void> _closeAll(BuildContext context, AppDb db, String name,
      List<Sale> sales) async {
    final total =
        sales.fold(0.0, (s, r) => s + (r.total - r.paid));
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('$name • Borç kapatma'),
        content: Text(
            '${sales.length} fiş, toplam ${money(total)} tahsil edilecek. Onaylıyor musun?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Vazgeç')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Kapat')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      for (final s in sales) {
        await db.collectDebt(
            saleId: s.id, amount: s.total - s.paid);
      }
      Cloud.instance.refreshPending();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('$name borcu kapatıldı.'),
            backgroundColor: Colors.green.shade700));
      }
      _reload();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Hata: $e')));
      }
    }
  }

  Future<void> _doCollect(AppDb db, int saleId, double amount) async {    try {
      await db.collectDebt(saleId: saleId, amount: amount);
      Cloud.instance.refreshPending();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Hata: $e')));
      }
    }
  }
}
