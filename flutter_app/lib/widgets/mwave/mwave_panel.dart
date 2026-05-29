import 'package:flutter/material.dart';

import '../../core/models.dart';

/// M-wave 라이브 패널 — 진폭/면적/잠복기 + 세션 baseline 대비 변화.
/// 자극(stim) 중에만 의미가 있으므로 비활성 상태에서는 회색.
class MwavePanel extends StatelessWidget {
  final AppStatus status;
  const MwavePanel({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    final active = status.isStimulating && status.mwCount > 0;
    final hasBaseline = status.mwAmpBaseline != null;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  Icons.bolt,
                  size: 16,
                  color: active ? Colors.amberAccent : Colors.white38,
                ),
                const SizedBox(width: 6),
                const Text(
                  'M-wave (자극 응답)',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                Text(
                  active
                      ? '${status.mwCount}회 검출${hasBaseline ? ' · baseline 확립' : ' · baseline 수집 중'}'
                      : (status.isStimulating ? '자극 시작 대기' : '자극 OFF'),
                  style: const TextStyle(color: Colors.white54, fontSize: 10),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                _metric(
                  label: '진폭',
                  value: active ? status.mwAmp.toStringAsFixed(0) : '—',
                  unit: 'p-p',
                  declinePct: status.mwAmpDeclinePct,
                  isDecline: true,
                  active: active,
                ),
                _divider(),
                _metric(
                  label: '면적',
                  value: active ? status.mwArea.toStringAsFixed(0) : '—',
                  unit: 'AUC',
                  declinePct: status.mwAreaDeclinePct,
                  isDecline: true,
                  active: active,
                ),
                _divider(),
                _metric(
                  label: '잠복기',
                  value: active ? status.mwLatency.toStringAsFixed(1) : '—',
                  unit: 'ms',
                  declinePct: status.mwLatencyDeltaMs,
                  isDecline: false, // latency는 증가가 fatigue
                  active: active,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _divider() => Container(
    width: 1,
    height: 38,
    color: Colors.white12,
    margin: const EdgeInsets.symmetric(horizontal: 8),
  );

  Widget _metric({
    required String label,
    required String value,
    required String unit,
    required double? declinePct,
    required bool isDecline, // true: 양수 감소가 fatigue, false: 양수 지연이 fatigue
    required bool active,
  }) {
    Color deltaColor = Colors.white54;
    String deltaText = '';
    if (active && declinePct != null) {
      final isWarning = isDecline ? declinePct > 15 : declinePct > 1.0;
      deltaColor = isWarning ? Colors.orangeAccent : Colors.white60;
      if (isDecline) {
        final sign = declinePct >= 0 ? '↓' : '↑';
        deltaText =
            '$sign ${declinePct.abs().toStringAsFixed(0)}%';
      } else {
        final sign = declinePct >= 0 ? '+' : '';
        deltaText = '$sign${declinePct.toStringAsFixed(1)}ms';
      }
    }
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                label,
                style: const TextStyle(color: Colors.white60, fontSize: 11),
              ),
              const SizedBox(width: 4),
              Text(
                unit,
                style: const TextStyle(color: Colors.white38, fontSize: 9),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: TextStyle(
              color: active ? Colors.amberAccent : Colors.white38,
              fontSize: 18,
              fontWeight: FontWeight.bold,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          if (deltaText.isNotEmpty)
            Text(
              deltaText,
              style: TextStyle(
                color: deltaColor,
                fontSize: 10,
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
        ],
      ),
    );
  }
}
