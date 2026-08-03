import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../model/zone.dart';

/// σ 타임라인 — `fatigue_gauge.html` 의 `.tl` 이식.
///
/// 표본마다 존 색 띠를 깔고 1σ/2σ/3σ 최초 도달 지점에 마커를 세운다.
/// 오프라인 게이지는 끝난 세션을 되짚어 보는 용도였지만, 여기서는 **실시간이라
/// 플레이하면서 왼쪽부터 채워진다**.
class ZoneTimeline extends StatelessWidget {
  const ZoneTimeline({
    super.key,
    required this.history,
    required this.nowSec,
    this.t1,
    this.t2,
    this.t3,
    this.height = 34,
  });

  /// (시각, σ) 이력.
  final List<({double t, double z})> history;
  final double nowSec;
  final double? t1, t2, t3;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          '타임라인 (구간 색 = σ 존, 위 눈금 = 1σ/2σ/3σ 도달)',
          style: TextStyle(color: Color(0xFF8B949E), fontSize: 12),
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Container(
            height: height,
            color: const Color(0xFF21262D),
            child: CustomPaint(
              size: Size.infinite,
              painter: _TimelinePainter(
                history: history,
                nowSec: nowSec,
                marks: {1: t1, 2: t2, 3: t3},
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 14,
          runSpacing: 4,
          children: [
            for (final z in FatigueZone.values) _LegendDot(zone: z),
          ],
        ),
      ],
    );
  }
}

class _LegendDot extends StatelessWidget {
  const _LegendDot({required this.zone});

  final FatigueZone zone;

  @override
  Widget build(BuildContext context) {
    final range = switch (zone) {
      FatigueZone.normal => '<1σ',
      FatigueZone.caution => '1–2σ',
      FatigueZone.warning => '2–3σ',
      FatigueZone.danger => '≥3σ',
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: Color(zone.argb),
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        const SizedBox(width: 5),
        Text('${zone.label} $range',
            style: const TextStyle(color: Color(0xFF8B949E), fontSize: 11)),
      ],
    );
  }
}

class _TimelinePainter extends CustomPainter {
  _TimelinePainter({
    required this.history,
    required this.nowSec,
    required this.marks,
  });

  final List<({double t, double z})> history;
  final double nowSec;
  final Map<int, double?> marks;

  @override
  void paint(Canvas canvas, Size size) {
    if (history.isEmpty) return;
    final t0 = history.first.t;
    final span = (nowSec - t0).abs() < 1e-6 ? 1.0 : nowSec - t0;
    double x(double t) => ((t - t0) / span * size.width).clamp(0.0, size.width);

    // 존 색 구간
    final p = Paint()..style = PaintingStyle.fill;
    for (var i = 0; i < history.length; i++) {
      final left = x(history[i].t);
      final right =
          i + 1 < history.length ? x(history[i + 1].t) : size.width;
      p.color = Color(zoneOf(history[i].z).argb).withValues(alpha: 0.55);
      canvas.drawRect(
        Rect.fromLTRB(left, 0, math.max(right, left + 1), size.height),
        p,
      );
    }

    // 도달 마커
    for (final e in marks.entries) {
      final t = e.value;
      if (t == null) continue;
      final zone = zoneOf(e.key.toDouble());
      canvas.drawRect(
        Rect.fromLTWH(x(t) - 1, 0, 2, size.height),
        Paint()..color = Color(zone.argb),
      );
    }

    // 현재 커서
    canvas.drawRect(
      Rect.fromLTWH(size.width - 2, 0, 2, size.height),
      Paint()..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(_TimelinePainter old) =>
      old.history.length != history.length ||
      old.nowSec != nowSec ||
      old.marks.toString() != marks.toString();
}
