import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import 'admin_gate.dart';
import 'audit_screen.dart';
import 'bulk_price_screen.dart';
import 'data_export_screen.dart';
import 'z_report_screen.dart';

/// Yönetim Paneli: denetim + yönetim işlemleri tek çatı.
/// PIN kapısından geçilerek açılır.
class AdminHub extends StatelessWidget {
  const AdminHub({super.key});

  @override
  Widget build(BuildContext context) {
    final items = [
      _Item('Gün Sonu (Z)', 'Günlük kapanış raporu + yazdır',
          Icons.receipt_long, PosColors.navy, () {
        Navigator.push(context,
            MaterialPageRoute(builder: (_) => const ZReportScreen()));
      }),
      _Item('Denetim İzi', 'Tüm hareketlerin kronolojik dökümü',
          Icons.history, PosColors.infoTx, () {
        Navigator.push(context,
            MaterialPageRoute(builder: (_) => const AuditScreen()));
      }),
      _Item('Toplu Fiyat', 'Kategoriye/mağazaya % zam-indirim',
          Icons.percent, PosColors.amberDark, () {
        Navigator.push(context,
            MaterialPageRoute(builder: (_) => const BulkPriceScreen()));
      }),
      _Item('Veri Aktarım', 'Tabloları CSV indir (Excel açar)',
          Icons.download, PosColors.okTx, () {
        Navigator.push(context,
            MaterialPageRoute(builder: (_) => const DataExportScreen()));
      }),
      _Item('PIN Değiştir', 'Yönetici giriş şifresi', Icons.key,
          PosColors.ink2, () {
        changeAdminPin(context);
      }),
    ];
    return Scaffold(
      appBar:
          AppBar(title: const Text('KırtasiyePOS • Yönetim')),
      body: GridView.count(
        crossAxisCount:
            MediaQuery.of(context).size.width > 700 ? 3 : 2,
        padding: const EdgeInsets.all(12),
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 1.25,
        children: items
            .map((e) => Card(
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: e.onTap,
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment:
                            CrossAxisAlignment.start,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: e.color.withValues(alpha: 0.12),
                              borderRadius:
                                  BorderRadius.circular(8),
                            ),
                            child: Icon(e.icon,
                                color: e.color, size: 24),
                          ),
                          const Spacer(),
                          Text(e.title,
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15)),
                          Text(e.sub,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 12,
                                  color: PosColors.ink2)),
                        ],
                      ),
                    ),
                  ),
                ))
            .toList(),
      ),
    );
  }
}

class _Item {
  final String title, sub;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  _Item(this.title, this.sub, this.icon, this.color, this.onTap);
}
