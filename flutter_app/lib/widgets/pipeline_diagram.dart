import 'package:flutter/material.dart';

import '../constants.dart';
import '../models.dart';

class PipelineDiagram extends StatelessWidget {
  final AppStatus status;
  final double envLast;
  final double rmsLast;
  final double mdfLast;

  const PipelineDiagram({
    super.key,
    required this.status,
    required this.envLast,
    required this.rmsLast,
    required this.mdfLast,
  });

  Widget _stage({
    required String label,
    required String value,
    required bool active,
    Color? activeColor,
  }) {
    final color = active
        ? (activeColor ?? Colors.indigoAccent)
        : Colors.white24;
    final bg = active ? color.withValues(alpha: 0.15) : Colors.white10;
    return Container(
      constraints: const BoxConstraints(minWidth: 78),
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
      decoration: BoxDecoration(
        color: bg,
        border: Border.all(color: color, width: active ? 1.5 : 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              color: active ? Colors.white : Colors.white54,
              fontSize: 10,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: TextStyle(
              color: color,
              fontSize: 13,
              fontWeight: FontWeight.bold,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  Widget _arrow(bool active) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 4),
    child: Icon(
      Icons.east,
      size: 16,
      color: active ? Colors.white70 : Colors.white24,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final running = status.isRunning;
    final sloping = status.historyCount >= 30;
    final cond1 = status.rmsSlope > status.rmsThreshold;
    final cond2 = status.mdfSlope < status.mdfThreshold;
    final consec = status.consecutive;

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          _stage(
            label: 'RAW EMG\nESP 1kHz',
            value: running ? '✓' : '—',
            active: running,
            activeColor: Colors.white70,
          ),
          _arrow(running),
          _stage(
            label: 'ENV (LPF)\n10Hz',
            value: running ? envLast.toStringAsFixed(0) : '—',
            active: running,
            activeColor: cEnv,
          ),
          _arrow(running),
          _stage(
            label: '1초 윈도우\nRMS / MDF',
            value: running
                ? '${rmsLast.toStringAsFixed(0)} / ${mdfLast.toStringAsFixed(0)}'
                : '—',
            active: running,
            activeColor: cRms,
          ),
          _arrow(running),
          _stage(
            label: '60s 버퍼',
            value: '${status.historyCount}/60',
            active: running && status.historyCount > 0,
            activeColor: Colors.cyanAccent,
          ),
          _arrow(sloping),
          _stage(
            label: 'slope %\n(선형회귀)',
            value: sloping
                ? '${status.rmsSlope >= 0 ? '+' : ''}${status.rmsSlope.toStringAsFixed(0)} / ${status.mdfSlope.toStringAsFixed(0)}'
                : '대기',
            active: sloping,
            activeColor: cRmsSlope,
          ),
          _arrow(sloping),
          _stage(
            label: '이중 조건\nRMS↑ ∧ MDF↓',
            value: (cond1 && cond2) ? '✓ 만족' : '✗',
            active: sloping && (cond1 || cond2),
            activeColor: (cond1 && cond2) ? Colors.amberAccent : Colors.white24,
          ),
          _arrow(status.consecutive > 0),
          _stage(
            label: '5× 카운터',
            value: '$consec/${status.consecutiveTrigger}',
            active: status.consecutive > 0,
            activeColor: consec >= status.consecutiveTrigger
                ? Colors.red
                : Colors.orangeAccent,
          ),
          _arrow(status.fatigueDetected),
          _stage(
            label: 'FATIGUE',
            value: status.fatigueDetected ? '🚨 ON' : 'OFF',
            active: status.fatigueDetected,
            activeColor: cThr,
          ),
          _arrow(status.fatigueDetected),
          _stage(
            label: 'FES 제어',
            value: status.isStimulating ? 'STIM ON' : 'OFF',
            active: status.isStimulating,
            activeColor: Colors.orange,
          ),
        ],
      ),
    );
  }
}
