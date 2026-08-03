import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../model/zone.dart';

/// 반원 σ 게이지 — `fatigue_gauge.html` 이식.
///
/// 원본 SVG 와 같은 기하다: 0~4σ 를 180° 에 펼치고 존마다 색 아크를 깔고,
/// 흰 바늘이 `z/4 × 180°` 를 가리킨다.
///
/// σ 를 모르는 동안([sigma] 가 null)은 바늘을 숨기고 "측정 중"을 띄운다.
/// 모르는 상태를 정상(0σ)으로 그리면 사용자가 안전하다고 오해한다.
/// 반원 다이얼만 — 텍스트 없이 바늘과 존 아크만 그린다.
///
/// 좁은 화면에서 게이지를 **가로로 눕힐** 때 쓴다. 세로로 쌓으면 하단 중앙을
/// 덮어 포구 순간이 가려지는데, 그건 이 화면에서 가장 보여줘야 할 장면이다.
class SigmaDial extends StatelessWidget {
  const SigmaDial({
    super.key,
    required this.sigma,
    this.predicted,
    this.size = const Size(78, 46),
  });

  final double? sigma;
  final double? predicted;
  final Size size;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size.width,
        height: size.height,
        child: CustomPaint(
          painter: _GaugePainter(sigma: sigma, predicted: predicted),
        ),
      );
}

class SigmaGauge extends StatelessWidget {
  const SigmaGauge({
    super.key,
    required this.sigma,
    this.predicted,
    this.predictionHorizonSec,
    this.compact = false,
    this.calibrationHint = '측정 중',
  });

  final double? sigma;

  /// LSTM 이 예측한 [predictionHorizonSec] 초 뒤의 σ.
  ///
  /// 같은 게이지에 **점선 바늘**로 겹쳐 그린다. SPC σ 가 "지금 지쳤다"를 사후에
  /// 말한다면 이쪽은 "곧 지친다"를 미리 말한다 — 위험에 닿기 전에 개입할 시간을
  /// 벌어주는 것이 목적이다.
  final double? predicted;

  final double? predictionHorizonSec;

  /// 게임 중 HUD 용 축소판. 숫자와 존 라벨만 곁들인다.
  final bool compact;

  final String calibrationHint;

  @override
  Widget build(BuildContext context) {
    final z = sigma;
    final zone = z == null ? null : zoneOf(z);
    final color = Color(zone?.argb ?? 0xFF8B949E);
    final size = compact ? const Size(96, 58) : const Size(300, 178);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: size.width,
          height: size.height,
          child: CustomPaint(
            painter: _GaugePainter(sigma: z, predicted: predicted),
          ),
        ),
        SizedBox(height: compact ? 2 : 10),
        if (z == null)
          Text(
            calibrationHint,
            style: TextStyle(
              color: const Color(0xFF8B949E),
              fontSize: compact ? 11 : 15,
              fontWeight: FontWeight.w600,
            ),
          )
        else ...[
          Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                z.clamp(0, 99).toStringAsFixed(1),
                style: TextStyle(
                  color: color,
                  fontSize: compact ? 22 : 56,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -1,
                  height: 1,
                ),
              ),
              Text(
                ' σ',
                style: TextStyle(
                  color: const Color(0xFF8B949E),
                  fontSize: compact ? 12 : 20,
                ),
              ),
            ],
          ),
          SizedBox(height: compact ? 2 : 8),
          _ZonePill(zone: zone!, compact: compact),
          if (predicted != null && predicted! > z + 0.15) ...[
            SizedBox(height: compact ? 3 : 8),
            _PredictionNote(
              predicted: predicted!,
              horizonSec: predictionHorizonSec,
              compact: compact,
            ),
          ],
        ],
      ],
    );
  }
}

class _ZonePill extends StatelessWidget {
  const _ZonePill({required this.zone, required this.compact});

  final FatigueZone zone;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 8 : 16,
        vertical: compact ? 2 : 6,
      ),
      decoration: BoxDecoration(
        color: Color(zone.argb),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '${zone.icon} ${zone.label}',
        style: TextStyle(
          // 존 4색 모두 밝은 계열이라 어두운 글자가 대비를 확보한다.
          color: const Color(0xFF0D1117),
          fontWeight: FontWeight.w700,
          fontSize: compact ? 11 : 15,
        ),
      ),
    );
  }
}

/// 예측이 현재보다 위험한 존이면 미리 알린다.
class _PredictionNote extends StatelessWidget {
  const _PredictionNote({
    required this.predicted,
    required this.horizonSec,
    required this.compact,
  });

  final double predicted;
  final double? horizonSec;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final zone = zoneOf(predicted);
    final after = horizonSec == null ? '' : '${horizonSec!.round()}초 후 ';
    return Text(
      '◌ 예측 $after${predicted.toStringAsFixed(1)}σ · ${zone.label}',
      textAlign: TextAlign.center,
      style: TextStyle(
        color: Color(zone.argb).withValues(alpha: 0.85),
        fontSize: compact ? 10 : 13,
        fontWeight: FontWeight.w700,
      ),
    );
  }
}

class _GaugePainter extends CustomPainter {
  const _GaugePainter({required this.sigma, this.predicted});

  final double? sigma;
  final double? predicted;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height * 0.955;
    final r = math.min(size.width / 2, cy) * 0.86;
    final stroke = r * 0.155;

    // 존 아크 — 0-1-2-3-4σ 를 180° 에 펼친다(원본 SVG 와 동일).
    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.butt;
    for (final zone in FatigueZone.values) {
      final z0 = zone.lowerSigma; // 각 존은 1σ 폭
      arc.color = Color(zone.argb);
      canvas.drawArc(
        Rect.fromCircle(center: Offset(cx, cy), radius: r),
        math.pi + (z0 / kSigmaMax) * math.pi,
        (1 / kSigmaMax) * math.pi,
        false,
        arc,
      );
    }

    final z = sigma;
    if (z == null) return;

    // 예측 바늘 — 점선·반투명. 현재 바늘보다 먼저(아래에) 그려 가리지 않게 한다.
    final p = predicted;
    if (p != null) _drawNeedle(canvas, cx, cy, r, p, dashed: true);

    // 바늘
    _drawNeedle(canvas, cx, cy, r, z);
    canvas.drawCircle(
      Offset(cx, cy),
      math.max(4, r * 0.062),
      Paint()..color = Colors.white,
    );
  }

  void _drawNeedle(
    Canvas canvas,
    double cx,
    double cy,
    double r,
    double value, {
    bool dashed = false,
  }) {
    final angle = math.pi + (value.clamp(0.0, kSigmaMax) / kSigmaMax) * math.pi;
    final len = r * (dashed ? 0.86 : 0.92);
    final dx = math.cos(angle), dy = math.sin(angle);
    final paint = Paint()
      ..color = dashed ? Colors.white.withValues(alpha: 0.5) : Colors.white
      ..strokeWidth = math.max(2, r * (dashed ? 0.024 : 0.031))
      ..strokeCap = StrokeCap.round;

    if (!dashed) {
      canvas.drawLine(
        Offset(cx, cy),
        Offset(cx + len * dx, cy + len * dy),
        paint,
      );
      return;
    }
    // 점선 — 예측은 확정이 아니라는 걸 형태로도 말한다.
    const seg = 7.0, gap = 5.0;
    var d = r * 0.16;
    while (d < len) {
      final e = math.min(d + seg, len);
      canvas.drawLine(
        Offset(cx + d * dx, cy + d * dy),
        Offset(cx + e * dx, cy + e * dy),
        paint,
      );
      d = e + gap;
    }
  }

  @override
  bool shouldRepaint(_GaugePainter old) =>
      old.sigma != sigma || old.predicted != predicted;
}
