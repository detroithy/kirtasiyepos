import 'dart:io' show Platform;

import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app.dart';
import '../../core/database/app_db.dart';
import '../../core/sync/cloud.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/money.dart';
import '../products/quick_add.dart';
import 'pos_print.dart';
import 'scan_screen.dart';

/// Sepet satırı: ürün + adet.
class CartLine {
  final Product product;
  double qty;
  CartLine(this.product, [this.qty = 1]);
}

class PosScreen extends ConsumerStatefulWidget {
  const PosScreen({super.key});

  @override
  ConsumerState<PosScreen> createState() => _PosScreenState();
}

class _PosScreenState extends ConsumerState<PosScreen> {
  final _searchCtrl = TextEditingController();
  final _paidCtrl = TextEditingController();
  final _searchFocus = FocusNode();
  List<Product> _results = [];
  final List<CartLine> _cart = [];
  String _payment = 'nakit';
  bool _busy = false;
  String _lastQuery = '';

  AppDb get _db => ref.read(dbProvider);

  double get _total =>
      _cart.fold(0, (s, l) => s + l.product.sellPrice * l.qty);
  double get _kdv => _cart.fold(
      0, (s, l) => s + kdvTutar(l.product.sellPrice, l.product.kdvRate) * l.qty);
  int get _count => _cart.length;

  void _refocusSearch() {
    if (mounted) _searchFocus.requestFocus();
  }

  Future<void> _search(String q) async {
    q = q.trim();
    _lastQuery = q;
    if (q.isEmpty) {
      setState(() => _results = []);
      return;
    }
    // Önce barkod tam eşleşme (USB okuyucu Enter basar -> direkt sepete).
    final exact = await _db.findByBarcode(q);
    if (exact != null) {
      _addToCart(exact);
      _searchCtrl.clear();
      setState(() => _results = []);
      _refocusSearch();
      return;
    }
    final list = await _db.searchProducts(q);
    if (mounted) setState(() => _results = list);
  }

  void _addToCart(Product p) {
    final i = _cart.indexWhere((l) => l.product.id == p.id);
    setState(() {
      if (i >= 0) {
        _cart[i].qty += 1;
      } else {
        _cart.add(CartLine(p));
      }
    });
    _refocusSearch();
  }

  Future<void> _completeSale() async {
    if (_cart.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      final items = _cart.map((l) {
        final p = l.product;
        final kdv = kdvTutar(p.sellPrice, p.kdvRate) * l.qty;
        final kar = satirKar(p.sellPrice, p.buyPrice, p.kdvRate, l.qty);
        return SaleItemsCompanion.insert(
          saleId: 0, // completeSale içinde gerçek id yazılır
          productId: drift.Value(p.id),
          barcode: drift.Value(p.barcode),
          name: p.name,
          qty: l.qty,
          unitPrice: p.sellPrice,
          kdvRate: drift.Value(p.kdvRate),
          kdvAmount: drift.Value(kdv),
          buyPriceSnapshot: drift.Value(p.buyPrice),
          profit: drift.Value(kar),
          uuid: newUuid(),
          saleUuid: const drift.Value(''),
        );
      }).toList();
      final profit = _cart.fold(
          0.0,
          (s, l) => s +
              satirKar(l.product.sellPrice, l.product.buyPrice,
                  l.product.kdvRate, l.qty));
      // Fiş için sepet görüntüsü (temizlemeden önce kopyala).
      final lines = _cart
          .map((l) => ReceiptLine(
                name: l.product.name,
                qty: l.qty,
                unitPrice: l.product.sellPrice,
                kdvRate: l.product.kdvRate,
              ))
          .toList();
      final saleTotal = _total;
      final saleKdv = _kdv;
      final salePay = _payment;
      final result = await _db.completeSale(
        items: items,
        total: saleTotal,
        kdvTotal: saleKdv,
        profitTotal: profit,
        paymentType: salePay,
      );
      final paid =
          double.tryParse(_paidCtrl.text.replaceAll(',', '.')) ?? 0;
      final change = paid - saleTotal;
      if (!mounted) return;
      setState(() {
        _cart.clear();
        _results = [];
        _paidCtrl.clear();
      });
      Cloud.instance.refreshPending();
      _receiptDialog(
        receiptNo: result.receiptNo,
        lines: lines,
        total: saleTotal,
        kdv: saleKdv,
        payment: salePay,
        paid: paid,
        change: change,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Hata: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
      _refocusSearch();
    }
  }

  /// Satış sonrası fiş özeti + yazdırma.
  Future<void> _receiptDialog({
    required String receiptNo,
    required List<ReceiptLine> lines,
    required double total,
    required double kdv,
    required String payment,
    required double paid,
    required double change,
  }) async {
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Fiş: $receiptNo'),
        content: SizedBox(
          width: 340,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ...lines.map((l) => Padding(
                      padding:
                          const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        children: [
                          Expanded(
                              child: Text(
                                  '${l.name} x ${fmtQty(l.qty)}')),
                          Text(money(l.unitPrice * l.qty),
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold)),
                        ],
                      ),
                    )),
                const Divider(),
                Row(
                    mainAxisAlignment:
                        MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('TOPLAM',
                          style: TextStyle(
                              fontWeight: FontWeight.bold)),
                      Text(money(total),
                          style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 18)),
                    ]),
                Row(
                    mainAxisAlignment:
                        MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('KDV:'),
                      Text(money(kdv)),
                    ]),
                if (paid > 0)
                  Row(
                      mainAxisAlignment:
                          MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Alınan: ${money(paid)}'),
                        Text('Para üstü: ${money(change)}',
                            style: const TextStyle(
                                fontWeight: FontWeight.bold)),
                      ]),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Kapat')),
          FilledButton.icon(
            onPressed: () async {
              Navigator.pop(ctx);
              try {
                await printReceipt(
                  receiptNo: receiptNo,
                  date: DateTime.now(),
                  lines: lines,
                  total: total,
                  kdvTotal: kdv,
                  profitTotal: 0,
                  paymentType: payment,
                  paid: paid,
                );
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                          content: Text('Yazdırma hatası: $e')));
                }
              }
              _refocusSearch();
            },
            icon: const Icon(Icons.print),
            label: const Text('Fişi Yazdır'),
          ),
        ],
      ),
    );
    _refocusSearch();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _paidCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('KırtasiyePOS • Hızlı Satış')),
      body: LayoutBuilder(
        builder: (ctx, c) {
          // Dar ekran (telefon dikey): alt alta; geniş: yan yana.
          if (c.maxWidth < 800) {
            return Column(
              children: [
                _searchField(),
                Expanded(flex: 3, child: _resultsList()),
                const Divider(height: 1),
                Expanded(flex: 4, child: _cartPanel()),
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 3,
                child: Column(
                  children: [
                    _searchField(),
                    Expanded(child: _resultsList()),
                  ],
                ),
              ),
              const VerticalDivider(width: 1),
              Expanded(flex: 2, child: _cartPanel()),
            ],
          );
        },
      ),
    );
  }

  Widget _searchField() {
    // Kamera tarama sadece mobilde (Windows'ta USB okuyucu var).
    final canScan = Platform.isAndroid || Platform.isIOS;
    return Padding(
      padding: const EdgeInsets.all(8),
      child: TextField(
        controller: _searchCtrl,
        focusNode: _searchFocus,
        autofocus: true,
        decoration: InputDecoration(
          labelText: 'Barkod okut / ürün adı yaz',
          prefixIcon: const Icon(Icons.qr_code_scanner),
          suffixIcon: canScan
              ? IconButton(
                  tooltip: 'Kamerayla okut',
                  icon: const Icon(Icons.photo_camera),
                  onPressed: () async {
                    final code = await Navigator.push<String>(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const ScanScreen()),
                    );
                    if (code != null && code.isNotEmpty) {
                      _searchCtrl.text = code;
                      await _search(code);
                    }
                    _refocusSearch();
                  },
                )
              : null,
          border: const OutlineInputBorder(),
        ),
        onSubmitted: _search,
        onChanged: (v) {
          if (v.length >= 2) _search(v);
        },
        textInputAction: TextInputAction.search,
      ),
    );
  }

  Widget _resultsList() {
    if (_results.isEmpty) {
      // Barkoda benziyor ama kayıtlı değilse -> tek tuşla hızlı ekle.
      final looksBarcode =
          RegExp(r'^\d{6,}$').hasMatch(_lastQuery);
      if (_lastQuery.isNotEmpty && looksBarcode) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Barkod kayıtlarda yok:\n$_lastQuery',
                    textAlign: TextAlign.center,
                    style:
                        const TextStyle(color: Colors.grey)),
                const SizedBox(height: 8),
                FilledButton.tonalIcon(
                  onPressed: () async {
                    final created =
                        await showQuickAddSheet(
                            context, _db, _lastQuery);
                    if (created != null) {
                      _addToCart(created);
                      _searchCtrl.clear();
                      setState(() {
                        _results = [];
                        _lastQuery = '';
                      });
                    }
                    _refocusSearch();
                  },
                  icon: const Icon(Icons.bolt),
                  label: const Text('Hızlı Ekle ve Sepete At'),
                ),
              ],
            ),
          ),
        );
      }
      return const Center(
          child: Text('Ürün aramak için yazın veya barkod okutun'));
    }
    return ListView.builder(
      itemCount: _results.length,
      itemBuilder: (_, i) {
        final p = _results[i];
        return ListTile(
          leading: const Icon(Icons.inventory),
          title: Text(p.name),
          subtitle: Text(
              '${p.barcode ?? 'barkodsuz'} • Stok: ${fmtQty(p.stock)}'),
          trailing: Text(money(p.sellPrice),
              style: const TextStyle(fontWeight: FontWeight.bold)),
          onTap: () => _addToCart(p),
        );
      },
    );
  }

  /// Sepet paneli: kendi içinde kayar, asla overflow vermez.
  Widget _cartPanel() {
    final paid =
        double.tryParse(_paidCtrl.text.replaceAll(',', '.')) ?? 0;
    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Text('Sepet ($_count)',
                    style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                TextButton.icon(
                  onPressed: _cart.isEmpty
                      ? null
                      : () => setState(() => _cart.clear()),
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Temizle'),
                ),
              ],
            ),
          ),
          if (_cart.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: Text('Sepet boş')),
            ),
          ..._cart.map((l) => Card(
                margin:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: ListTile(
                  dense: true,
                  title: Text(l.product.name,
                      style: const TextStyle(fontSize: 14)),
                  subtitle: Text(
                      '${money(l.product.sellPrice)} x ${fmtQty(l.qty)} = ${money(l.product.sellPrice * l.qty)}'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.remove),
                        onPressed: () => setState(() {
                          l.qty -= 1;
                          if (l.qty <= 0) _cart.remove(l);
                        }),
                      ),
                      Text(fmtQty(l.qty),
                          style: const TextStyle(
                              fontWeight: FontWeight.bold)),
                      IconButton(
                        icon: const Icon(Icons.add),
                        onPressed: () =>
                            setState(() => l.qty += 1),
                      ),
                    ],
                  ),
                ),
              )),
          const Divider(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('KDV:'),
                    Text(money(_kdv)),
                  ],
                ),
                const SizedBox(height: 4),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: Text('TOPLAM: ${money(_total)}',
                      style: Theme.of(context)
                          .textTheme
                          .titleLarge
                          ?.copyWith(fontWeight: FontWeight.bold)),
                ),
                const SizedBox(height: 8),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(
                        value: 'nakit',
                        label: Text('Nakit'),
                        icon: Icon(Icons.money)),
                    ButtonSegment(
                        value: 'kart',
                        label: Text('Kart'),
                        icon: Icon(Icons.credit_card)),
                  ],
                  selected: {_payment},
                  onSelectionChanged: (s) =>
                      setState(() => _payment = s.first),
                ),
                const SizedBox(height: 8),
                if (_payment == 'nakit')
                  TextField(
                    controller: _paidCtrl,
                    keyboardType:
                        const TextInputType.numberWithOptions(
                            decimal: true),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(
                          RegExp(r'[0-9,.]')),
                    ],
                    decoration: InputDecoration(
                      labelText: 'Alınan tutar',
                      suffixText: paid > 0
                          ? 'Üstü: ${money(paid - _total)}'
                          : null,
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                if (_payment == 'nakit') const SizedBox(height: 8),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: PosColors.amber,
                    foregroundColor: Colors.white,
                    minimumSize: const Size.fromHeight(48),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(6)),
                  ),
                  onPressed:
                      (_cart.isEmpty || _busy) ? null : _completeSale,
                  icon: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.check),
                  label:
                      Text(_busy ? 'İşleniyor...' : 'Satışı Tamamla'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
