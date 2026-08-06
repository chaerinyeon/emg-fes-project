import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../refit_theme.dart';

/// 화면의 손. 이 앱의 주인공이다.
///
/// [openness] 1 = 완전히 펴짐, 0 = 완전히 쥠.
///
/// 신경가소성은 "쥔다는 의도 · 실제 수축 · 감각 되먹임"이 같은 시점에 겹칠 때
/// 생긴다. 그래서 이 위젯은 **큐가 나가는 순간부터 미리 접히기 시작**한다
/// (환자가 의도할 시간). 자극이 오면 완전히 쥐어지고, 수축이 확인되지 않으면
/// 도중에 힘없이 멈춘다 — 빨강도 흔들림도 없다. 실패를 연출하지 않는다.
class HandView extends StatelessWidget {
  const HandView({
    super.key,
    required this.openness,
    this.glowing = false,
    this.successPulse = 0,
  });

  final double openness;

  /// 수축이 확인된 순간의 따뜻한 빛.
  final bool glowing;

  /// 성공할 때마다 1씩 증가. 값이 바뀌면 확산 링이 한 번 돈다.
  final int successPulse;

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        _SuccessRing(pulse: successPulse),
        TweenAnimationBuilder<double>(
          tween: Tween(begin: openness, end: openness),
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOutCubic,
          builder: (context, v, _) => CustomPaint(
            painter: _HandPainter(openness: v, glowing: glowing),
            size: Size.infinite,
          ),
        ),
      ],
    );
  }
}

class _SuccessRing extends StatefulWidget {
  const _SuccessRing({required this.pulse});
  final int pulse;

  @override
  State<_SuccessRing> createState() => _SuccessRingState();
}

class _SuccessRingState extends State<_SuccessRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 620),
  );

  @override
  void didUpdateWidget(covariant _SuccessRing old) {
    super.didUpdateWidget(old);
    if (widget.pulse != old.pulse && widget.pulse > 0) {
      _c.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        if (_c.isDismissed) return const SizedBox.shrink();
        final t = Curves.easeOutCubic.transform(_c.value);
        return IgnorePointer(
          child: CustomPaint(painter: _RingPainter(t), size: Size.infinite),
        );
      },
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.t);
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height * 0.52);
    final r = size.shortestSide * (0.28 + 0.34 * t);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5 * (1 - t) + 0.8
      ..color = RefitTheme.glow.withValues(alpha: 0.45 * (1 - t));
    canvas.drawCircle(center, r, paint);
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.t != t;
}

class _HandPainter extends CustomPainter {
  _HandPainter({required this.openness, required this.glowing});

  final double openness;
  final bool glowing;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final center = Offset(size.width / 2, size.height * 0.55);

    final palmW = s * 0.40;
    final palmH = s * 0.44;
    final palmRect = Rect.fromCenter(
      center: center + Offset(0, palmH * 0.18),
      width: palmW,
      height: palmH,
    );

    if (glowing) {
      canvas.drawCircle(
        center,
        s * 0.36,
        Paint()
          ..color = RefitTheme.handGlow.withValues(alpha: 0.16)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 40),
      );
    }

    final fill = Paint()
      ..style = PaintingStyle.fill
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          glowing ? RefitTheme.handGlow : RefitTheme.hand,
          RefitTheme.handShade,
        ],
      ).createShader(palmRect.inflate(s * 0.3));

    // 손가락 4개 — openness 로 길이와 안쪽 회전이 같이 변한다.
    const fingerCount = 4;
    final fingerW = palmW / 5.1;
    for (var i = 0; i < fingerCount; i++) {
      final tNorm = (i + 0.5) / fingerCount; // 0..1
      final x = palmRect.left + palmW * tNorm;

      // 가운데 손가락이 가장 길다.
      final lengthScale = 1.0 - (tNorm - 0.5).abs() * 0.55;
      final maxLen = palmH * 0.86 * lengthScale;
      final len = maxLen * (0.30 + 0.70 * openness);

      final curl = (1 - openness) * 0.55 * (i.isEven ? 1 : 1);
      canvas.save();
      canvas.translate(x, palmRect.top + fingerW * 0.15);
      canvas.rotate(curl * (tNorm - 0.5) * 1.6);

      final rr = RRect.fromRectAndRadius(
        Rect.fromLTWH(-fingerW / 2, -len, fingerW, len + fingerW),
        Radius.circular(fingerW / 2),
      );
      canvas.drawRRect(rr, fill);
      canvas.restore();
    }

    // 엄지 — 손바닥 옆구리에서 비스듬히 나온다.
    // 너무 눕히면(≈70°) 팔에서 떨어진 막대처럼 보여 손으로 읽히지 않는다.
    canvas.save();
    canvas.translate(palmRect.left + palmW * 0.18, center.dy + palmH * 0.22);
    canvas.rotate(-math.pi / 3.6 + (1 - openness) * 0.7);
    final thumbLen = palmH * (0.46 + 0.22 * openness);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          -fingerW * 0.6,
          -thumbLen,
          fingerW * 1.2,
          thumbLen + fingerW,
        ),
        Radius.circular(fingerW * 0.6),
      ),
      fill,
    );
    canvas.restore();

    // 손바닥
    canvas.drawRRect(
      RRect.fromRectAndCorners(
        palmRect,
        topLeft: Radius.circular(palmW * 0.22),
        topRight: Radius.circular(palmW * 0.22),
        bottomLeft: Radius.circular(palmW * 0.40),
        bottomRight: Radius.circular(palmW * 0.40),
      ),
      fill,
    );
  }

  @override
  bool shouldRepaint(_HandPainter old) =>
      old.openness != openness || old.glowing != glowing;
}
