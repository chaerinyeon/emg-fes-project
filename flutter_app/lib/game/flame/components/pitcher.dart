import 'dart:math' as math;
import 'dart:ui';

import 'package:flame/components.dart';

import '../baseball_game.dart';

/// 투수 — 다음 수축 이벤트에 맞춰 공을 던지는 연출.
class Pitcher extends PositionComponent with HasGameReference<BaseballGame> {
  Pitcher() : super(priority: 5, anchor: Anchor.bottomCenter);

  double _phase = 0;
  bool _throwing = false;

  static const double windupSec = 0.55;

  void throwPitch() {
    _throwing = true;
    _phase = 0;
  }

  @override
  void onGameResize(Vector2 size) {
    super.onGameResize(size);
    this.size = Vector2(size.x * 0.115, size.x * 0.17);
    position = Vector2(size.x * 0.5, size.y * 0.48);
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
    if (!game.showPitcher) return;
    final width = size.x;
    final height = size.y;
    final body = Paint()..color = const Color(0xFFE8EEF5);
    final trim = Paint()..color = const Color(0xFF2C5AA0);
    final skin = Paint()..color = const Color(0xFFF2C89B);

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(width * 0.34, height * 0.6, width * 0.14, height * 0.4),
        Radius.circular(width * 0.06),
      ),
      body,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(width * 0.52, height * 0.6, width * 0.14, height * 0.4),
        Radius.circular(width * 0.06),
      ),
      body,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(width * 0.3, height * 0.3, width * 0.4, height * 0.34),
        Radius.circular(width * 0.1),
      ),
      body,
    );
    canvas.drawRect(
      Rect.fromLTWH(width * 0.3, height * 0.44, width * 0.4, height * 0.05),
      trim,
    );
    canvas.drawCircle(Offset(width * 0.5, height * 0.2), width * 0.15, skin);
    canvas.drawArc(
      Rect.fromCircle(
        center: Offset(width * 0.5, height * 0.2),
        radius: width * 0.16,
      ),
      math.pi,
      math.pi,
      true,
      trim,
    );

    final angle = math.pi * (0.85 - 1.5 * _easeIn(_throwing ? _phase : 0));
    final shoulderX = width * 0.5;
    final shoulderY = height * 0.36;
    final armLength = height * 0.34;
    canvas.drawLine(
      Offset(shoulderX, shoulderY),
      Offset(
        shoulderX + math.cos(angle) * armLength,
        shoulderY - math.sin(angle) * armLength,
      ),
      Paint()
        ..color = const Color(0xFFF2C89B)
        ..strokeWidth = width * 0.11
        ..strokeCap = StrokeCap.round,
    );
  }

  static double _easeIn(double value) => value * value;
}
