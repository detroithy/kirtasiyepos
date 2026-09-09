import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app.dart';
import '../../core/database/app_db.dart';
import '../../core/sync/cloud.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/money.dart';
import 'pos_print.dart';

/// Satış İadesi: fiş nodan fişi bul, kalem + adet seç, iade fişi kes.
/// Stok geri döner, ciro/KDV düşer, orijinal fiş değişmez.
class ReturnScreen extends ConsumerStatefulWidget {
  const ReturnScreen({super.key});

  @override
  ConsumerState<ReturnScreen> createState() => _ReturnScreenState();
}

class _ReturnScreenState extends ConsumerState<ReturnScreen> {
  final _receiptCtrl = TextEditingController();
  final _focus = FocusNode();
  Sale? _sale;
  List<SaleItem> _lines = [];
  Map<int, double> _returned = {};
  final Map<int, double> _qty = {}; // saleItemId -> iade adedi
  bool _busy = false;
  String? _error;

  AppDb get _db => ref.read(dbProvider);

  @override
  void dispose() {
    _receiptCtrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  double _returnable(SaleItem l) {
    if (l.productId == null) return l.qty; // hizmet: takip yok
    final done = _returned[l.productId!] ?? 0;
    return (l.qty - done).clamp(0, l.qty);
  }

  double get _total => _qty.entries.fold(
      0.0,
      (s, e) =>
          s +
          _lines
                  .firstWhere((l) => l.id == e.key)
                  .unitPrice *
              e.value);

  Future<void> _find() async {
    final no = _receiptCtrl.text.trim();
    if (no.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
      _sale = null;
    });
    try {
      final sale = await _db.findSaleByReceipt(no);
      if (sale == null) {
        setState(() => _error = 'Fiş bulunamadı: $no');
        return;
      }
      if (sale.receiptNo.startsWith('İADE-')) {
        setState(() =>
            _error = 'İade fişleri tekrar iade edilemez.');
        return;
      }
      final lines = await _db.saleItemsFor(sale.id);
      final ret = await _db.returnedQtyByProduct(sale.receiptNo);
      if (!mounted) return;
      setState(() {
        _sale = sale;
        _lines = lines;
        _returned = ret;
        _qty.clear();
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Hata: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _complete() async {
    final sale = _sale;
    if (sale == null || _busy) return;
    final picked = _qty.entries.where((e) => e.value > 0).toList();
    if (picked.isEmpty) return;
    setState(() => _busy = true);
    try {
      // Orijinal indirim oranı iade satırlarına da yansır:
      final gross = _lines.fold(
          0.0, (s, l) => s + l.unitPrice * l.qty);
      final f = gross > 0 ? sale.total / gross : 1.0;
      final items = picked.map((e) {
        final l = _lines.firstWhere((x) => x.id == e.key);
        final q = -e.value; // negatif adet
        return SaleItemsCompanion.insert(
          saleId: 0,
          productId: l.productId == null
              ? const drift.Value<int?>(null)
              : drift.Value(l.productId),
          barcode: drift.Value(l.barcode),
          name: l.name,
          qty: q,
          unitPrice: l.unitPrice,
          kdvRate: drift.Value(l.kdvRate),
          kdvAmount: drift.Value(l.kdvAmount / l.qty * q * f),
          buyPriceSnapshot: drift.Value(l.buyPriceSnapshot),
          profit: drift.Value(l.profit / l.qty * q * f),
          uuid: newUuid(),
          saleUuid: const drift.Value(''),
        );
      }).toList();
      final total = picked.fold(
          0.0,
          (s, e) =>
              s +
              _lines.firstWhere((l) => l.id == e.key).unitPrice *
                  -e.value);
      final kdv = picked.fold(
          0.0,
          (s, e) {
            final l = _lines.firstWhere((x) => x.id == e.key);
            return s + l.kdvAmount / l.qty * -e.value * f;
          });
      final profit = picked.fold(
          0.0,
          (s, e) {
            final l = _lines.firstWhere((x) => x.id == e.key);
            return s + l.profit / l.qty * -e.value * f;
          });
      final no = await _db.nextReturnReceiptNo(sale.receiptNo);
      // Parçalı orijinalde bölünme aynen yansır:
      final of = gross > 0 ? total / (gross * f) : 0.0;
      // Baskı için satır görüntüsü (liste temizlenmeden önce):
      final printLines = picked
          .map((e) {
            final l =
                _lines.firstWhere((x) => x.id == e.key);
            return ReceiptLine(
              name: l.name,
              qty: -e.value,
              unitPrice: l.unitPrice,
              kdvRate: l.kdvRate,
            );
          })
          .toList();
      final result = await _db.completeSale(
        items: items,
        total: total,
        kdvTotal: kdv,
        profitTotal: profit,
        paymentType: sale.paymentType,
        cashAmount: sale.cashAmount * of,
        cardAmount: sale.cardAmount * of,
        customer: sale.customer,
        paid: sale.paymentType == 'cari' ? 0 : total,
        receiptNo: no,
        movementType: 'iade',
        movementNote: sale.receiptNo,
      );
      if (!mounted) return;
      setState(() {
        _sale = null;
        _lines = [];
        _returned = {};
        _qty.clear();
        _receiptCtrl.clear();
      });
      Cloud.instance.refreshPending();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            'İade tamamlandı: ${result.receiptNo} (${money(total)})'),
        backgroundColor: Colors.green.shade700,
        action: SnackBarAction(
          label: 'Yazdır',
          textColor: Colors.white,
          onPressed: () => printReceipt(
            receiptNo: result.receiptNo,
            date: DateTime.now(),
            lines: printLines,
            total: total,
            kdvTotal: kdv,
            profitTotal: 0,
            paymentType: sale.paymentType,
          ),
        ),
      ));
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
    return Scaffold(
      appBar:
          AppBar(title: const Text('KırtasiyePOS • Satış İadesi')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _receiptCtrl,
                    focusNode: _focus,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: 'Fiş no (örn. K1-0007)',
                      prefixIcon:
                          Icon(Icons.receipt_long),
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _find(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _busy ? null : _find,
                  icon: const Icon(Icons.search),
                  label: const Text('Bul'),
                ),
              ],
            ),
          ),
          if (_busy) const LinearProgressIndicator(),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(_error!,
                  style: const TextStyle(color: Colors.red)),
            ),
          if (_sale != null) ...[
            Card(
              margin: const EdgeInsets.symmetric(
                  horizontal: 12, vertical: 4),
              color: PosColors.infoBg,
              child: ListTile(
                title: Text(_sale!.receiptNo,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold)),
                subtitle: Text(
                    '${fdate(_sale!.date)} • ${_sale!.paymentType} • Toplam ${money(_sale!.total)}'),
                trailing: Text('İade: ${money(-_total)}',
                    style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                        color: Colors.red.shade700)),
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: _lines.length,
                itemBuilder: (_, i) {
                  final l = _lines[i];
                  final max = _returnable(l);
                  final cur = _qty[l.id] ?? 0;
                  return Card(
                    margin: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 4),
                    child: ListTile(
                      title: Text(l.name,
                          style:
                              const TextStyle(fontSize: 14)),
                      subtitle: Text(
                          '${fmtQty(l.qty)} x ${money(l.unitPrice)}'
                          '${l.productId == null ? ' • hizmet' : ' • iade edilebilir: ${fmtQty(max)}'}'),
                      trailing: max <= 0
                          ? const Text('Tümü iade',
                              style: TextStyle(
                                  color: Colors.grey,
                                  fontSize: 12))
                          : Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(
                                      Icons.remove),
                                  onPressed: cur <= 0
                                      ? null
                                      : () => setState(() =>
                                          _qty[l.id] =
                                              cur - 1),
                                ),
                                Text(fmtQty(cur),
                                    style: const TextStyle(
                                        fontWeight:
                                            FontWeight.bold)),
                                IconButton(
                                  icon:
                                      const Icon(Icons.add),
                                  onPressed: cur >= max
                                      ? null
                                      : () => setState(() =>
                                          _qty[l.id] =
                                              cur + 1),
                                ),
                              ],
                            ),
                    ),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: SizedBox(
                width: double.infinity,
                height: 48,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.red.shade700,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: (_total == 0 || _busy)
                      ? null
                      : _complete,
                  icon: const Icon(Icons.assignment_return),
                  label: Text(_busy
                      ? 'İşleniyor...'
                      : 'İadeyi Tamamla (${money(-_total)})'),
                ),
              ),
            ),
          ] else if (!_busy && _error == null)
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(12, 4, 12, 4),
                    child: Text('Son fişler (dokunarak seç)',
                        style: TextStyle(
                            fontWeight: FontWeight.bold)),
                  ),
                  Expanded(
                    child: FutureBuilder<List<Sale>>(
                      future: _db.recentSales(),
                      builder: (_, snap) {
                        if (!snap.hasData) {
                          return const Center(
                              child:
                                  CircularProgressIndicator());
                        }
                        final list = snap.data!.where((s) =>
                            !s.receiptNo
                                .startsWith('İADE-'));
                        if (list.isEmpty) {
                          return const Center(
                              child: Text('Fiş yok.'));
                        }
                        return ListView.builder(
                          itemCount: list.length,
                          itemBuilder: (_, i) {
                            final s = list.elementAt(i);
                            return Card(
                              margin:
                                  const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 4),
                              child: ListTile(
                                title: Text(s.receiptNo,
                                    style: const TextStyle(
                                        fontWeight:
                                            FontWeight.bold,
                                        fontSize: 14)),
                                subtitle: Text(
                                    '${fdate(s.date)} • ${s.paymentType}'),
                                trailing: Text(
                                    money(s.total),
                                    style: const TextStyle(
                                        fontWeight:
                                            FontWeight.bold)),
                                onTap: () {
                                  _receiptCtrl.text =
                                      s.receiptNo;
                                  _find();
                                },
                              ),
                            );
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
