import 'dart:math' as math;
import 'dart:ui';

import 'package:flame/components.dart';

import '../baseball_game.dart';

/// 야구장 배경 — 2.5D 의 "속임수"가 사는 곳.
///
/// 카메라가 고정이라 관중석·도시·조명탑·전광판은 전부 정지 화면이다. 그래서
/// 3D 로 만들 이유가 없고, 그림 한 장이면 된다.
///
/// 에셋(`assets/game/stadium.png`)이 있으면 그걸 쓰고, 없으면 같은 구도를 코드로
/// 그린다. 덕분에 에셋 없이도 화면이 돌아가고, 나중에 그림만 넣으면 교체된다.
///
/// TODO(에셋): 1인칭 타석 뷰 카툰 스타디움 PNG 를 `assets/game/stadium.png` 로
///   넣으면 [BaseballGame.stadiumSprite] 가 채워지고 이 컴포넌트가 그걸 그린다.
class Stadium extends PositionComponent with HasGameReference<BaseballGame> {
  Stadium() : super(priority: -100);

  /// σ 존 색 틴트. **분위기만** 바꾼다 — 게임 규칙에는 영향이 없다.
  Color tint = const Color(0x0039D353);

  @override
  void onGameResize(Vector2 size) {
    super.onGameResize(size);
    this.size = size.clone();
  }

  @override
  void render(Canvas canvas) {
    final w = size.x, h = size.y;
    final sprite = game.stadiumSprite;
    if (sprite != null) {
      sprite.render(canvas, size: size);
    } else {
      _paintFallback(canvas, w, h);
    }

    // 존 색 틴트 — 존이 오를수록 조명이 가라앉는 느낌을 준다.
    canvas.drawRect(
      Rect.fromLTWH(0, 0, w, h),
      Paint()..color = tint,
    );
  }

  /// 에셋 없이 그리는 스타디움. 사진 같지는 않아도 구도는 같다.
  void _paintFallback(Canvas canvas, double w, double h) {
    final horizon = h * 0.42;

    // 하늘 — 야간 경기 무드
    canvas.drawRect(
      Rect.fromLTWH(0, 0, w, horizon),
      Paint()
        ..shader = Gradient.linear(
          Offset(0, 0),
          Offset(0, horizon),
          [const Color(0xFF0B1A2E), const Color(0xFF2A4A6B)],
        ),
    );

    // 원경 빌딩 — 결정론적이라 프레임마다 흔들리지 않는다.
    final b = Paint()..color = const Color(0xFF16283D);
    var seed = 20260803;
    double rnd() {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      return seed / 0x7fffffff;
    }

    for (var x = 0.0; x < w; x += w * 0.055) {
      final bh = horizon * (0.18 + rnd() * 0.3);
      canvas.drawRect(Rect.fromLTWH(x, horizon - bh, w * 0.05, bh), b);
    }

    // 관중석
    canvas.drawRect(
      Rect.fromLTWH(0, horizon, w, h * 0.1),
      Paint()..color = const Color(0xFF243447),
    );
    final crowd = Paint()..color = const Color(0xFF3A4E68);
    for (var i = 0; i < 220; i++) {
      canvas.drawCircle(
        Offset(rnd() * w, horizon + rnd() * h * 0.1),
        w * 0.004,
        crowd,
      );
    }

    // 외야 담장
    canvas.drawRect(
      Rect.fromLTWH(0, horizon + h * 0.1, w, h * 0.022),
      Paint()..color = const Color(0xFF1E4620),
    );

    // 잔디 — 아래로 갈수록 밝게 해서 원근을 만든다
    final grassTop = horizon + h * 0.122;
    canvas.drawRect(
      Rect.fromLTWH(0, grassTop, w, h - grassTop),
      Paint()
        ..shader = Gradient.linear(
          Offset(0, grassTop),
          Offset(0, h),
          [const Color(0xFF2E6B33), const Color(0xFF3F8C45)],
        ),
    );

    // 내야 흙 — 사다리꼴로 원근
    final dirt = Path()
      ..moveTo(w * 0.22, h)
      ..lineTo(w * 0.78, h)
      ..lineTo(w * 0.62, grassTop + (h - grassTop) * 0.36)
      ..lineTo(w * 0.38, grassTop + (h - grassTop) * 0.36)
      ..close();
    canvas.drawPath(dirt, Paint()..color = const Color(0xFF8A5A38));

    // 마운드
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(w * 0.5, grassTop + (h - grassTop) * 0.42),
        width: w * 0.16,
        height: h * 0.028,
      ),
      Paint()..color = const Color(0xFF9C6A44),
    );

    // 홈플레이트
    final plate = Path()
      ..moveTo(w * 0.5, h * 0.965)
      ..lineTo(w * 0.44, h * 0.94)
      ..lineTo(w * 0.44, h * 0.915)
      ..lineTo(w * 0.56, h * 0.915)
      ..lineTo(w * 0.56, h * 0.94)
      ..close();
    canvas.drawPath(plate, Paint()..color = const Color(0xFFECECEC));

    _paintLightTowers(canvas, w, horizon);
  }

  void _paintLightTowers(Canvas canvas, double w, double horizon) {
    final pole = Paint()..color = const Color(0xFF1A2634);
    final lamp = Paint()..color = const Color(0xFFFFF3C4);
    final glow = Paint()
      ..color = const Color(0x22FFF3C4)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18);

    for (final x in [w * 0.12, w * 0.88]) {
      final top = horizon * 0.28;
      canvas.drawRect(Rect.fromLTWH(x - w * 0.006, top, w * 0.012, horizon - top), pole);
      final head = Rect.fromCenter(
        center: Offset(x, top),
        width: w * 0.09,
        height: horizon * 0.1,
      );
      canvas.drawCircle(Offset(x, top), w * 0.075, glow);
      canvas.drawRect(head, pole);
      for (var i = 0; i < 4; i++) {
        for (var j = 0; j < 2; j++) {
          canvas.drawCircle(
            Offset(head.left + head.width * (0.16 + i * 0.23),
                head.top + head.height * (0.3 + j * 0.4)),
            math.min(w * 0.007, head.height * 0.16),
            lamp,
          );
        }
      }
    }
  }
}
