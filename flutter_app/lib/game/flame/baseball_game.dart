import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flutter/services.dart' show AssetManifest, rootBundle;

import '../data/fatigue_feed.dart';
import '../model/zone.dart';
import 'components/ball.dart';
import 'components/catch_effect.dart';
import 'components/glove.dart';
import 'components/pitcher.dart';
import 'components/stadium.dart';

/// FES 재활용 "야구 포구" 바이오피드백 게임.
///
/// ## 이 게임에는 판정이 없다
///
/// 대상은 완전마비 환자다. 근수축을 만드는 것은 FES 고, 환자가 타이밍을 맞히거나
/// 더 세게 쥘 방법은 없다. 그래서 **판정창·점수·콤보가 전부 없다.**
/// 성공 지표는 "수축이 일어났다는 사실" 하나뿐이고, 화면이 하는 일은 그 수축을
/// 공을 잡는 장면으로 되돌려주는 것이다 — 신경가소성을 노린 되먹임이다.
///
/// ## 힘의 크기는 쓰지 않는다
///
/// 근피로는 힘 크기와 무관하게 M-wave 의 SPC σ 로만 판별한다. 게임에 들어오는
/// 것은 **수축 시각뿐**이다([ContractionEvent] 에 진폭이 없는 이유).
///
/// ## 2.5D
///
/// 3D 엔진을 쓰지 않는다. 카메라가 고정이라 스타디움은 그림 한 장이면 되고,
/// 움직이는 것은 공·글러브·투수뿐이다. 원근은 스케일 보간으로 흉내낸다.
class BaseballGame extends FlameGame {
  BaseballGame({required this.feed});

  final FatigueFeed feed;

  late final Stadium stadium;
  late final Pitcher pitcher;
  late final Glove glove;

  // ── 에셋 (없으면 컴포넌트가 코드 드로잉으로 폴백) ──────────────
  // TODO(에셋): assets/game/ 에 png 를 넣고 pubspec 에 등록하면 자동으로 쓰인다.
  Sprite? stadiumSprite;
  Sprite? gloveOpenSprite;
  Sprite? gloveClosedSprite;
  Sprite? ballSprite;
  SpriteAnimation? pitcherAnimation;

  final List<StreamSubscription<Object?>> _subs = [];

  /// 피드 기준 현재 시각(초). 공의 비행 계산이 이 시계를 쓴다.
  double feedNowSec = 0;

  /// 글러브가 공을 받는 y 좌표.
  ///
  /// 배경(assets/game/background.png)의 홈플레이트가 세로 88% 지점에 있다.
  /// 포수 시점이라 글러브는 그 바로 앞에 온다.
  double get glovePlateY => size.y * 0.82;

  /// 현재 σ / 예측 σ — HUD 가 읽는다.
  double? sigmaNow;
  double? sigmaPredicted;

  /// 지금까지 관측된 수축(=포구) 횟수. 유일한 카운터다.
  int catchCount = 0;

  /// 휴식 중인가 — 진행이 멈춘다.
  bool resting = false;

  /// 마지막 수축 시각(초).
  double? lastContractionSec;

  /// 공을 이 시각에 도착시키려고 예약해 둔 상태.
  double? _scheduledArrival;

  /// 포구 순간 화면이 반응할 수 있게 알려준다("CATCH!" 팝업 등).
  void Function()? onCatch;

  @override
  Color backgroundColor() => const Color(0xFF0D1117);

  @override
  Future<void> onLoad() async {
    await _loadOptionalAssets();

    stadium = Stadium();
    pitcher = Pitcher();
    glove = Glove();
    await addAll([stadium, pitcher, glove]);

    _subs.add(feed.contractions.listen(_onContraction));
    _subs.add(feed.sigmaNow.listen((z) {
      sigmaNow = z;
      stadium.tint = _tintFor(z);
    }));
    _subs.add(feed.sigmaPredicted.listen((z) => sigmaPredicted = z));
    await feed.start();
  }

  /// 에셋은 **있으면 쓰고 없으면 넘어간다.** 그래야 그림이 준비되기 전에도
  /// 화면 전체가 돌아가고, 나중에 파일만 넣으면 교체된다.
  ///
  /// `Sprite.load` 를 try/catch 로 감싸는 것만으로는 부족하다 — 실패가 비동기로
  /// 새어 나와 프레임워크 에러로 보고된다. 그래서 **매니페스트로 존재를 먼저
  /// 확인하고** 있는 것만 부른다.
  Future<void> _loadOptionalAssets() async {
    // Flame 은 기본으로 assets/images/ 아래를 본다. 이 프로젝트는 게임 에셋을
    // assets/game/ 에 두므로 프리픽스를 맞춰준다. (안 맞추면 PNG 를 넣어도
    // 계속 코드 드로잉이 나온다 — 조용히 실패하는 종류의 버그다.)
    images.prefix = 'assets/';

    Set<String> available;
    try {
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      available = manifest.listAssets().toSet();
    } catch (_) {
      return; // 매니페스트를 못 읽으면 전부 코드 드로잉으로 간다
    }

    Future<Sprite?> loadIfPresent(String name) async {
      if (!available.contains('${images.prefix}$name')) return null;
      return Sprite.load(name, images: images);
    }

    // background.png 를 먼저 보고, 없으면 stadium.png 로 떨어진다.
    stadiumSprite = await loadIfPresent('game/background.png') ??
        await loadIfPresent('game/stadium.png');
    gloveOpenSprite = await loadIfPresent('game/glove_open.png');
    gloveClosedSprite = await loadIfPresent('game/glove_closed.png');
    ballSprite = await loadIfPresent('game/ball.png');
  }

  /// σ 존 색을 아주 옅게 깐다. **연출 전용** — 게임 규칙에는 영향이 없다.
  Color _tintFor(double z) {
    final zone = zoneOf(z);
    final strength = switch (zone) {
      FatigueZone.normal => 0.0,
      FatigueZone.caution => 0.07,
      FatigueZone.warning => 0.14,
      FatigueZone.danger => 0.24,
    };
    return Color(zone.argb).withValues(alpha: strength);
  }

  /// 처리 대기 중인 수축. 스트림 콜백에서 바로 쓰지 않는다(아래 설명).
  final List<ContractionEvent> _pending = [];

  /// 수축 1회 검출 — 이 게임에서 유일하게 "성공"인 사건.
  ///
  /// ★ 여기서 컴포넌트 트리를 건드리지 않는다. 이 콜백은 BLE 수신처럼 프레임과
  /// 무관한 시점에 불릴 수 있어서, 곧바로 `add`/`remove` 하면 Flame 이 자식들을
  /// 순회하는 도중에 집합이 바뀌어 터진다. 큐에 넣고 [update] 에서 처리한다.
  void _onContraction(ContractionEvent e) {
    lastContractionSec = e.t;
    if (resting) return;
    _pending.add(e);
  }

  /// 큐에 쌓인 수축을 프레임 안에서 처리한다.
  void _drainContractions() {
    if (_pending.isEmpty) return;
    final events = List<ContractionEvent>.from(_pending);
    _pending.clear();

    for (final e in events) {
      catchCount++;
      // 근육이 수축하는 **동안** 쥐고 있는다. 순간적으로 닫았다 펴면
      // "잡았다"가 아니라 "스쳤다"로 보이고, 되먹임의 내용이 달라진다.
      //
      // 자극이 끝나도 근육은 곧바로 풀리지 않으므로 이완 시간을 더한다
      // (kRelaxationSec — 측정값이 아니라 가정이다).
      final hold = e.holdSec + kRelaxationSec;
      glove.beginContraction(hold);

      // 날아오던 공이 있으면 글러브 안에 들어가고, 없으면(예측이 어긋났거나 첫
      // 수축이면) 글러브만 닫힌다. 어느 쪽이든 벌점은 없다.
      final ball =
          children.whereType<Ball>().where((b) => !b.caught).firstOrNull;
      ball?.hold(holdSec: math.max(hold, Glove.minHoldSec));

      add(CatchEffect(position: Vector2(size.x * 0.5, glovePlateY)));
      onCatch?.call();
    }
  }

  @override
  void update(double dt) {
    // ★ 시계는 피드 것 하나뿐이다. 여기서 dt 를 누적하면 재생 배속과 갈라져
    //   공의 출발·도착 계산이 통째로 어긋난다. 자식(공)이 읽기 전에 갱신한다.
    feedNowSec = feed.nowSec;
    // 수축을 자식들보다 **먼저** 처리한다. 그래야 글러브가 같은 프레임에 닫힌다 —
    // 뒤로 미루면 되먹임이 한 프레임 늦고, 그 지연이 이 화면의 목적을 깎는다.
    if (!resting) _drainContractions();
    super.update(dt);
    if (resting) return;
    _sweepDeadBalls();
    _scheduleNextPitch();
  }

  /// 다음 수축 도착 시각에서 **역산해** 공을 던진다.
  ///
  /// 공이 원경에서 날아오는 데 [flightSec] 이 걸리므로 그만큼 앞서 출발해야
  /// 도착 순간과 수축 순간이 맞는다. 예측이 어긋나면 실제 수축이 온 시점에
  /// 포구가 일어나고 공은 그대로 잡힌다.
  void _scheduleNextPitch() {
    final eta = feed.nextContractionEta;
    if (eta == null) return;
    if (_scheduledArrival != null && (_scheduledArrival! - eta).abs() < 0.05) {
      return; // 이미 이 도착시각으로 던져 뒀다
    }

    final flight = _flightSec;
    if (feedNowSec < eta - flight) return; // 아직 던질 때가 아니다

    _scheduledArrival = eta;
    add(Ball(spawnSec: feedNowSec, arrivalSec: eta));
    pitcher.throwPitch();
  }

  /// 공의 비행 시간(초).
  ///
  /// 주기 1.618초 = 자극 0.629초 + 쉼 0.99초다. 이전 공을 놓아주는 시점
  /// (도착 + 0.629)에 다음 공이 출발하도록 비행시간을 쉼 구간에 맞춘다.
  /// 그래야 한 번에 하나만 날고, 던지는 순간이 곧 손을 펴는 순간이 된다.
  double get _flightSec => 0.95;

  /// 휴식 이닝 시작/종료. 치료사 판단으로 재개한다.
  void setResting(bool value) {
    resting = value;
    if (value) {
      _pending.clear();
      _clearBalls();
      _scheduledArrival = null;
    }
  }

  /// 수명이 끝난 공을 치운다.
  ///
  /// 공이 자기 update 안에서 removeFromParent() 를 불러도 실제로 지워지지 않아
  /// 글러브에 무한히 쌓였다. 부모가 직접 remove 하면 정상 처리된다.
  void _sweepDeadBalls() {
    for (final b in children.whereType<Ball>().where((b) => b.isDone).toList()) {
      remove(b);
    }
  }

  /// 순회 중 제거는 컴포넌트 집합을 깨뜨린다 — 먼저 목록으로 굳힌다.
  void _clearBalls() {
    for (final b in children.whereType<Ball>().toList()) {
      b.removeFromParent();
    }
  }

  void resetSession() {
    catchCount = 0;
    sigmaNow = null;
    sigmaPredicted = null;
    lastContractionSec = null;
    _scheduledArrival = null;
    feedNowSec = 0;
    resting = false;
    _pending.clear();
    _clearBalls();
  }

  @override
  void onRemove() {
    for (final s in _subs) {
      s.cancel();
    }
    feed.dispose();
    super.onRemove();
  }
}
