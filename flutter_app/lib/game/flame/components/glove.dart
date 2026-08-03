import 'dart:math' as math;
import 'dart:ui';

import 'package:flame/components.dart';

import '../baseball_game.dart';

/// 화면 하단 고정 글러브.
///
/// 수축이 검출되면 닫히고, 포구 이펙트가 끝나면 다시 열린다. **환자가 조작하지
/// 않는다** — FES 가 손을 닫는 그 순간을 그대로 옮긴 것이다. 자기 근육이
/// 수축했다는 사실이 화면에서 공을 잡는 장면으로 되돌아오는 것이 이 화면의
/// 존재 이유다(신경가소성 되먹임).
///
/// TODO(에셋): `assets/game/glove_open.png` · `glove_closed.png` 를 넣으면
///   [BaseballGame.gloveOpenSprite] / [gloveClosedSprite] 가 채워지고 그림으로
///   교체된다. 없으면 아래 코드 드로잉으로 동작한다.
class Glove extends PositionComponent with HasGameReference<BaseballGame> {
  Glove() : super(priority: 20, anchor: Anchor.bottomCenter);

  /// 글러브 폭 (화면 폭 대비).
  ///
  /// 공 지름이 0.17w 이므로 이 값이 커질수록 실제 야구공-글러브 비율(약 1:4)에
  /// 가까워진다. 포구 순간이 화면에서 확실히 읽혀야 해서 넉넉하게 잡는다.
  static const double widthRatio = 0.44;

  /// 0 = 활짝 폄, 1 = 완전히 쥠.
  double closeAmount = 0;

  /// 근육이 수축 중인가 — 이 동안 공을 잡고 있다.
  bool get isHolding => _holdLeft > 0;

  double _holdLeft = 0;
  double _closeIn = 0;

  /// 닫히는 데 걸리는 시간(초). 짧아야 "잡아채는" 느낌이 난다.
  static const double closeSec = 0.09;

  /// 눈에 보이려면 최소 이만큼은 쥐고 있어야 한다.
  ///
  /// 실측 자극은 0.62~0.65초로 안정적이지만, 실측 스트림에서 검출이 부실해
  /// 짧은 값이 들어올 수 있다. 그때도 한 프레임에 지나가 버리지 않게 바닥을 둔다.
  static const double minHoldSec = 0.2;

  /// 수축 시작 — [holdSec] 동안 쥐고 있다가 편다.
  void beginContraction(double holdSec) {
    _holdLeft = math.max(holdSec, minHoldSec);
    _closeIn = closeSec;
  }

  @override
  void onGameResize(Vector2 size) {
    super.onGameResize(size);
    // ★ 파라미터 size 는 **캔버스** 크기고, this.size 는 컴포넌트 크기다.
    //   전에 이 둘을 헷갈려 position.y 를 캔버스 높이로 계산하는 바람에
    //   세로 폰에서 1029(화면 844)가 되어 글러브가 통째로 화면 밖에 있었다.
    final canvas = size;
    final gloveSize =
        Vector2(canvas.x * widthRatio, canvas.x * widthRatio * 0.88);
    this.size = gloveSize;
    position = Vector2(canvas.x * 0.5, game.glovePlateY + gloveSize.y * 0.30);
  }

  @override
  void update(double dt) {
    super.update(dt);
    if (_holdLeft > 0) {
      // 닫히는 구간이 끝나면 수축이 이어지는 내내 완전히 쥔 상태를 유지한다.
      _closeIn = math.max(0, _closeIn - dt);
      closeAmount = 1 - (_closeIn / closeSec);
      _holdLeft -= dt;
    } else {
      // 자극이 끝나도 근육은 곧바로 풀리지 않는다(기계적 이완). 0.25초에 걸쳐
      // 서서히 펴는 것으로 그 지연을 표현한다.
      closeAmount = math.max(0, closeAmount - dt * 4);
    }
  }

  @override
  void render(Canvas canvas) {
    final sprite = closeAmount > 0.5
        ? game.gloveClosedSprite
        : game.gloveOpenSprite;
    if (sprite != null) {
      // ★ 두 스프라이트의 비율이 다르다(열림 0.92, 쥠 0.84). 같은 상자에 늘려
      //   그리면 쥘 때 글러브가 세로로 늘어나며 튄다. 각자 비율을 지키고
      //   **손목(아랫변)을 고정**해 손가락만 움직이는 것처럼 보이게 한다.
      final src = sprite.srcSize;
      final drawW = size.x;
      final drawH = drawW * src.y / src.x;
      sprite.render(
        canvas,
        position: Vector2(0, size.y - drawH),
        size: Vector2(drawW, drawH),
      );
      return;
    }
    _paintFallback(canvas);
  }

  /// 에셋 없이 그리는 글러브. 손가락부가 [closeAmount] 만큼 안으로 말린다.
  void _paintFallback(Canvas canvas) {
    final w = size.x, h = size.y;
    final leather = Paint()..color = const Color(0xFF8B5A2B);
    final dark = Paint()..color = const Color(0xFF5C3A1C);
    final edge = Paint()
      ..color = const Color(0xFF3E2713)
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.012;

    // 손바닥(주머니) — 고정
    final palm = Rect.fromLTWH(w * 0.14, h * 0.42, w * 0.72, h * 0.56);
    final palmR = RRect.fromRectAndRadius(palm, Radius.circular(w * 0.16));
    canvas.drawRRect(palmR, leather);
    canvas.drawRRect(palmR, edge);

    // 웹(엄지-검지 사이 그물)
    canvas.drawOval(
      Rect.fromLTWH(w * 0.30, h * 0.50, w * 0.40, h * 0.30),
      dark,
    );

    // 손가락 4개 — 닫힐수록 안으로 말리고 짧아 보인다.
    final curl = closeAmount;
    for (var i = 0; i < 4; i++) {
      final fx = w * (0.20 + i * 0.175);
      final baseTop = h * 0.44;
      final len = h * (0.40 - 0.22 * curl);
      final lean = (i - 1.5) * w * 0.03 * curl; // 안쪽으로 모인다
      final finger = RRect.fromRectAndRadius(
        Rect.fromLTWH(fx + lean, baseTop - len, w * 0.14, len + h * 0.06),
        Radius.circular(w * 0.07),
      );
      canvas.drawRRect(finger, leather);
      canvas.drawRRect(finger, edge);
    }

    // 닫힐 때 손바닥에 그늘 — 입체감
    if (curl > 0.05) {
      canvas.drawRRect(
        palmR,
        Paint()..color = Color.fromRGBO(0, 0, 0, 0.22 * curl),
      );
    }
  }
}
