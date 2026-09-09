import 'dart:io' show Platform;

import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app.dart';
import '../../core/database/app_db.dart';
import '../../core/sync/cloud.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/money.dart';
import '../pos_device/pos_device.dart';
import '../pos_device/simulated_device.dart';
import '../pos_device/tokenx_device.dart';
import '../products/quick_add.dart';
import 'cari_defter_screen.dart';
import 'return_screen.dart';
import 'pos_print.dart';
import 'scan_screen.dart';

/// Sepet satırı: ürün + adet.
class CartLine {
  final Product product;
  double qty;
  CartLine(this.product, [this.qty = 1]);
}

/// Tezgah üstü hızlı hizmetler (stoksuz, KDV %20 varsayılır).
const List<(String, double)> quickServices = [
  ('S/B Çıktı (A4)', 2.5),
  ('Renkli Baskı (A4)', 7.5),
  ('Spiral Ciltleme', 35.0),
  ('Laminasyon', 20.0),
];

const _receiptSeqKey = 'receipt_seq';

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
  double _discount = 0;
  // Parçalı/cari detayları:
  double _cashSplit = 0;
  double _cardSplit = 0;
  String _customer = '';
  String _receiptPreview = '';

  AppDb get _db => ref.read(dbProvider);

  @override
  void initState() {
    super.initState();
    _refreshPreview();
  }

  /// Sıradaki fiş no önizlemesi (K1-0007...).
  Future<void> _refreshPreview() async {
    final prefs = await SharedPreferences.getInstance();
    final seq = prefs.getInt(_receiptSeqKey) ?? await _salesCount() + 1;
    if (mounted) {
      setState(() =>
          _receiptPreview = '${_db.deviceCode}-${seq.toString().padLeft(4, '0')}');
    }
  }

  Future<int> _salesCount() async {
    return (await (_db.selectOnly(_db.sales)
          ..addColumns([_db.sales.id.count()]))
        .map((r) => r.read(_db.sales.id.count()) ?? 0)
        .getSingle());
  }

  /// Satışta harcanan fiş no: sayaçtan alıp bir artırır.
  Future<String> _takeReceiptNo() async {
    final prefs = await SharedPreferences.getInstance();
    var seq = prefs.getInt(_receiptSeqKey) ?? await _salesCount() + 1;
    await prefs.setInt(_receiptSeqKey, seq + 1);
    return '${_db.deviceCode}-${seq.toString().padLeft(4, '0')}';
  }

  /// Hizmetler DB'de tutulmaz; sepete sentetik ürün olarak girer (id<0).
  void _addService(int index) {
    final now = DateTime.now();
    final svc = quickServices[index];
    _addToCart(Product(
      id: -(index + 1),
      name: svc.$1,
      unit: 'adet',
      buyPrice: 0,
      sellPrice: svc.$2,
      kdvRate: 20,
      stock: 0,
      criticalLevel: 0,
      createdAt: now,
      updatedAt: now,
      syncStatus: 0,
      uuid: 'svc-$index',
      originDevice: _db.deviceCode,
      isDeleted: false,
    ));
  }

  double get _subtotal =>
      _cart.fold(0.0, (s, l) => s + l.product.sellPrice * l.qty);

  /// İndirim çarpanı: satır KDV/karı orantılı küçültür (matrah dürüstlüğü).
  double get _factor {
    if (_subtotal <= 0) return 1.0;
    final d = _discount.clamp(0, _subtotal);
    return (_subtotal - d) / _subtotal;
  }

  /// ÖDENECEK tutar (ara toplam - indirim). Mevcut kullanımlar aynen çalışır.
  double get _total => _subtotal - _discount.clamp(0, _subtotal);
  double get _kdv =>
      _cart.fold(
          0.0,
          (s, l) =>
              s +
              kdvTutar(l.product.sellPrice, l.product.kdvRate) *
                  l.qty) *
      _factor;
  int get _count => _cart.length;

  /// Kaydedilecek para üstü: SADECE nakitte (alınan - toplam),
  /// diğer tiplerde her zaman 0. Kâra dokunmaz, ayrı izlenir.
  double _changeFor(String pay) =>
      pay == 'nakit' ? parseTr(_paidCtrl.text) - _total : 0.0;

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

  /// Kartlı tutarı POS cihazından onaylatır. Onay yoksa null döner
  /// (satış KAYDEDİLMEZ).
  /// - Bypass açıksa cihaza sorulmadan manuel onay döner (fişte izi olur).
  /// - Bağlantı/zaman aşımı hatalarında Tekrar Dene / Manuel Devam Et
  ///   / Vazgeç seçenekleri sunulur (sistem asla kilitlenmez).
  /// - Cihazın açık REDDİnde manuel seçenek YOKTUR (kart reddedildi).
  Future<PosResult?> _authorizeCard(
      double amountTl, String receiptNo) async {
    final settings = await PosSettings.load();
    if (!mounted) return null;
    if (settings.bypass) {
      return const PosResult(
        approved: true,
        manual: true,
        message: 'Acil durum bypassı: tutar terminalden elle alındı',
      );
    }
    final PosDevice device = settings.driver == 'tokenx'
        ? TokenXDevice(settings: settings)
        : SimulatedDevice();
    final req = PosSaleRequest(
      amountKurus: (amountTl * 100).round(),
      receiptNo: receiptNo,
      lines: [
        for (final l in _cart)
          PosLine(
            name: l.product.name,
            qty: l.qty,
            unitPriceTl: l.product.sellPrice,
            kdvDept: settings.deptFor(l.product.kdvRate),
          ),
      ],
      timeout: Duration(seconds: settings.timeoutSec),
    );
    var cancelled = false;
    // ignore: unawaited_futures
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(device.name),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Tutar: ${money(amountTl)}',
                style: const TextStyle(
                    fontSize: 22, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text(
                'Kartı cihaza okutun / takın. Onay bekleniyor...'),
            const SizedBox(height: 12),
            const LinearProgressIndicator(),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              cancelled = true;
              Navigator.pop(ctx);
            },
            child: const Text('Vazgeç'),
          ),
        ],
      ),
    );
    PosResult res;
    try {
      res = await device
          .sale(req)
          .timeout(req.timeout + const Duration(seconds: 10));
    } on PosNotConfigured catch (e) {
      if (mounted) Navigator.pop(context);
      return _deviceFailure(e.message, amountTl, receiptNo);
    } catch (e) {
      if (mounted) Navigator.pop(context);
      return _deviceFailure('Cihaz hatası: $e', amountTl, receiptNo);
    }
    if (mounted) Navigator.pop(context); // bekleme diyaloğu
    if (cancelled) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'İptal edildi. Cihazdan çekim yapıldıysa iade/iptal işlemi yapın.')));
      }
      return null;
    }
    if (!res.approved) {
      // Belirsiz sonuç (zaman aşımı): manuel devam SEÇENEKLİ.
      if (res.uncertain) {
        return _deviceFailure(
            '${res.message}\nSatış henüz kaydedilmedi.',
            amountTl,
            receiptNo);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Ödeme reddedildi: ${res.message}')));
      }
      return null;
    }
    return res;
  }

  /// Cihaz arızasında kilitlenmeyen çıkış: Tekrar Dene /
  /// Manuel Devam Et (terminalden elle tahsil, fişte izi olur) / Vazgeç.
  Future<PosResult?> _deviceFailure(
      String message, double amountTl, String receiptNo) async {
    if (!mounted) return null;
    final choice = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Cihaza ulaşılamadı'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(message),
            const SizedBox(height: 8),
            Text('Tutar: ${money(amountTl)}',
                style: const TextStyle(fontWeight: FontWeight.bold)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'cancel'),
            child: const Text('Vazgeç'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'manual'),
            child: const Text('Manuel Devam Et'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, 'retry'),
            child: const Text('Tekrar Dene'),
          ),
        ],
      ),
    );
    if (choice == 'manual') {
      return const PosResult(
        approved: true,
        manual: true,
        message: 'Manuel devam: tutar terminalden elle alındı',
      );
    }
    if (choice == 'retry') {
      return _authorizeCard(amountTl, receiptNo);
    }
    return null;
  }

  Future<void> _completeSale() async {
    if (_cart.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      final f = _factor;
      final items = _cart.map((l) {
        final p = l.product;
        final kdv = kdvTutar(p.sellPrice, p.kdvRate) * l.qty * f;
        final kar =
            satirKar(p.sellPrice, p.buyPrice, p.kdvRate, l.qty) * f;
        return SaleItemsCompanion.insert(
          saleId: 0, // completeSale içinde gerçek id yazılır
          productId: p.id <= 0
              ? const drift.Value<int?>(null) // hizmet: stoksuz
              : drift.Value(p.id),
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
              (s, l) =>
                  s +
                  satirKar(l.product.sellPrice, l.product.buyPrice,
                          l.product.kdvRate, l.qty) *
                      _factor);
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
      // Parçalı/cari doğrulama:
      var cash = _cashSplit;
      var card = _cardSplit;
      var customer = _customer;
      if (salePay == 'parcali') {
        if ((cash + card - saleTotal).abs() > 0.01 ||
            cash < 0 ||
            card < 0) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content:
                  Text('Sepet değişti — parçalı tutarları yeniden girin.')));
          await _parcaliDialog();
          return;
        }
      } else if (salePay == 'cari' && customer.trim().isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Cari satış için müşteri adı gerekli.')));
        await _cariDialog();
        return;
      }
      final receiptNo = await _takeReceiptNo();
      final saleDiscount = _discount.clamp(0.0, _subtotal);
      // Kartlı tutar cihazdan onaylanır (Beko 300TR). Onaysız kayıt YOK.
      var approvalCode = '';
      var fiscalNo = '';
      var posStatus = '';
      final cardAmount = salePay == 'kart'
          ? saleTotal
          : (salePay == 'parcali' ? card : 0.0);
      if (cardAmount > 0) {
        final auth =
            await _authorizeCard(cardAmount, receiptNo);
        if (auth == null) {
          if (mounted) setState(() => _busy = false);
          _refocusSearch();
          return;
        }
        approvalCode = auth.approvalCode;
        fiscalNo = auth.fiscalNo;
        posStatus = auth.manual ? 'manual' : 'approved';
      }
      final result = await _db.completeSale(
        items: items,
        total: saleTotal,
        kdvTotal: saleKdv,
        profitTotal: profit,
        discount: saleDiscount,
        paymentType: salePay,
        cashAmount: cash,
        cardAmount: card,
        customer: customer.trim(),
        receiptNo: receiptNo,
        approvalCode: approvalCode,
        fiscalNo: fiscalNo,
        posStatus: posStatus,
        change: _changeFor(salePay),
      );
      final paidRaw = parseTr(_paidCtrl.text);
      // Nakit: elden alınan; parçalı: toplam (nakit+kart); cari: 0.
      final paid = salePay == 'nakit'
          ? paidRaw
          : (salePay == 'parcali' ? cash + card : 0.0);
      // Para üstü SADECE nakitte olur; kart/cari/parçalıda her zaman 0.
      // (Eskiden kart/cari'de negatif yazılıyordu — artık yazılmıyor.)
      final change = salePay == 'nakit' ? paidRaw - saleTotal : 0.0;
      if (!mounted) return;
      setState(() {
        _cart.clear();
        _results = [];
        _paidCtrl.clear();
        _cashSplit = 0;
        _cardSplit = 0;
        _customer = '';
        _discount = 0;
      });
      Cloud.instance.refreshPending();
      _refreshPreview();
      _receiptDialog(
        receiptNo: result.receiptNo,
        lines: lines,
        total: saleTotal,
        kdv: saleKdv,
        discount: saleDiscount,
        payment: salePay,
        paid: paid,
        change: change,
        cash: cash,
        card: card,
        customer: customer.trim(),
        approvalCode: approvalCode,
        fiscalNo: fiscalNo,
        posStatus: posStatus,
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

  /// Ödeme tipi seçimi: parçalı/cari detay ister, vazgeçilirse eski tip kalır.
  Future<void> _onPaymentSelected(String v) async {
    if (v == 'parcali') {
      final ok = await _parcaliDialog();
      if (!ok) return;
    } else if (v == 'cari') {
      final ok = await _cariDialog();
      if (!ok) return;
    }
    setState(() => _payment = v);
  }

  /// Parçalı ödeme: nakit tutarı gir, kart otomatik tamamlar.
  Future<bool> _parcaliDialog() async {
    if (_cart.isEmpty) return false;
    final ctrl = TextEditingController(
        text: _cashSplit > 0
            ? _cashSplit.toString()
            : _total.toString());
    final res = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Parçalı Ödeme • Toplam ${money(_total)}'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType:
              const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[0-9,.]'))
          ],
          decoration: const InputDecoration(
              labelText: 'Nakit kısım ₺ (kalan karta)',
              border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Vazgeç')),
          FilledButton(
            onPressed: () {
              final cash = tryParseTr(ctrl.text);
              if (cash == null || cash < 0 || cash > _total) {
                return;
              }
              _cashSplit = cash;
              _cardSplit = _total - cash;
              Navigator.pop(ctx, true);
            },
            child: const Text('Tamam'),
          ),
        ],
      ),
    );
    return res == true;
  }

  /// Cari (veresiye): müşteri adı zorunlu.
  /// Sepet indirimi: tutar veya % kısayol. KDV/kar orantılı küçülür.
  Future<void> _discountDialog() async {
    if (_cart.isEmpty) return;
    final ctrl = TextEditingController(
        text: _discount > 0 ? _discount.toString() : '');
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) {
          void pct(double p) {
            final v = _subtotal * p / 100;
            ctrl.text = v.toStringAsFixed(2);
            setD(() {});
          }

          return AlertDialog(
            title: Text('İndirim • Ara Toplam ${money(_subtotal)}'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
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
                      labelText: 'İndirim tutarı ₺',
                      border: OutlineInputBorder()),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    ActionChip(
                        label: const Text('%5'),
                        onPressed: () => pct(5)),
                    ActionChip(
                        label: const Text('%10'),
                        onPressed: () => pct(10)),
                    ActionChip(
                        label: const Text('Temizle'),
                        onPressed: () {
                          ctrl.clear();
                          setD(() {});
                        }),
                  ],
                ),
              ],
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Vazgeç')),
              FilledButton(
                onPressed: () {
                  final v = parseTr(ctrl.text);
                  setState(() {
                    _discount = v.clamp(0.0, _subtotal);
                    // Parçalı bölünme indirimsiz kaldıysa sıfırla:
                    if (_payment == 'parcali' &&
                        (_cashSplit + _cardSplit - _total)
                                .abs() >
                            0.01) {
                      _cashSplit = 0;
                      _cardSplit = 0;
                    }
                  });
                  Navigator.pop(ctx);
                  _refocusSearch();
                },
                child: const Text('Uygula'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<bool> _cariDialog() async {
    final ctrl = TextEditingController(text: _customer);
    final res = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Cari Satış • Toplam ${money(_total)}'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(
              labelText: 'Müşteri adı *',
              border: OutlineInputBorder()),
          onSubmitted: (_) {
            if (ctrl.text.trim().isNotEmpty) {
              _customer = ctrl.text.trim();
              Navigator.pop(ctx, true);
            }
          },
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Vazgeç')),
          FilledButton(
            onPressed: () {
              if (ctrl.text.trim().isEmpty) return;
              _customer = ctrl.text.trim();
              Navigator.pop(ctx, true);
            },
            child: const Text('Tamam'),
          ),
        ],
      ),
    );
    return res == true;
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
    double cash = 0,
    double card = 0,
    String customer = '',
    double discount = 0,
    String approvalCode = '',
    String fiscalNo = '',
    String posStatus = '',
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
                if (discount > 0)
                  Row(
                      mainAxisAlignment:
                          MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('İndirim:'),
                        Text('-${money(discount)}',
                            style: const TextStyle(
                                color: Colors.green)),
                      ]),
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
                Text(_paymentLabel(payment, customer),
                    style: const TextStyle(color: Colors.grey)),
                if (payment == 'parcali') ...[
                  Row(
                      mainAxisAlignment:
                          MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Nakit:'),
                        Text(money(cash)),
                      ]),
                  Row(
                      mainAxisAlignment:
                          MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Kart:'),
                        Text(money(card)),
                      ]),
                ],
                if (approvalCode.isNotEmpty)
                  Text('Onay Kodu: $approvalCode',
                      style: const TextStyle(
                          color: Colors.grey, fontSize: 12)),
                if (fiscalNo.isNotEmpty)
                  Text('Mali Fiş No: $fiscalNo',
                      style: const TextStyle(
                          color: Colors.grey, fontSize: 12)),
                if (posStatus == 'manual')
                  const Text('Not: kart tutarı terminalden elle alındı',
                      style: TextStyle(
                          color: Colors.orange, fontSize: 12)),
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
                  cash: cash,
                  card: card,
                  customer: customer,
                  discount: discount,
                  approvalCode: approvalCode,
                  fiscalNo: fiscalNo,
                  posStatus: posStatus,
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
            label: const Text('Yazdır & Bitir'),
          ),
        ],
      ),
    );
    _refocusSearch();
  }

  String _paymentLabel(String p, String customer) {
    return switch (p) {
      'kart' => 'Ödeme: Kredi Kartı',
      'parcali' => 'Ödeme: Parçalı',
      'cari' => 'Ödeme: Cari${customer.isNotEmpty ? ' ($customer)' : ''}',
      _ => 'Ödeme: Nakit',
    };
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
      appBar: AppBar(
        title: const Text('KırtasiyePOS • Hızlı Satış'),
        actions: [
          IconButton(
            tooltip: 'Satış İadesi',
            icon: const Icon(Icons.assignment_return),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => const ReturnScreen()),
            ),
          ),
          IconButton(
            tooltip: 'Cari Defter (veresiye)',
            icon: const Icon(Icons.book),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => const CariDefterScreen()),
            ),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (ctx, c) {
          // Dar ekran (telefon dikey): alt alta; geniş: yan yana.
          if (c.maxWidth < 800) {
            return Column(
              children: [
                _searchField(),
                _servicesStrip(),
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
                    _servicesStrip(),
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

  /// Tezgah üstü hızlı hizmetler şeridi (yatay kayar, taşmaz).
  Widget _servicesStrip() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(12, 4, 12, 4),
          child: Text('Tezgah Üstü Hızlı Hizmetler',
              style:
                  TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: List.generate(quickServices.length, (i) {
              final s = quickServices[i];
              return Padding(
                padding: const EdgeInsets.only(right: 8, bottom: 8),
                child: ActionChip(
                  avatar: const Icon(Icons.print_outlined, size: 18),
                  label: Text('${s.$1} • ${money(s.$2)}'),
                  onPressed: () => _addService(i),
                ),
              );
            }),
          ),
        ),
      ],
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

  Widget _payChip(String value, String label, IconData icon) {
    final sel = _payment == value;
    return ChoiceChip(
      label: Text(label),
      avatar: Icon(icon,
          size: 18, color: sel ? Colors.white : PosColors.navy),
      selected: sel,
      selectedColor: PosColors.navy,
      labelStyle: TextStyle(
          color: sel ? Colors.white : PosColors.navy,
          fontWeight: FontWeight.bold),
      onSelected: (_) => _onPaymentSelected(value),
    );
  }

  /// Sepet paneli: kendi içinde kayar, asla overflow vermez.
  Widget _cartPanel() {
    final paid = parseTr(_paidCtrl.text);
    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Sepet ($_count)${_receiptPreview.isEmpty ? '' : ' • Fiş $_receiptPreview'}',
                    style: Theme.of(context).textTheme.titleMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
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
                    TextButton.icon(
                      onPressed: _cart.isEmpty
                          ? null
                          : () => _discountDialog(),
                      icon: const Icon(Icons.percent, size: 18),
                      label: Text(_discount > 0
                          ? 'İndirim: -${money(_discount)} (değiştir)'
                          : 'İndirim Ekle'),
                    ),
                    if (_discount > 0)
                      Text('Ara: ${money(_subtotal)}',
                          style: const TextStyle(
                              color: Colors.grey,
                              decoration:
                                  TextDecoration.lineThrough)),
                  ],
                ),
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
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    _payChip('nakit', 'Nakit', Icons.money),
                    _payChip('kart', 'Kart', Icons.credit_card),
                    _payChip(
                        'parcali', 'Parçalı', Icons.splitscreen),
                    _payChip('cari', 'Cari', Icons.book),
                  ],
                ),
                if (_payment == 'parcali')
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      'Nakit ${money(_cashSplit)} + Kart ${money(_cardSplit)}',
                      style: const TextStyle(
                          fontSize: 12, color: Colors.grey),
                    ),
                  ),
                if (_payment == 'cari' && _customer.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      'Müşteri: $_customer',
                      style: const TextStyle(
                          fontSize: 12, color: Colors.grey),
                    ),
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
