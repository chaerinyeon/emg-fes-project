import 'dart:math' as math;
import 'dart:ui';

import 'package:flame/components.dart';

import '../baseball_game.dart';

/// 날아오는 야구공.
///
/// 2.5D 원근을 **크기와 위치 보간으로 흉내낸다.** 원경(작게, 위쪽)에서 홈(크게,
/// 아래쪽)으로 오면서 커지고, 살짝 포물선을 그린다. 3D 지오메트리는 없다.
///
/// 도착 시각은 **다음 수축 이벤트 시각**이다. 스킬 판정이 없으므로 이 공은
/// 맞히라고 있는 게 아니라, 자기 근육이 수축하는 순간을 눈에 보이게 만드는
/// 장치다 — 수축과 포구가 같은 순간에 일어나야 되먹임이 성립한다.
class Ball extends PositionComponent with HasGameReference<BaseballGame> {
  Ball({required this.spawnSec, required this.arrivalSec})
      : super(priority: 10, anchor: Anchor.center);

  /// 던져진 시각(초).
  final double spawnSec;

  /// 글러브에 닿는 시각(초) = 수축 이벤트 시각.
  double arrivalSec;

  /// 글러브에 잡혔는가.
  bool caught = false;

  /// 잡고 있는 동안 남은 시간(초). 근육이 수축하는 만큼 쥐고 있는다.
  double _holdLeft = 0;

  double _fade = 1.0;

  /// 수명이 끝났는가 — 게임이 이걸 보고 치운다.
  ///
  /// 컴포넌트가 자기 update 안에서 removeFromParent() 를 부르는 방식은 이
  /// 프로젝트에서 신뢰할 수 없었다(호출은 되는데 실제로 안 지워져 공이 글러브에
  /// 무한히 쌓였다). 판단만 여기서 하고 제거는 게임이 한다.
  bool get isDone => _dead;
  bool _dead = false;

  /// 화면에 그릴 때의 불투명도.
  double get opacity => _fade.clamp(0.0, 1.0);

  /// 포구 — [holdSec] 동안 글러브 안에 머문 뒤 사라진다.
  ///
  /// 순간적으로 사라지면 "잡았다"가 아니라 "스쳤다"로 보인다. 근육이 수축하는
  /// 동안 공이 손에 있는 것이 이 화면이 돌려주려는 되먹임이다.
  void hold({required double holdSec}) {
    caught = true;
    _holdLeft = holdSec;
  }

  static const double _minScale = 0.12;
  static const double _maxScale = 1.0;

  /// 공이 출발하는 높이 (화면 높이 대비). 투수의 릴리스 지점.
  static const double releaseHeightRatio = 0.42;

  /// 도착했을 때 공의 반지름 (화면 폭 대비).
  ///
  /// 글러브 폭이 0.34w 이므로 지름 0.17w 면 글러브의 절반쯤 된다 — 실제 야구공과
  /// 글러브 비율에 가깝고, 잡히는 순간이 확실히 읽힌다.
  static const double _arrivalRadiusRatio = 0.085;

  double _progress(double now) {
    final flight = arrivalSec - spawnSec;
    if (flight <= 0) return 1;
    return ((now - spawnSec) / flight).clamp(0.0, 1.3);
  }

  @override
  void update(double dt) {
    super.update(dt);
    final w = game.size.x, h = game.size.y;
    final p = _progress(game.feedNowSec);

    // 원근: 진행도의 제곱에 가깝게 커져야 "빠르게 다가오는" 느낌이 난다.
    final s = _minScale + (_maxScale - _minScale) * math.pow(p, 2.2).toDouble();
    final r = w * _arrivalRadiusRatio * s;
    size = Vector2.all(r * 2);

    // 투수 → 글러브. 살짝 좌우로 흔들어 궤적을 만든다.
    // 투수는 마운드(세로 50%)에 서 있고 키가 0.19w 이라 릴리스 지점이 대략
    // 세로 42% 다. 거기서 출발해야 공이 손에서 나오는 것처럼 보이고, 비행
    // 거리도 21% 길어져 다가오는 게 눈에 들어온다.
    final fromY = h * releaseHeightRatio, toY = game.glovePlateY;
    final sway = math.sin(p * math.pi) * w * 0.05;
    position = Vector2(
      w * 0.5 + sway,
      fromY + (toY - fromY) * math.pow(p, 1.6).toDouble(),
    );

    if (caught) {
      // 잡고 있는 동안은 글러브 위에 고정. 크기도 도착 크기로 유지한다.
      final r = w * _arrivalRadiusRatio * _maxScale;
      size = Vector2.all(r * 2);
      position = Vector2(w * 0.5, game.glovePlateY - r * 0.35);
      if (_holdLeft > 0) {
        _holdLeft -= dt;
        return; // 아직 쥐고 있다
      }
      _fade -= dt * 3.2;
      if (_fade <= 0) _dead = true;
    } else if (p >= 1.3) {
      // 수축이 안 와서 지나쳐 버린 공 — "놓침" 연출로만 쓰이고 벌점은 없다.
      _dead = true;
    }
  }

  @override
  void render(Canvas canvas) {
    // 수명이 끝났으면 그리지 않는다. 제거가 한 프레임 늦어도 화면에는 안 남는다
    // — 이 프로젝트에서 컴포넌트 제거 타이밍이 신뢰할 수 없었던 적이 있다.
    if (_dead) return;
    final r = size.x / 2;
    final o = Offset(r, r);
    final a = opacity;

    final sprite = game.ballSprite;
    if (sprite != null) {
      // 그림자를 먼저 깔아 공이 배경에 떠 있지 않게 한다.
      canvas.drawCircle(
        o.translate(r * 0.16, r * 0.2),
        r * 0.95,
        Paint()..color = Color.fromRGBO(0, 0, 0, 0.22 * a),
      );
      sprite.render(
        canvas,
        size: size,
        overridePaint: Paint()..color = Color.fromRGBO(255, 255, 255, a),
      );
      return;
    }

    // 그림자 — 공이 클수록(가까울수록) 진하게
    canvas.drawCircle(
      o.translate(r * 0.18, r * 0.22),
      r,
      Paint()..color = Color.fromRGBO(0, 0, 0, 0.25 * a),
    );
    canvas.drawCircle(
      o,
      r,
      Paint()..color = Color.fromRGBO(245, 242, 234, a),
    );

    // 실밥 두 줄 — 작을 땐 생략(어차피 안 보이고 비용만 든다)
    if (r > 6) {
      final seam = Paint()
        ..color = Color.fromRGBO(200, 50, 43, a)
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1, r * 0.11);
      for (final side in [-1.0, 1.0]) {
        canvas.drawArc(
          Rect.fromCircle(center: o.translate(side * r * 0.85, 0), radius: r),
          side > 0 ? math.pi * 0.72 : -math.pi * 0.28,
          math.pi * 0.56,
          false,
          seam,
        );
      }
    }
  }
}
