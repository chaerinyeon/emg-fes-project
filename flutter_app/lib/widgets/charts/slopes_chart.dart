import 'dart:collection';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../core/constants.dart';
import '../../core/models.dart';

class SlopesChart extends StatelessWidget {
  final Queue<Sample> rmsSlopeQueue;
  final Queue<Sample> mdfSlopeQueue;
  // 관리도(값 차트)에서 derive 한 슬로프 등가 임계.
  //   rmsSlopeUcl = (UCL_rms - mean_rms) / mean_rms * 100   (≈ 3σ/mean × 100)
  //   mdfSlopeLcl = (LCL_mdf - mean_mdf) / mean_mdf * 100
  // 8점 학습 완료 전엔 null → 선 안 그림.
  final double? rmsSlopeUcl;
  final double? mdfSlopeLcl;

  const SlopesChart({
    super.key,
    required this.rmsSlopeQueue,
    required this.mdfSlopeQueue,
    this.rmsSlopeUcl,
    this.mdfSlopeLcl,
  });

  List<HorizontalLine> _buildLimitLines() {
    final lines = <HorizontalLine>[
      HorizontalLine(y: 0, color: Colors.black26, strokeWidth: 1),
    ];
    if (rmsSlopeUcl != null) {
      lines.add(HorizontalLine(
        y: rmsSlopeUcl!,
        color: cThr.withValues(alpha: 0.7),
        strokeWidth: 1.2,
        dashArray: [5, 4],
        label: HorizontalLineLabel(
          show: true,
          alignment: Alignment.topRight,
          style: TextStyle(color: cThr, fontSize: 9),
          labelResolver: (_) =>
              'RMS UCL +${rmsSlopeUcl!.toStringAsFixed(1)}%',
        ),
      ));
    }
    if (mdfSlopeLcl != null) {
      lines.add(HorizontalLine(
        y: mdfSlopeLcl!,
        color: cThr.withValues(alpha: 0.7),
        strokeWidth: 1.2,
        dashArray: [5, 4],
        label: HorizontalLineLabel(
          show: true,
          alignment: Alignment.bottomRight,
          style: TextStyle(color: cThr, fontSize: 9),
          labelResolver: (_) =>
              'MDF LCL ${mdfSlopeLcl!.toStringAsFixed(1)}%',
        ),
      ));
    }
    return lines;
  }

  Widget _legendDot(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 14,
          height: 3,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: const TextStyle(color: Colors.black54, fontSize: 10),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final rsSpots = rmsSlopeQueue.map((s) => FlSpot(s.t, s.value)).toList();
    final msSpots = mdfSlopeQueue.map((s) => FlSpot(s.t, s.value)).toList();
    final all = [...rsSpots, ...msSpots];

    double minX = 0, maxX = kWindowSec.toDouble();
    if (all.isNotEmpty) {
      maxX = all.map((s) => s.x).reduce((a, b) => a > b ? a : b) + 0.5;
      minX = maxX - kWindowSec;
    }
    double minY = -30, maxY = 30;
    if (all.isNotEmpty) {
      final lo = all.map((s) => s.y).reduce((a, b) => a < b ? a : b);
      final hi = all.map((s) => s.y).reduce((a, b) => a > b ? a : b);
      minY = lo < -30 ? lo - 5 : -30;
      maxY = hi > 30 ? hi + 5 : 30;
    }
    // 관리도 derive 임계선이 범위 밖이면 보이게 확장
    if (rmsSlopeUcl != null && rmsSlopeUcl! > maxY) maxY = rmsSlopeUcl! + 5;
    if (mdfSlopeLcl != null && mdfSlopeLcl! < minY) minY = mdfSlopeLcl! - 5;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 12, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _legendDot(cRmsSlope, 'RMS slope %'),
                const SizedBox(width: 14),
                _legendDot(cMdfSlope, 'MDF slope %'),
                const SizedBox(width: 14),
                _legendDot(cThr, 'CC-derive 임계'),
              ],
            ),
            const SizedBox(height: 2),
            const Text(
              '30초 선형회귀 변화율. 점선은 관리도 UCL/LCL을 슬로프 등가로 환산한 값 '
              '(= 3σ/mean × 100). 8점 학습 후 자동 표시.',
              style: TextStyle(color: Colors.black45, fontSize: 10),
            ),
            const SizedBox(height: 4),
            SizedBox(
              height: 160,
              child: (rsSpots.isEmpty && msSpots.isEmpty)
                  ? const Center(
                      child: Text(
                        '대기 중 (30초치 모일 때까지)',
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
                              spots: rsSpots,
                              isCurved: false,
                              color: cRmsSlope,
                              barWidth: 1.8,
                              dotData: const FlDotData(show: false),
                            ),
                            LineChartBarData(
                              spots: msSpots,
                              isCurved: false,
                              color: cMdfSlope,
                              barWidth: 1.8,
                              dotData: const FlDotData(show: false),
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
