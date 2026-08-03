import 'dart:math' as math;
import 'dart:ui';

import 'package:flame/components.dart';

/// 포구 이펙트 — 빛 링 + 파티클.
///
/// 이 게임에 점수가 없으므로, **성취감은 전적으로 이 순간의 연출이 만든다.**
/// 환자에게 "내 근육이 수축했고 그게 공을 잡았다"를 시원하게 돌려주는 것이
/// 신경가소성 동기부여의 핵심이라 아끼지 않는다.
class CatchEffect extends PositionComponent {
  CatchEffect({required Vector2 position})
      : super(position: position, priority: 30, anchor: Anchor.center);

  static const double _durationSec = 0.62;
  double _t = 0;

  final List<_Spark> _sparks = [];

  @override
  Future<void> onLoad() async {
    // 결정론적 배치 — 매번 같은 모양이라 프레임마다 튀지 않는다.
    var seed = 20260803;
    double rnd() {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      return seed / 0x7fffffff;
    }

    for (var i = 0; i < 14; i++) {
      final a = (i / 14) * math.pi * 2 + rnd() * 0.35;
      _sparks.add(_Spark(angle: a, speed: 90 + rnd() * 170, size: 3 + rnd() * 4));
    }
  }

  @override
  void update(double dt) {
    super.update(dt);
    _t += dt;
    if (_t >= _durationSec) removeFromParent();
  }

  @override
  void render(Canvas canvas) {
    final p = (_t / _durationSec).clamp(0.0, 1.0);
    final fade = 1.0 - p;

    // 퍼지는 빛 링
    final r = 26 + p * 96;
    canvas.drawCircle(
      Offset.zero,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 7 * fade
        ..color = Color.fromRGBO(255, 245, 200, 0.85 * fade),
    );

    // 중심 섬광
    canvas.drawCircle(
      Offset.zero,
      34 * (1 - p * 0.55),
      Paint()
        ..color = Color.fromRGBO(255, 255, 255, 0.55 * fade * fade)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14),
    );

    // 파티클
    for (final s in _sparks) {
      final d = s.speed * p;
      canvas.drawCircle(
        Offset(math.cos(s.angle) * d, math.sin(s.angle) * d),
        s.size * fade,
        Paint()..color = Color.fromRGBO(255, 224, 130, fade),
      );
    }
  }
}

class _Spark {
  const _Spark({required this.angle, required this.speed, required this.size});

  final double angle;
  final double speed;
  final double size;
}
