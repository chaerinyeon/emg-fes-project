import 'dart:math' as math;
import 'dart:ui';

import 'package:flame/components.dart';

import '../baseball_game.dart';

/// 투수 — 공을 던지는 연출.
///
/// 던지는 시각은 **다음 수축 이벤트 도착 시각에서 역산**한다. 공이 원경에서
/// 날아오는 데 걸리는 시간만큼 앞서 와인드업을 시작해야, 공이 도착하는 순간과
/// 근수축이 일어나는 순간이 맞아떨어진다.
///
/// TODO(에셋): `assets/game/pitcher.png` (가로로 이어붙인 프레임)을 넣으면
///   [BaseballGame.pitcherAnimation] 이 채워지고 스프라이트 애니메이션으로
///   교체된다. 없으면 아래 코드 드로잉이 같은 모션을 흉내낸다.
class Pitcher extends PositionComponent with HasGameReference<BaseballGame> {
  Pitcher() : super(priority: 5, anchor: Anchor.bottomCenter);

  /// 0 = 대기, 0~1 = 와인드업→릴리스.
  double _phase = 0;
  bool _throwing = false;

  /// 와인드업 총 길이(초).
  static const double windupSec = 0.55;

  /// 투구 모션 시작.
  void throwPitch() {
    _throwing = true;
    _phase = 0;
  }

  @override
  void onGameResize(Vector2 size) {
    super.onGameResize(size);
    this.size = Vector2(size.x * 0.13, size.x * 0.19);
    position = Vector2(size.x * 0.5, size.y * 0.535);
  }

  @override
  void update(double dt) {
    super.update(dt);
    if (!_throwing) return;
    _phase += dt / windupSec;
    if (_phase >= 1) {
      _phase = 0;
      _throwing = false;
    }
  }

  @override
  void render(Canvas canvas) {
    final anim = game.pitcherAnimation;
    if (anim != null) {
      final frame = (_phase * anim.frames.length)
          .floor()
          .clamp(0, anim.frames.length - 1);
      anim.frames[frame].sprite.render(canvas, size: size);
      return;
    }
    _paintFallback(canvas);
  }

  /// 에셋 없이 그리는 투수. 팔이 뒤로 갔다가 앞으로 나온다.
  void _paintFallback(Canvas canvas) {
    final w = size.x, h = size.y;
    final body = Paint()..color = const Color(0xFFE8EEF5);
    final trim = Paint()..color = const Color(0xFF2C5AA0);
    final skin = Paint()..color = const Color(0xFFF2C89B);

    // 다리
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * 0.34, h * 0.6, w * 0.14, h * 0.4),
        Radius.circular(w * 0.06),
      ),
      body,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * 0.52, h * 0.6, w * 0.14, h * 0.4),
        Radius.circular(w * 0.06),
      ),
      body,
    );
    // 몸통
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * 0.3, h * 0.3, w * 0.4, h * 0.34),
        Radius.circular(w * 0.1),
      ),
      body,
    );
    canvas.drawRect(Rect.fromLTWH(w * 0.3, h * 0.44, w * 0.4, h * 0.05), trim);
    // 머리 + 모자
    canvas.drawCircle(Offset(w * 0.5, h * 0.2), w * 0.15, skin);
    canvas.drawArc(
      Rect.fromCircle(center: Offset(w * 0.5, h * 0.2), radius: w * 0.16),
      math.pi,
      math.pi,
      true,
      trim,
    );

    // 던지는 팔 — 와인드업(뒤) → 릴리스(앞)
    final a = _throwing ? _phase : 0.0;
    final angle = math.pi * (0.85 - 1.5 * _easeIn(a));
    final sx = w * 0.5, sy = h * 0.36;
    final len = h * 0.34;
    canvas.drawLine(
      Offset(sx, sy),
      Offset(sx + math.cos(angle) * len, sy - math.sin(angle) * len),
      Paint()
        ..color = const Color(0xFFF2C89B)
        ..strokeWidth = w * 0.11
        ..strokeCap = StrokeCap.round,
    );
  }

  static double _easeIn(double t) => t * t;
}
