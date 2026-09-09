import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../core/database/app_db.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/money.dart';

/// Okunabilirlik paketi (kullanıcı geri bildirimi):
/// ızgara neredeyse görünmez tutulur, eksen yazıları koyu + kalın
/// basılır ki grid çizgileriyle çakışmasın.
FlLine _faintGrid(double v) => FlLine(
      color: PosColors.navy.withValues(alpha: 0.07),
      strokeWidth: 1,
    );

const TextStyle _axisStyle = TextStyle(
  fontSize: 11,
  fontWeight: FontWeight.w600,
  color: PosColors.ink,
);

/// Rapor grafikleri (modern stil): saatlik bar + kategori donut +
/// 7 günlük çizgi. Salt-okunur sorgular.
class ChartsSection extends StatelessWidget {
  final AppDb db;
  final DateTime start;
  final DateTime end;
  const ChartsSection(
      {super.key,
      required this.db,
      required this.start,
      required this.end});

  Future<_Charts> _load() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    // Saatlik: aralık bugünü kapsıyorsa bugün, yoksa bitiş günü.
    final hourlyDay = !end.isBefore(today) &&
            !start.isAfter(today.add(const Duration(days: 1)))
        ? today
        : DateTime(end.year, end.month, end.day);
    final daySales = await db.salesOnDay(hourlyDay);
    final cats = await db.categoryRevenue(start, end);
    final trend = await db.last7Days();
    return _Charts(
      hourlyDay: hourlyDay,
      hourly: hourlyBuckets(daySales, hourlyDay),
      cats: cats,
      trend: trend,
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_Charts>(
      future: _load(),
      builder: (_, snap) {
        if (snap.hasError) {
          return Card(
              child: Padding(
                  padding: const EdgeInsets.all(16),
                  child:
                      Text('Grafikler yüklenemedi: ${snap.error}')));
        }
        if (!snap.hasData) {
          return const Card(
              child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(
                      child: CircularProgressIndicator())));
        }
        final c = snap.data!;
        final empty = c.hourly.every((v) => v == 0) &&
            c.cats.isEmpty &&
            c.trend.every((p) => p.total == 0);
        if (empty) {
          return const Card(
              child: Padding(
                  padding: EdgeInsets.all(16),
                  child:
                      Text('Bu aralıkta grafik çizilecek satış yok.')));
        }
        return LayoutBuilder(
          builder: (_, cons) {
            final wide = cons.maxWidth > 700;
            final pie = _pieCard(c);
            final trend = _trendCard(c);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _hourlyCard(c),
                const SizedBox(height: 12),
                if (wide)
                  Row(
                    crossAxisAlignment:
                        CrossAxisAlignment.start,
                    children: [
                      Expanded(child: pie),
                      const SizedBox(width: 12),
                      Expanded(child: trend),
                    ],
                  )
                else ...[
                  pie,
                  const SizedBox(height: 12),
                  trend,
                ],
              ],
            );
          },
        );
      },
    );
  }

  // ---------- Ortak başlık ----------

  Widget _header(IconData icon, Color color, String title,
      String sub, Widget trailing) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, size: 20, color: color),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: PosColors.navy)),
              Text(sub,
                  style: const TextStyle(
                      fontSize: 12, color: PosColors.ink2)),
            ],
          ),
        ),
        trailing,
      ],
    );
  }

  Widget _chip(String text, Color color) {
    return Container(
      padding:
          const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(text,
          style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: color)),
    );
  }

  // ---------- Saatlik bar ----------

  Widget _hourlyCard(_Charts c) {
    final hi =
        c.hourly.fold(0.0, (a, b) => a > b ? a : b);
    final lo = c.hourly.fold(0.0, (a, b) => a < b ? a : b);
    final maxY = (hi * 1.25).clamp(10.0, double.infinity);
    final minY = lo < 0 ? lo * 1.25 : 0.0;
    final peakH =
        c.hourly.indexOf(c.hourly.reduce((a, b) => a > b ? a : b));
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(
              Icons.bar_chart,
              PosColors.navy,
              'Saatlik Ciro',
              fday(c.hourlyDay),
              hi > 0
                  ? _chip(
                      'Zirve $peakH:00 • ${money(hi)}',
                      PosColors.amberDark)
                  : const SizedBox.shrink(),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 210,
              child: BarChart(
                BarChartData(
                  maxY: maxY,
                  minY: minY,
                  gridData: FlGridData(
                    show: true,
                    drawVerticalLine: false,
                    getDrawingHorizontalLine: _faintGrid,
                  ),
                  borderData: FlBorderData(show: false),
                  barTouchData: BarTouchData(
                    touchTooltipData: BarTouchTooltipData(
                      getTooltipColor: (_) => PosColors.navy,
                      tooltipBorderRadius:
                          BorderRadius.circular(8),
                      tooltipPadding:
                          const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 6),
                      getTooltipItem:
                          (group, _, rod, stack) =>
                              BarTooltipItem(
                        '${group.x}:00 – ${group.x + 1}:00\n${money(rod.toY)}',
                        const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 13),
                      ),
                    ),
                  ),
                  titlesData: FlTitlesData(
                    topTitles: const AxisTitles(
                        sideTitles:
                            SideTitles(showTitles: false)),
                    rightTitles: const AxisTitles(
                        sideTitles:
                            SideTitles(showTitles: false)),
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 46,
                        getTitlesWidget: (v, _) => Text(
                          moneyCompact(v),
                          style: _axisStyle,
                        ),
                      ),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        getTitlesWidget: (v, _) {
                          final h = v.toInt();
                          if (h < 0 ||
                              h > 23 ||
                              h % 3 != 0) {
                            return const SizedBox.shrink();
                          }
                          return Padding(
                            padding:
                                const EdgeInsets.only(top: 4),
                            child: Text('$h:00',
                                style: _axisStyle),
                          );
                        },
                      ),
                    ),
                  ),
                  barGroups: [
                    for (var h = 0; h < 24; h++)
                      BarChartGroupData(
                        x: h,
                        barRods: [
                          BarChartRodData(
                            toY: c.hourly[h],
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: h == peakH && hi > 0
                                  ? [
                                      PosColors.amber,
                                      PosColors.amberDark
                                    ]
                                  : [
                                      PosColors.royal,
                                      PosColors.navy
                                    ],
                            ),
                            width: 12,
                            borderRadius:
                                const BorderRadius.vertical(
                                    top: Radius.circular(
                                        4)),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------- Kategori donut ----------

  static const _palette = [
    PosColors.navy,
    PosColors.amber,
    PosColors.royal,
    PosColors.okTx,
    PosColors.critTx,
    PosColors.ink2,
  ];

  Widget _pieCard(_Charts c) {
    final entries = c.cats.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final total =
        entries.fold(0.0, (s, e) => s + e.value);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(
              Icons.pie_chart,
              PosColors.amberDark,
              'Kategori Cirosu',
              '${entries.length} kategori',
              total > 0
                  ? _chip(
                      'Toplam ${money(total)}', PosColors.navy)
                  : const SizedBox.shrink(),
            ),
            const SizedBox(height: 8),
            if (entries.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('Veri yok.'),
              )
            else ...[
              SizedBox(
                height: 200,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    PieChart(
                      PieChartData(
                        centerSpaceRadius: 58,
                        sectionsSpace: 3,
                        sections: [
                          for (var i = 0;
                              i < entries.length && i < 6;
                              i++)
                            _pieSlice(entries, total, i),
                        ],
                      ),
                    ),
                    SizedBox(
                      // Deliğin içine sığmaya zorla: taşma yok.
                      width: 104,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('TOPLAM',
                              style: TextStyle(
                                  fontSize: 10,
                                  color: PosColors.ink2,
                                  letterSpacing: 1)),
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(money(total),
                                maxLines: 1,
                                style: const TextStyle(
                                    fontSize: 19,
                                    fontWeight:
                                        FontWeight.w800,
                                    color: PosColors.navy)),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              ...entries.take(6).map((e) {
                final i = entries.indexOf(e);
                final share =
                    total > 0 ? e.value / total : 0.0;
                return Padding(
                  padding:
                      const EdgeInsets.symmetric(vertical: 4),
                  child: Column(
                    crossAxisAlignment:
                        CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              color: _palette[
                                  i % _palette.length],
                              borderRadius:
                                  BorderRadius.circular(3),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                              child: Text(e.key,
                                  style: const TextStyle(
                                      fontSize: 13))),
                          Text(
                              '%${(share * 100).toStringAsFixed(0)}',
                              style: const TextStyle(
                                  fontSize: 12,
                                  color: PosColors.ink2)),
                          const SizedBox(width: 8),
                          Text(money(e.value),
                              style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight:
                                      FontWeight.bold)),
                        ],
                      ),
                      const SizedBox(height: 4),
                      ClipRRect(
                        borderRadius:
                            BorderRadius.circular(3),
                        child: LinearProgressIndicator(
                          value: share.clamp(0.0, 1.0),
                          minHeight: 5,
                          backgroundColor:
                              PosColors.cardBorder,
                          valueColor:
                              AlwaysStoppedAnimation(
                                  _palette[
                                      i % _palette.length]),
                        ),
                      ),
                    ],
                  ),
                );
              }),
            ],
          ],
        ),
      ),
    );
  }

  /// Pasta dilimi: açık zeminde (amber) koyu yazı, koyuda beyaz.
  /// Böylece yüzde her dilimde okunur.
  PieChartSectionData _pieSlice(
      List<MapEntry<String, double>> entries, double total, int i) {
    final bg = _palette[i % _palette.length];
    final onLight = bg == PosColors.amber;
    final share = total > 0 ? entries[i].value / total : 0.0;
    return PieChartSectionData(
      value: entries[i].value,
      // Minik dilimde (%6 altı) etiket eziliyor — lejantta zaten var:
      title: share < 0.06
          ? ''
          : '%${(share * 100).toStringAsFixed(0)}',
      color: bg,
      radius: 62,
      titleStyle: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.bold,
          color: onLight ? PosColors.navy : Colors.white),
    );
  }

  // ---------- 7 günlük çizgi ----------
  Widget _trendCard(_Charts c) {
    final spots = [
      for (var i = 0; i < c.trend.length; i++)
        FlSpot(i.toDouble(), c.trend[i].total),
    ];
    final spotsNet = [
      for (var i = 0; i < c.trend.length; i++)
        FlSpot(i.toDouble(), c.trend[i].net),
    ];
    final allY = [
      ...c.trend.map((p) => p.total),
      ...c.trend.map((p) => p.net),
    ];
    final hi =
        allY.fold(10.0, (a, b) => a > b ? a : b) * 1.2;
    final lo =
        allY.fold(0.0, (a, b) => a < b ? a : b);
    final weekTotal =
        c.trend.fold(0.0, (s, p) => s + p.total);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(
              Icons.show_chart,
              PosColors.okTx,
              '7 Günlük Trend',
              'Ciro + net kâr',
              _chip('7 gün: ${money(weekTotal)}',
                  PosColors.okTx),
            ),
            const SizedBox(height: 8),
            const Row(
              children: [
                _Legend(color: PosColors.navy, label: 'Ciro'),
                SizedBox(width: 12),
                _Legend(
                    color: PosColors.okTx, label: 'Net kâr'),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 200,
              child: LineChart(
                LineChartData(
                  maxY: hi,
                  minY: lo < 0 ? lo * 1.2 : 0,
                  gridData: FlGridData(
                    show: true,
                    drawVerticalLine: false,
                    getDrawingHorizontalLine: _faintGrid,
                  ),
                  borderData: FlBorderData(show: false),
                  lineTouchData: LineTouchData(
                    touchTooltipData: LineTouchTooltipData(
                      getTooltipColor: (_) => PosColors.navy,
                      tooltipBorderRadius:
                          BorderRadius.circular(8),
                      getTooltipItems: (touched) => touched
                          .map((s) => LineTooltipItem(
                                '${fday(c.trend[s.x.toInt()].day).substring(0, 5)}\n${money(s.y)}',
                                const TextStyle(
                                    color: Colors.white,
                                    fontWeight:
                                        FontWeight.bold,
                                    fontSize: 13),
                              ))
                          .toList(),
                    ),
                  ),
                  titlesData: FlTitlesData(
                    topTitles: const AxisTitles(
                        sideTitles:
                            SideTitles(showTitles: false)),
                    rightTitles: const AxisTitles(
                        sideTitles:
                            SideTitles(showTitles: false)),
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 46,
                        getTitlesWidget: (v, _) => Text(
                          moneyCompact(v),
                          style: _axisStyle,
                        ),
                      ),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        getTitlesWidget: (v, _) {
                          final i = v.toInt();
                          if (i < 0 ||
                              i >= c.trend.length) {
                            return const SizedBox.shrink();
                          }
                          return Padding(
                            padding:
                                const EdgeInsets.only(top: 4),
                            child: Text(
                              fday(c.trend[i].day)
                                  .substring(0, 5),
                              style: _axisStyle,
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  lineBarsData: [
                    LineChartBarData(
                      spots: spots,
                      isCurved: true,
                      preventCurveOverShooting: true,
                      color: PosColors.navy,
                      barWidth: 3,
                      dotData: const FlDotData(show: true),
                      belowBarData: BarAreaData(
                        show: true,
                        color: PosColors.navy
                            .withValues(alpha: 0.10),
                      ),
                    ),
                    LineChartBarData(
                      spots: spotsNet,
                      isCurved: true,
                      preventCurveOverShooting: true,
                      color: PosColors.okTx,
                      barWidth: 2,
                      dotData: const FlDotData(show: true),
                      belowBarData: BarAreaData(
                        show: true,
                        color: PosColors.okTx
                            .withValues(alpha: 0.08),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Charts {
  final DateTime hourlyDay;
  final List<double> hourly;
  final Map<String, double> cats;
  final List<DayPoint> trend;
  const _Charts({
    required this.hourlyDay,
    required this.hourly,
    required this.cats,
    required this.trend,
  });
}

class _Legend extends StatelessWidget {
  final Color color;
  final String label;
  const _Legend({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 14,
          height: 4,
          decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(2)),
        ),
        const SizedBox(width: 4),
        Text(label,
            style: const TextStyle(
                fontSize: 11, color: PosColors.ink2)),
      ],
    );
  }
}
