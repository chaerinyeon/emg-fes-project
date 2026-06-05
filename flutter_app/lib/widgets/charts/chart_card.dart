import 'dart:collection';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../core/constants.dart';
import '../../core/models.dart';

class ChartCard extends StatelessWidget {
  final String title;
  final Queue<Sample> queue;
  final Color color;
  final String? hint;
  final List<double>? fixedRange;
  final double? baselineY;
  // 관리도(SPC) 표시 — center / UCL / LCL 모두 옵셔널.
  final double? centerY;
  final double? upperLimitY;
  final double? lowerLimitY;
  final double height;

  const ChartCard({
    super.key,
    required this.title,
    required this.queue,
    required this.color,
    this.hint,
    this.fixedRange,
    this.baselineY,
    this.centerY,
    this.upperLimitY,
    this.lowerLimitY,
    this.height = 160,
  });

  List<HorizontalLine> _buildLimitLines() {
    final lines = <HorizontalLine>[];
    HorizontalLine make(double y, Color c, String label,
        {List<int> dash = const [4, 4], double width = 1}) =>
        HorizontalLine(
          y: y,
          color: c,
          strokeWidth: width,
          dashArray: dash,
          label: HorizontalLineLabel(
            show: true,
            alignment: Alignment.topRight,
            style: TextStyle(color: c.withValues(alpha: 0.9), fontSize: 9),
            labelResolver: (_) => label,
          ),
        );
    if (baselineY != null) {
      lines.add(make(baselineY!, Colors.black38, 'baseline'));
    }
    if (centerY != null) {
      lines.add(make(centerY!, Colors.teal.shade600, 'mean', dash: [2, 3]));
    }
    if (upperLimitY != null) {
      lines.add(make(upperLimitY!, Colors.redAccent, 'UCL'));
    }
    if (lowerLimitY != null) {
      lines.add(make(lowerLimitY!, Colors.redAccent, 'LCL'));
    }
    return lines;
  }

  @override
  Widget build(BuildContext context) {
    final spots = queue.map((s) => FlSpot(s.t, s.value)).toList();
    double minX = 0, maxX = kWindowSec.toDouble();
    if (spots.isNotEmpty) {
      maxX = spots.last.x + 0.5;
      minX = maxX - kWindowSec;
    }
    double minY = 0, maxY = 1;
    if (fixedRange != null) {
      minY = fixedRange![0];
      maxY = fixedRange![1];
    } else if (spots.isNotEmpty) {
      final ys = spots.map((s) => s.y);
      final lo = ys.reduce((a, b) => a < b ? a : b);
      final hi = ys.reduce((a, b) => a > b ? a : b);
      final pad = ((hi - lo).abs() * 0.15).clamp(0.5, double.infinity);
      minY = lo - pad;
      maxY = hi + pad;
      if (baselineY != null) {
        if (baselineY! < minY) minY = baselineY! - pad;
        if (baselineY! > maxY) maxY = baselineY! + pad;
      }
      // UCL/LCL 선이 화면 밖에 있으면 보이도록 범위 확장
      for (final v in [centerY, upperLimitY, lowerLimitY]) {
        if (v == null) continue;
        if (v < minY) minY = v - pad;
        if (v > maxY) maxY = v + pad;
      }
    }

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 12, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
            if (hint != null) ...[
              const SizedBox(height: 2),
              Text(
                hint!,
                style: const TextStyle(color: Colors.black45, fontSize: 10),
              ),
            ],
            const SizedBox(height: 4),
            SizedBox(
              height: height,
              child: spots.isEmpty
                  ? const Center(
                      child: Text(
                        '대기 중',
                        style: TextStyle(color: Colors.black38, fontSize: 11),
                      ),
                    )
                  : RepaintBoundary(
                      child: LineChart(
                        LineChartData(
                          minX: minX,
                          maxX: maxX,
                          minY: minY,
                          maxY: maxY,
                          gridData: const FlGridData(show: true),
                          titlesData: const FlTitlesData(
                            leftTitles: AxisTitles(
                              sideTitles: SideTitles(
                                showTitles: true,
                                reservedSize: 38,
                              ),
                            ),
                            bottomTitles: AxisTitles(
                              sideTitles: SideTitles(
                                showTitles: true,
                                reservedSize: 20,
                              ),
                            ),
                            topTitles: AxisTitles(
                              sideTitles: SideTitles(showTitles: false),
                            ),
                            rightTitles: AxisTitles(
                              sideTitles: SideTitles(showTitles: false),
                            ),
                          ),
                          borderData: FlBorderData(show: true),
                          extraLinesData: ExtraLinesData(
                            horizontalLines: _buildLimitLines(),
                          ),
                          lineBarsData: [
                            LineChartBarData(
                              spots: spots,
                              isCurved: false,
                              color: color,
                              barWidth: 1.5,
                              dotData: FlDotData(show: spots.length < 60),
                            ),
                          ],
                        ),
                        duration: Duration.zero,
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
