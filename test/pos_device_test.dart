import 'package:flutter_test/flutter_test.dart';
import 'package:kirtasiye_app/features/pos_device/pos_device.dart';
import 'package:kirtasiye_app/features/pos_device/simulated_device.dart';
import 'package:kirtasiye_app/features/pos_device/tokenx_device.dart';

void main() {
  test('kuruş dönüşümü doğru', () {
    final req = PosSaleRequest(
      amountKurus: (199.99 * 100).round(),
      receiptNo: 'K1-0001',
      lines: const [],
      timeout: const Duration(seconds: 60),
    );
    expect(req.amountKurus, 19999);
    expect(req.amountTl, closeTo(199.99, 0.001));
  });

  test('kısım eşleme varsayılanları', () {
    final s = PosSettings();
    expect(s.deptFor(0), 1);
    expect(s.deptFor(1), 2);
    expect(s.deptFor(10), 3);
    expect(s.deptFor(20), 4);
    expect(s.deptFor(99), 4); // bilinmeyen -> 4
  });

  test('simülatör onay üretir', () async {
    final d = SimulatedDevice();
    final conn = await d.checkConnection();
    expect(conn.ok, true);
    final res = await d.sale(PosSaleRequest(
      amountKurus: 5000,
      receiptNo: 'K1-0001',
      lines: const [],
      timeout: const Duration(seconds: 60),
    ));
    expect(res.approved, true);
    expect(res.approvalCode.isNotEmpty, true);
  });

  test('simülatör sıfır tutarı reddeder', () async {
    final d = SimulatedDevice();
    final res = await d.sale(PosSaleRequest(
      amountKurus: 0,
      receiptNo: 'K1-0001',
      lines: const [],
      timeout: const Duration(seconds: 60),
    ));
    expect(res.approved, false);
  });

  test('TokenX payload kuruş + kısım içerir', () {
    final s = PosSettings();
    final t = TokenXDevice(settings: s);
    final p = t.buildPayload(PosSaleRequest(
      amountKurus: 10050,
      receiptNo: 'K1-0007',
      lines: const [
        PosLine(
            name: 'Kalem', qty: 2, unitPriceTl: 50.25, kdvDept: 4),
      ],
      timeout: const Duration(seconds: 60),
    ));
    expect(p['amountKurus'], 10050);
    expect(p['receiptNo'], 'K1-0007');
    expect((p['lines'] as List).single['kdvDept'], 4);
  });

  test('yol girilmeden TokenX satış yapmaz', () async {    final s = PosSettings(driver: 'tokenx', salePath: '');
    final t = TokenXDevice(settings: s);
    bool threw = false;
    try {
      await t.sale(PosSaleRequest(
        amountKurus: 100,
        receiptNo: 'K1-1',
        lines: const [],
        timeout: const Duration(seconds: 5),
      ));
    } on PosNotConfigured {
      threw = true;
    }
    expect(threw, true);
  });

  test('bypass varsayılanı kapalı, manuel sonuç işaretli', () {
    expect(PosSettings().bypass, false);
    const r = PosResult(approved: true, manual: true);
    expect(r.approved, true);
    expect(r.manual, true);
    expect(r.uncertain, false);
  });
}
