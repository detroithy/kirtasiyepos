import 'pos_device.dart';

/// Gerçek cihaz gelene kadar birebir akış simülasyonu:
/// 2 sn bekler, onay üretir. İptal edilebilir.
class SimulatedDevice implements PosDevice {
  @override
  String get name => 'Simülatör (Beko 300TR provası)';

  @override
  Future<PosConnection> checkConnection() async {
    await Future.delayed(const Duration(milliseconds: 300));
    return const PosConnection(true, 'Simülatör her zaman bağlıdır.');
  }

  @override
  Future<PosResult> sale(PosSaleRequest req) async {
    if (req.amountKurus <= 0) {
      return const PosResult.declined('Tutar sıfırdan büyük olmalı.');
    }
    // İptal edilebilir bekleme (diyalog kapatınca token düşer):
    await Future.delayed(const Duration(seconds: 2));
    final stamp = DateTime.now().millisecondsSinceEpoch % 1000000;
    return PosResult(
      approved: true,
      approvalCode: 'SIM-$stamp',
      fiscalNo: 'SIM-FIS-$stamp',
      message: 'Simülatör onayı (mali fiş YOK — prova amaçlı)',
    );
  }
}
