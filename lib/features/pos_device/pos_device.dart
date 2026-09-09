import 'package:shared_preferences/shared_preferences.dart';

/// Beko 300TR (Ziraat) POS cihazı soyutlaması.
/// Gerçek sürücü TokenX Connect servisidir; donanım/lisans hazır
/// olana kadar simülatörle birebir aynı akış çalışır.
abstract class PosDevice {
  String get name;
  Future<PosConnection> checkConnection();
  Future<PosResult> sale(PosSaleRequest req);
}

/// Cihaza gönderilecek satış: tutar + KDV kısım eşlemeli satırlar.
class PosSaleRequest {
  /// Kuruş cinsinden toplam (cihaz форматı).
  final int amountKurus;
  final String receiptNo;
  final List<PosLine> lines;
  final Duration timeout;
  const PosSaleRequest({
    required this.amountKurus,
    required this.receiptNo,
    required this.lines,
    required this.timeout,
  });

  double get amountTl => amountKurus / 100.0;
}

class PosLine {
  final String name;
  final double qty;
  final double unitPriceTl;

  /// KDV oranına karşılık cihaz kısım (departman) numarası.
  final int kdvDept;
  const PosLine({
    required this.name,
    required this.qty,
    required this.unitPriceTl,
    required this.kdvDept,
  });
}

class PosConnection {
  final bool ok;
  final String message;
  const PosConnection(this.ok, this.message);
}

class PosResult {
  final bool approved;

  /// true ise tutar cihazdan DEĞİL elle tahsil edildi (fişte izi olur).
  final bool manual;

  /// true ise para hareketi belirsiz (zaman aşımı) — çift tahsilat
  /// riski için kullanıcı uyarılmalı, kayıt yine de tutulabilir.
  final bool uncertain;
  final String approvalCode;
  final String fiscalNo;
  final String message;
  const PosResult({
    required this.approved,
    this.manual = false,
    this.uncertain = false,
    this.approvalCode = '',
    this.fiscalNo = '',
    this.message = '',
  });

  const PosResult.declined(this.message)
      : approved = false,
        manual = false,
        uncertain = false,
        approvalCode = '',
        fiscalNo = '';
}

/// Cihaz ayarları (Ayarlar > POS Cihazı ekranından).
class PosSettings {
  static const kDriver = 'pos_driver'; // simulator | tokenx
  static const kBaseUrl = 'pos_base_url';
  static const kTimeoutSec = 'pos_timeout_sec';
  static const kSalePath = 'pos_sale_path';
  static const kBypass = 'pos_bypass';
  static const kDeptPrefix = 'pos_dept_'; // +0/1/10/20

  final String driver;
  final String baseUrl;
  final int timeoutSec;
  final String salePath;

  /// true ise kart satışları cihaza SORULMADAN manuel kaydedilir
  /// (fişte pos_status='manual' izi olur). Acil durum şalteri.
  final bool bypass;
  final Map<double, int> deptByKdv;

  PosSettings({
    this.driver = 'simulator',
    this.baseUrl = 'http://127.0.0.1:9001',
    this.timeoutSec = 60,
    this.salePath = '',
    this.bypass = false,
    Map<double, int>? deptByKdv,
  }) : deptByKdv = deptByKdv ?? {0.0: 1, 1.0: 2, 10.0: 3, 20.0: 4};

  int deptFor(double kdvRate) => deptByKdv[kdvRate] ?? 4;

  static Future<PosSettings> load() async {
    final p = await SharedPreferences.getInstance();
    int dept(String k, int fb) => p.getInt('$kDeptPrefix$k') ?? fb;
    return PosSettings(
      driver: p.getString(kDriver) ?? 'simulator',
      baseUrl: p.getString(kBaseUrl) ?? 'http://127.0.0.1:9001',
      timeoutSec: p.getInt(kTimeoutSec) ?? 60,
      salePath: p.getString(kSalePath) ?? '',
      bypass: p.getBool(kBypass) ?? false,
      deptByKdv: {
        0: dept('0', 1),
        1: dept('1', 2),
        10: dept('10', 3),
        20: dept('20', 4),
      },
    );
  }

  Future<void> save({
    String? driver,
    String? baseUrl,
    int? timeoutSec,
    String? salePath,
    bool? bypass,
    Map<double, int>? deptByKdv,
  }) async {
    final p = await SharedPreferences.getInstance();
    if (driver != null) await p.setString(kDriver, driver);
    if (bypass != null) await p.setBool(kBypass, bypass);
    if (baseUrl != null) {
      await p.setString(
          kBaseUrl, baseUrl.trim().replaceAll(RegExp(r'/+$'), ''));
    }
    if (timeoutSec != null) await p.setInt(kTimeoutSec, timeoutSec);
    if (salePath != null) {
      await p.setString(kSalePath, salePath.trim());
    }
    if (deptByKdv != null) {
      for (final e in deptByKdv.entries) {
        await p.setInt(
            '$kDeptPrefix${e.key.toInt()}', e.value);
      }
    }
  }
}
