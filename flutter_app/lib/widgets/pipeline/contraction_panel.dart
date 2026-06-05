import 'package:flutter/material.dart';

import '../../core/models.dart';

class ContractionPanel extends StatelessWidget {
  final AppStatus status;

  const ContractionPanel({super.key, required this.status});

  static String _stateLabel(int s) {
    switch (s) {
      case 0:
        return '휴식 (REST)';
      case 1:
        return '시작 (ONSET)';
      case 2:
        return '지속 (SUSTAINED)';
      default:
        return '—';
    }
  }

  static Color _stateColor(int s) {
    switch (s) {
      case 1:
        return Colors.orange.shade700;
      case 2:
        return Colors.green.shade600;
      default:
        return Colors.black38;
    }
  }

  static String _typeLabel(String t) {
    switch (t) {
      case 'b':
        return 'BURST (<2s, 일시적)';
      case 't':
        return 'TRANSIENT (2~5s)';
      case 's':
        return 'SUSTAINED (≥5s, 분석 유효)';
      default:
        return '없음';
    }
  }

  static Color _typeColor(String t) {
    switch (t) {
      case 'b':
        return Colors.redAccent;
      case 't':
        return Colors.amber.shade800;
      case 's':
        return Colors.green.shade600;
      default:
        return Colors.black38;
    }
  }

  Widget _countRow(
    String label,
    int count,
    int total,
    Color color,
    String hint,
  ) {
    final ratio = total > 0 ? count / total : 0.0;
    return Row(
      children: [
        SizedBox(
          width: 80,
          child: Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: Stack(
              children: [
                Container(height: 6, color: Colors.black12),
                FractionallySizedBox(
                  widthFactor: ratio.clamp(0.0, 1.0),
                  child: Container(height: 6, color: color),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 28,
          child: Text(
            '$count',
            textAlign: TextAlign.right,
            style: const TextStyle(
              color: Colors.black87,
              fontSize: 12,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            hint,
            style: const TextStyle(color: Colors.black38, fontSize: 9),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final dur = (status.contractDurMs / 1000).toStringAsFixed(1);
    final lastDur = (status.lastContractDurMs / 1000).toStringAsFixed(1);
    final total = status.burstCount + status.transientCount + status.sustainedCount;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 현재 상태
            Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _stateColor(status.contractState),
                  ),
                ),
                const SizedBox(width: 8),
                const Text(
                  '현재 상태',
                  style: TextStyle(color: Colors.black54, fontSize: 11),
                ),
                const SizedBox(width: 8),
                Text(
                  _stateLabel(status.contractState),
                  style: TextStyle(
                    color: _stateColor(status.contractState),
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                if (status.contractState != 0)
                  Text(
                    '${dur}s',
                    style: TextStyle(
                      color: _stateColor(status.contractState),
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
              ],
            ),
            const Divider(height: 18, color: Colors.black12),

            // 마지막 수축
            Row(
              children: [
                const Icon(Icons.history, size: 14, color: Colors.black45),
                const SizedBox(width: 6),
                const Text(
                  '마지막 수축',
                  style: TextStyle(color: Colors.black54, fontSize: 11),
                ),
                const SizedBox(width: 8),
                Text(
                  _typeLabel(status.lastContractType),
                  style: TextStyle(
                    color: _typeColor(status.lastContractType),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            if (status.lastContractType != '-') ...[
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.only(left: 20),
                child: Text(
                  '지속 ${lastDur}s   |   peak RMS ${status.lastContractPeak.toStringAsFixed(0)}',
                  style: const TextStyle(color: Colors.black45, fontSize: 11),
                ),
              ),
            ],
            const Divider(height: 18, color: Colors.black12),

            // 누적 카운터
            Row(
              children: [
                const Icon(Icons.bar_chart, size: 14, color: Colors.black45),
                const SizedBox(width: 6),
                const Text(
                  '세션 누적',
                  style: TextStyle(color: Colors.black54, fontSize: 11),
                ),
                const SizedBox(width: 8),
                Text(
                  '총 $total회',
                  style: const TextStyle(
                    color: Colors.black87,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            _countRow(
              'SUSTAINED',
              status.sustainedCount,
              total,
              Colors.green.shade600,
              '분석에 유효',
            ),
            const SizedBox(height: 4),
            _countRow(
              'TRANSIENT',
              status.transientCount,
              total,
              Colors.amber.shade800,
              '경계, 주의',
            ),
            const SizedBox(height: 4),
            _countRow(
              'BURST',
              status.burstCount,
              total,
              Colors.redAccent,
              '톱니파 원인 — 분석 제외 권장',
            ),
          ],
        ),
      ),
    );
  }
}
