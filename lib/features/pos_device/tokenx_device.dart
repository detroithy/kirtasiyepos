import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'pos_device.dart';

/// TokenX Connect (Beko 300TR kablolu) HTTP sürücüsü.
///
/// Gerçekler:
/// - Sürücü (TokenX Connect Wired) PC'de servis olarak çalışır ve
///   `http://pc-ip:9001/swagger/ui` adresinde Swagger yayınlar.
/// - checkConnection(): TCP soketiyle servis AYAKTA MI diye bakar
///   (protokol bilgisi gerekmez, bugün GERÇEKTEN çalışır).
/// - sale(): istek modelini eksiksiz kurar (kuruş + kısım eşlemeli
///   satırlar), ancak UÇ NOKTA YOLU bayiden alınacak Swagger'dan
///   Ayarlar > POS Cihazı > "Satış uç noktası" alanına yazılmadan
///   gönderim yapmaz — uydurma URL'ye istek atmak YASAK.
///   Yol girilince standart JSON POST atar, JSON yanıt bekler.
class TokenXDevice implements PosDevice {
  final PosSettings settings;
  TokenXDevice({required this.settings});

  @override
  String get name => 'TokenX Connect (Beko 300TR)';

  Uri get _base => Uri.parse(settings.baseUrl);

  @override
  Future<PosConnection> checkConnection() async {
    try {
      final socket = await Socket.connect(
        _base.host,
        _base.hasPort ? _base.port : 80,
        timeout: const Duration(seconds: 3),
      );
      socket.destroy();
      return PosConnection(
          true, 'TokenX servisine ulaşıldı (${settings.baseUrl}).');
    } catch (e) {
      return PosConnection(false,
          'Ulaşılamadı: önce TokenX Connect sürücüsünü kurun ve cihazda Harici Mod (GMP3 > TOKENX CONNECT) açın. Detay: $e');
    }
  }

  /// Satış isteği modeli (kuruş + kısım). Uç nokta yolu ayarlardan gelir.
  Map<String, dynamic> buildPayload(PosSaleRequest req) => {
        'amountKurus': req.amountKurus,
        'amountTl': req.amountTl,
        'receiptNo': req.receiptNo,
        'lines': [
          for (final l in req.lines)
            {
              'name': l.name,
              'qty': l.qty,
              'unitPriceTl': l.unitPriceTl,
              'kdvDept': l.kdvDept,
            }
        ],
      };

  @override
  Future<PosResult> sale(PosSaleRequest req) async {
    final path = settings.salePath.trim();
    if (path.isEmpty) {
      throw const PosNotConfigured(
          'Satış uç noktası girilmedi. Ayarlar > POS Cihazı alanından, '
          'bayinin verdiği Swagger (http://bilgisayar-ip:9001/swagger/ui) '
          'üzerindeki satış metodunun yolunu yazın (örn. /api/sale).');
    }
    final url = Uri.parse('${settings.baseUrl}$path');
    http.Response resp;
    try {
      resp = await http
          .post(
            url,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(buildPayload(req)),
          )
          .timeout(req.timeout);
    } on TimeoutException {
      return const PosResult.declined(
          'Cihaz yanıt vermedi (zaman aşımı). Kart çekilmiş olabilir — cihaz fişini kontrol edin, çift tahsilata dikkat!');
    } catch (e) {
      return PosResult.declined('Bağlantı hatası: $e');
    }
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      return PosResult.declined(
          'Cihaz HTTP ${resp.statusCode}: ${resp.body}');
    }
    try {
      final m = jsonDecode(resp.body) as Map<String, dynamic>;
      final approved = (m['approved'] == true) ||
          (m['status'] == 'approved') ||
          (m['result'] == 'approved');
      if (!approved) {
        return PosResult.declined(
            '${m['message'] ?? m['error'] ?? 'Cihaz reddetti'}');
      }
      return PosResult(
        approved: true,
        approvalCode:
            '${m['approvalCode'] ?? m['approval_code'] ?? ''}',
        fiscalNo: '${m['fiscalNo'] ?? m['fiscal_no'] ?? ''}',
        message: '${m['message'] ?? 'Onaylandı'}',
      );
    } catch (e) {
      return PosResult.declined(
          'Cihaz yanıtı anlaşılamadı: ${resp.body}');
    }
  }
}

class PosNotConfigured implements Exception {
  final String message;
  const PosNotConfigured(this.message);
  @override
  String toString() => message;
}
