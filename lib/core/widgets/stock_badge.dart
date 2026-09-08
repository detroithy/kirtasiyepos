import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../utils/money.dart';

/// Stok durum rozeti: Stokta (yeşil) / Kritik (amber) / Tükendi (kırmızı).
class StockBadge extends StatelessWidget {
  final double stock;
  final double critical;

  const StockBadge(
      {super.key, required this.stock, required this.critical});

  @override
  Widget build(BuildContext context) {
    late Color bg, bd, tx, dot;
    late String text;
    if (stock <= 0) {
      bg = PosColors.critBg;
      bd = PosColors.critBd;
      tx = PosColors.critTx;
      dot = const Color(0xFFDC2626);
      text = 'Tükendi';
    } else if (stock <= critical) {
      bg = PosColors.warnBg;
      bd = PosColors.warnBd;
      tx = PosColors.warnTx;
      dot = const Color(0xFFD97706);
      text = 'Kritik: ${fmtQty(stock)}';
    } else {
      bg = PosColors.okBg;
      bd = PosColors.okBd;
      tx = PosColors.okTx;
      dot = const Color(0xFF059669);
      text = 'Stok: ${fmtQty(stock)}';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        border: Border.all(color: bd),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration:
                BoxDecoration(color: dot, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(text,
              style: TextStyle(
                  fontSize: 11, fontWeight: FontWeight.w600, color: tx)),
        ],
      ),
    );
  }
}

/// KDV rozeti: %20, %10...
class KdvBadge extends StatelessWidget {
  final double rate;
  const KdvBadge({super.key, required this.rate});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: PosColors.infoBg,
        border: Border.all(color: PosColors.infoBd),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        'KDV ${kdvEtiket(rate)}',
        style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: PosColors.infoTx),
      ),
    );
  }
}
