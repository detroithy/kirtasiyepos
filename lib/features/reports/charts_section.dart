import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../core/database/app_db.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/money.dart';

/// Rapor grafikleri: saatlik bar + kategori pasta + 7 günlük çizgi.
/// Salt-okunur sorgular, muhasebe yazma yollarına dokunmaz.
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

  Widget _hourlyCard(_Charts c) {
    final hi =
        c.hourly.fold(0.0, (a, b) => a > b ? a : b);
    final lo = c.hourly.fold(0.0, (a, b) => a < b ? a : b);
    final maxY = (hi * 1.2).clamp(10.0, double.infinity);
    final minY = lo < 0 ? lo * 1.2 : 0.0;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 12, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Saatlik Ciro • ${fday(c.hourlyDay)}',
                style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    color: PosColors.navy)),
            const SizedBox(height: 8),
            SizedBox(
              height: 200,
              child: BarChart(
                BarChartData(
                  maxY: maxY,
                  minY: minY,
                  gridData:
                      const FlGridData(show: false),
                  borderData: FlBorderData(show: false),
                  barTouchData: BarTouchData(
                    touchTooltipData: BarTouchTooltipData(
                      getTooltipItem:
                          (group, _, rod, stack) =>
                              BarTooltipItem(
                        '${group.x}:00\n${money(rod.toY)}',
                        const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold),
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
                        reservedSize: 52,
                        getTitlesWidget: (v, _) => Text(
                          money(v).replaceAll('₺', '').trim(),
                          style: const TextStyle(
                              fontSize: 10,
                              color: PosColors.ink2),
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
                          return Text('$h',
                              style: const TextStyle(
                                  fontSize: 10,
                                  color: PosColors.ink2));
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
                            color: h >= 11 && h <= 14
                                ? PosColors.amber
                                : PosColors.navy,
                            width: 10,
                            borderRadius:
                                const BorderRadius.vertical(
                                    top: Radius.circular(
                                        3)),
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

  Widget _pieCard(_Charts c) {
    const palette = [
      PosColors.navy,
      PosColors.amber,
      PosColors.royal,
      PosColors.okTx,
      PosColors.critTx,
      PosColors.ink2,
    ];
    final entries = c.cats.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final total =
        entries.fold(0.0, (s, e) => s + e.value);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Kategori Ciro Dağılımı',
                style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: PosColors.navy)),
            const SizedBox(height: 8),
            if (entries.isEmpty)
              const Text('Veri yok.')
            else
              SizedBox(
                height: 190,
                child: PieChart(
                  PieChartData(
                    centerSpaceRadius: 34,
                    sectionsSpace: 2,
                    sections: [
                      for (var i = 0;
                          i < entries.length && i < 6;
                          i++)
                        PieChartSectionData(
                          value: entries[i].value,
                          title:
                              '%${(entries[i].value / total * 100).toStringAsFixed(0)}',
                          color: palette[i % palette.length],
                          radius: 64,
                          titleStyle: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: Colors.white),
                        ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 8),
            ...entries.take(6).map((e) => Padding(
                  padding:
                      const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: palette[entries
                                  .indexOf(e) %
                              palette.length],
                          borderRadius:
                              BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                          child: Text(e.key,
                              style: const TextStyle(
                                  fontSize: 12))),
                      Text(money(e.value),
                          style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold)),
                    ],
                  ),
                )),
          ],
        ),
      ),
    );
  }

  Widget _trendCard(_Charts c) {
    final spots = [
      for (var i = 0; i < c.trend.length; i++)
        FlSpot(i.toDouble(), c.trend[i].total),
    ];
    final spotsNet = [
      for (var i = 0; i < c.trend.length; i++)
        FlSpot(i.toDouble(), c.trend[i].net),
    ];
    final maxY = [
      ...c.trend.map((p) => p.total),
      ...c.trend.map((p) => p.net),
      10.0,
    ].reduce((a, b) => a > b ? a : b) * 1.2;
    final minY = [
      ...c.trend.map((p) => p.total),
      ...c.trend.map((p) => p.net),
      0.0,
    ].reduce((a, b) => a < b ? a : b);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 12, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('7 Günlük Trend (ciro + net kâr)',
                style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: PosColors.navy)),
            const SizedBox(height: 4),
            const Row(
              children: [
                _Legend(
                    color: PosColors.navy, label: 'Ciro'),
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
                  maxY: maxY,
                  minY: minY < 0 ? minY * 1.2 : 0,
                  gridData:
                      const FlGridData(show: false),
                  borderData: FlBorderData(show: false),
                  lineTouchData: LineTouchData(
                    touchTooltipData: LineTouchTooltipData(
                      getTooltipItems: (touched) => touched
                          .map((s) => LineTooltipItem(
                                '${fday(c.trend[s.x.toInt()].day).substring(0, 5)}\n${money(s.y)}',
                                TextStyle(
                                    color: s.bar.color ??
                                        Colors.white,
                                    fontWeight:
                                        FontWeight.bold),
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
                        reservedSize: 52,
                        getTitlesWidget: (v, _) => Text(
                          money(v)
                              .replaceAll('₺', '')
                              .trim(),
                          style: const TextStyle(
                              fontSize: 10,
                              color: PosColors.ink2),
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
                          return Text(
                            fday(c.trend[i].day)
                                .substring(0, 5),
                            style: const TextStyle(
                                fontSize: 10,
                                color: PosColors.ink2),
                          );
                        },
                      ),
                    ),
                  ),
                  lineBarsData: [
                    LineChartBarData(
                      spots: spots,
                      isCurved: true,
                      color: PosColors.navy,
                      barWidth: 3,
                      dotData:
                          const FlDotData(show: false),
                      belowBarData: BarAreaData(
                        show: true,
                        color: PosColors.navy
                            .withValues(alpha: 0.12),
                      ),
                    ),
                    LineChartBarData(
                      spots: spotsNet,
                      isCurved: true,
                      color: PosColors.okTx,
                      barWidth: 2,
                      dotData:
                          const FlDotData(show: false),
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
