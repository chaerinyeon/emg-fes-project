import 'package:flutter/material.dart';

import '../../core/constants.dart';
import '../../core/models.dart';

/// 관리도(SPC) 기반 피로 트리거 표시.
/// - 운동 초반 8점으로 학습한 mean ± 3σ 가 임계치.
/// - 조건1: 현재 RMS > UCL
/// - 조건2: 현재 MDF < LCL
class FatigueTriggerPanel extends StatelessWidget {
  final AppStatus status;

  const FatigueTriggerPanel({super.key, required this.status});

  Widget _condRow({
    required String label,
    required String value,
    required double progress,    // 0..1.5 (1.0 = 임계 도달)
    required bool met,
    required bool established,
    required Color color,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(
              met
                  ? Icons.check_circle
                  : (established
                      ? Icons.radio_button_unchecked
                      : Icons.hourglass_empty),
              size: 16,
              color: met
                  ? color
                  : (established ? Colors.black38 : Colors.black26),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: met ? color : Colors.black54,
                  fontSize: 12,
                ),
              ),
            ),
            Text(
              value,
              style: TextStyle(
                color: met ? color : Colors.black54,
                fontSize: 13,
                fontWeight: FontWeight.bold,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: Stack(
            children: [
              Container(height: 6, color: Colors.black12),
              FractionallySizedBox(
                widthFactor: (progress / 1.5).clamp(0.0, 1.0),
                child: Container(
                  height: 6,
                  color: met ? color : color.withValues(alpha: 0.4),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final rmsMean = status.rmsCcMean;
    final ucl = status.rmsCcUcl;
    final mdfMean = status.mdfCcMean;
    final lcl = status.mdfCcLcl;
    final rms = status.lastRms;
    final mdf = status.lastMdf;

    final rmsEstablished = ucl != null && rmsMean != null;
    final mdfEstablished = lcl != null && mdfMean != null;

    final rmsHigh = rmsEstablished && rms > ucl;
    final mdfLow = mdfEstablished && mdf < lcl;

    // progress: mean → 임계(UCL/LCL) 사이 비율 (1.0 = 도달)
    double rmsProgress = 0;
    if (rmsEstablished && (ucl - rmsMean).abs() > 0.01) {
      rmsProgress = ((rms - rmsMean) / (ucl - rmsMean)).clamp(0.0, 1.5);
    }
    double mdfProgress = 0;
    if (mdfEstablished && (mdfMean - lcl).abs() > 0.01) {
      mdfProgress = ((mdfMean - mdf) / (mdfMean - lcl)).clamp(0.0, 1.5);
    }

    final rmsLabel = rmsEstablished
        ? 'RMS > UCL (mean ${rmsMean.toStringAsFixed(1)} · UCL ${ucl.toStringAsFixed(1)})'
        : 'RMS 관리도 학습 중 (${status.rmsCcSamples}/8)';
    final mdfLabel = mdfEstablished
        ? 'MDF < LCL (mean ${mdfMean.toStringAsFixed(1)} · LCL ${lcl.toStringAsFixed(1)})'
        : 'MDF 관리도 학습 중 (${status.mdfCcSamples}/8)';

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _condRow(
              label: rmsLabel,
              value: rmsEstablished ? rms.toStringAsFixed(1) : '—',
              progress: rmsProgress,
              met: rmsHigh,
              established: rmsEstablished,
              color: cRmsSlope,
            ),
            const SizedBox(height: 10),
            _condRow(
              label: mdfLabel,
              value: mdfEstablished ? mdf.toStringAsFixed(1) : '—',
              progress: mdfProgress,
              met: mdfLow,
              established: mdfEstablished,
              color: cMdfSlope,
            ),
            const Divider(height: 22, color: Colors.black26),
            Row(
              children: [
                const Expanded(
                  child: Text(
                    '연속 만족 카운트',
                    style: TextStyle(color: Colors.black54, fontSize: 13),
                  ),
                ),
                Text(
                  '${status.engineConsecutive} / ${status.consecutiveTrigger}',
                  style: TextStyle(
                    color: status.engineConsecutive >= status.consecutiveTrigger
                        ? cThr
                        : Colors.black87,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(status.consecutiveTrigger, (i) {
                final filled = i < status.engineConsecutive;
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: filled
                          ? (i + 1 == status.consecutiveTrigger
                                ? cThr
                                : Colors.orange.shade700)
                          : Colors.black12,
                      border: Border.all(
                        color: filled
                            ? (i + 1 == status.consecutiveTrigger
                                  ? cThr
                                  : Colors.orange.shade700)
                            : Colors.black26,
                      ),
                    ),
                  ),
                );
              }),
            ),
            const SizedBox(height: 6),
            Text(
              rmsHigh && mdfLow
                  ? (status.engineConsecutive >= status.consecutiveTrigger
                        ? '트리거 발동 — FES 자동 정지'
                        : '두 조건 만족 — 카운터 누적 중')
                  : (rmsHigh || mdfLow ? '한 조건만 만족' : '조건 미충족'),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: rmsHigh && mdfLow
                    ? (status.engineConsecutive >= status.consecutiveTrigger
                          ? cThr
                          : Colors.amber.shade800)
                    : Colors.black45,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
