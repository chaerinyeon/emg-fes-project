import 'package:flutter/material.dart';

import '../../core/constants.dart';
import '../../core/models.dart';

class FatigueTriggerPanel extends StatelessWidget {
  final AppStatus status;

  const FatigueTriggerPanel({super.key, required this.status});

  Widget _condRow({
    required BuildContext context,
    required String label,
    required String value,
    required double progress,
    required bool met,
    required Color color,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(
              met ? Icons.check_circle : Icons.radio_button_unchecked,
              size: 16,
              color: met ? color : Colors.white38,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: met ? Colors.white : Colors.white70,
                  fontSize: 12,
                ),
              ),
            ),
            Text(
              value,
              style: TextStyle(
                color: met ? color : Colors.white70,
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
              Container(height: 6, color: Colors.white10),
              FractionallySizedBox(
                widthFactor: (progress / 1.5).clamp(0.0, 1.0),
                child: Container(
                  height: 6,
                  color: met ? color : color.withValues(alpha: 0.4),
                ),
              ),
              // 임계값 마커 (66.7% 위치 = progress 1.0)
              Positioned(
                left: MediaQuery.of(context).size.width * 0.66 - 30,
                child: Container(width: 1.5, height: 6, color: cThr),
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final rs = status.rmsSlope;
    final ms = status.mdfSlope;
    final rt = status.rmsThreshold;
    final mt = status.mdfThreshold;

    final rsProgress = rt > 0 ? (rs / rt).clamp(0.0, 1.5) : 0.0;
    final msProgress = mt < 0 ? (ms / mt).clamp(0.0, 1.5) : 0.0;

    final cond1 = rs > rt;
    final cond2 = ms < mt;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _condRow(
              context: context,
              label: 'RMS slope > +${rt.toStringAsFixed(0)}%',
              value: '${rs >= 0 ? '+' : ''}${rs.toStringAsFixed(1)}%',
              progress: rsProgress,
              met: cond1,
              color: cRmsSlope,
            ),
            const SizedBox(height: 10),
            _condRow(
              context: context,
              label: 'MDF slope < ${mt.toStringAsFixed(0)}%',
              value: '${ms.toStringAsFixed(1)}%',
              progress: msProgress,
              met: cond2,
              color: cMdfSlope,
            ),
            const Divider(height: 22, color: Colors.white24),
            Row(
              children: [
                const Expanded(
                  child: Text(
                    '연속 만족 카운트',
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                ),
                Text(
                  '${status.consecutive} / ${status.consecutiveTrigger}',
                  style: TextStyle(
                    color: status.consecutive >= status.consecutiveTrigger
                        ? cThr
                        : Colors.white,
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
                final filled = i < status.consecutive;
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
                                : Colors.orangeAccent)
                          : Colors.white10,
                      border: Border.all(
                        color: filled
                            ? (i + 1 == status.consecutiveTrigger
                                  ? cThr
                                  : Colors.orangeAccent)
                            : Colors.white24,
                      ),
                    ),
                  ),
                );
              }),
            ),
            const SizedBox(height: 6),
            Text(
              cond1 && cond2
                  ? (status.consecutive >= status.consecutiveTrigger
                        ? '✅ 트리거 발동 — FES 자동 정지'
                        : '⚠️ 두 조건 만족 — 카운터 누적 중')
                  : (cond1 || cond2 ? '한 조건만 만족 (피로 아님)' : '조건 미충족 — 안정'),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: cond1 && cond2
                    ? (status.consecutive >= status.consecutiveTrigger
                          ? cThr
                          : Colors.amberAccent)
                    : Colors.white54,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
