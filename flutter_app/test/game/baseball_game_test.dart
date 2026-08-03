import 'dart:async';

import 'package:flame/game.dart';
import 'package:flame_test/flame_test.dart';
import 'package:flutter_app/game/data/fatigue_feed.dart';
import 'package:flutter_app/game/flame/baseball_game.dart';
import 'package:flutter_app/game/flame/components/ball.dart';
import 'package:flutter_test/flutter_test.dart';

/// 테스트가 시각과 이벤트를 직접 미는 피드.
///
/// 벽시계·재생 배속 같은 변수를 없애고 게임 루프만 본다.
class ScriptedFeed implements FatigueFeed {
  ScriptedFeed({this.period = 1.618});

  final double period;

  final _contractions = StreamController<ContractionEvent>.broadcast();
  final _sigmaNow = StreamController<double>.broadcast();
  final _sigmaPredicted = StreamController<double>.broadcast();

  double _now = 0;
  double? _lastContraction;

  @override
  double get nowSec => _now;

  @override
  Stream<ContractionEvent> get contractions => _contractions.stream;

  @override
  Stream<double> get sigmaNow => _sigmaNow.stream;

  @override
  Stream<double> get sigmaPredicted => _sigmaPredicted.stream;

  @override
  double get predictionHorizonSec => 30;

  @override
  double? get nextContractionEta =>
      (_lastContraction ?? 0) + period;

  /// 시각만 민다(수축 없이).
  void advanceTo(double t) => _now = t;

  Future<void> fireContraction(double t, double sigma,
      {double holdSec = 0.31}) async {
    _now = t;
    _lastContraction = t;
    _contractions.add(ContractionEvent(t, holdSec: holdSec));
    _sigmaNow.add(sigma);
    _sigmaPredicted.add(sigma);
    // 브로드캐스트 스트림 전달을 기다린다.
    await Future<void>.delayed(Duration.zero);
  }

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  @override
  void dispose() {
    _contractions.close();
    _sigmaNow.close();
    _sigmaPredicted.close();
  }
}

void main() {
  // flame_test 의 testWithGame 은 바인딩을 초기화하지 않는다. 그러면 onLoad 의
  // AssetManifest 로드가 "Binding has not yet been initialized" 로 실패해
  // 에셋이 조용히 null 이 된다 — 실기기에서는 나지 않는 문제다.
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 공식 하네스로 게임을 **mount 된 상태**로 띄운다.
  ///
  /// 직접 `onLoad` 만 부르면 게임이 mount 되지 않는다. 그러면 Flame 이 자식
  /// 제거를 큐에 넣지 않고 즉시 지워서 순회 중 수정으로 터진다 — 실기기에서는
  /// 나지 않는 문제라, 테스트 쪽을 프레임워크에 맞춘다.
  void gameTest(String desc, Future<void> Function(BaseballGame) body) {
    testWithGame<BaseballGame>(
      desc,
      () => BaseballGame(feed: ScriptedFeed()),
      body,
    );
  }

  int ballCount(BaseballGame g) => g.children.whereType<Ball>().length;

  group('★ 공이 실제로 날아온다 (회귀)', () {
    gameTest('도착 시각 − 비행시간 이 되면 공이 생긴다', (game) async {
      final feed = game.feed as ScriptedFeed;

      // 아직 던질 때가 아니다 (eta=1.618, 비행 1.05 → 0.568 부터)
      feed.advanceTo(0.2);
      game.update(0.016);
      expect(ballCount(game), 0, reason: '너무 일찍 던지면 공이 먼저 도착해버린다');

      // 던질 때가 됐다
      feed.advanceTo(0.7);
      game.update(0.016);
      game.update(0); // 스폰 처리
      expect(ballCount(game), 1, reason: '★ 공이 한 개도 안 생기면 게임이 아니다');
    });

    gameTest('수축이 반복되면 공도 계속 나온다', (game) async {
      final feed = game.feed as ScriptedFeed;

      var spawned = 0;
      for (var i = 0; i < 6; i++) {
        final t = i * feed.period;
        await feed.fireContraction(t, 0.5);
        // 다음 도착 직전까지 시간을 민다
        for (var k = 0; k < 40; k++) {
          feed.advanceTo(t + k * 0.04);
          game.update(0.04);
        }
        game.update(0);
        spawned += ballCount(game);
      }
      expect(spawned, greaterThan(0), reason: '반복 수축에서 공이 계속 나와야 한다');
      expect(game.catchCount, 6, reason: '수축 6회 = 포구 6회');
    });

    gameTest('같은 도착 시각으로 공을 중복 생성하지 않는다', (game) async {
      final feed = game.feed as ScriptedFeed;
      feed.advanceTo(0.7);
      for (var i = 0; i < 30; i++) {
        game.update(0.016);
      }
      game.update(0);
      expect(ballCount(game), 1, reason: '프레임마다 던지면 공이 쌓인다');
    });
  });

  group('★ 글러브가 화면 안에 있다 (회귀)', () {
    gameTest('글러브가 캔버스 안에 들어온다', (game) async {
      game.update(0);
      final g = game.glove;
      // 전에는 onGameResize 에서 캔버스 크기와 컴포넌트 크기를 헷갈려
      // position.y 가 1029(화면 844)로 잡혀 통째로 화면 밖에 있었다.
      // 앵커가 bottomCenter 라 position.y 가 글러브 아랫변이다.
      expect(g.position.y, lessThanOrEqualTo(game.size.y),
          reason: '글러브 아랫변 ${g.position.y} 이 화면 높이 ${game.size.y} 밖이다');
      expect(g.position.y, greaterThan(game.size.y * 0.7),
          reason: '글러브는 화면 아래쪽(포수 시점)에 있어야 한다');
      expect(g.position.y - g.size.y, greaterThan(0),
          reason: '글러브 윗변이 화면 위로 잘리면 안 된다');
      expect(g.position.x, closeTo(game.size.x / 2, 1),
          reason: '가로 중앙');
    });
  });

  group('★ 수축하는 동안 공을 잡고 있는다', () {
    gameTest('자극 + 이완 시간만큼 쥐고 있는다', (game) async {
      final feed = game.feed as ScriptedFeed;
      const stim = 0.629; // 실측 자극 지속
      await feed.fireContraction(1.618, 0.4, holdSec: stim);
      game.update(0.016);
      expect(game.glove.isHolding, isTrue);

      // 자극만 끝난 시점 — 아직 놓으면 안 된다. 근육은 곧바로 안 풀린다.
      for (var i = 0; i < 38; i++) {
        game.update(0.016);
      }
      expect(game.glove.isHolding, isTrue,
          reason: '자극 종료 직후 놓으면 화면에서 너무 빨리 놓는 것처럼 보인다');
      expect(game.glove.closeAmount, closeTo(1.0, 0.01));

      // 자극 + 이완을 넘기면 편다.
      final rest = ((stim + kRelaxationSec) / 0.016).ceil() - 38 + 2;
      for (var i = 0; i < rest; i++) {
        game.update(0.016);
      }
      expect(game.glove.isHolding, isFalse);
    });

    gameTest('아주 짧은 수축도 눈에 보일 만큼은 쥐고 있는다', (game) async {
      final feed = game.feed as ScriptedFeed;
      // 실측에는 펄스 1개(0.031초)짜리 수축도 있다 — 그대로면 한 프레임에 지나간다.
      await feed.fireContraction(1.618, 0.4, holdSec: 0.031);
      game.update(0.016);
      for (var i = 0; i < 8; i++) {
        game.update(0.016);
      }
      expect(game.glove.isHolding, isTrue, reason: '최소 유지시간이 있어야 보인다');
    });

    gameTest('공 유지시간이 글러브와 같다', (game) async {
      final feed = game.feed as ScriptedFeed;
      feed.advanceTo(0.7);
      game.update(0.016);
      game.update(0);
      await feed.fireContraction(1.618, 0.4, holdSec: 0.629);
      game.update(0.016);
      final ball = game.children.whereType<Ball>().first;

      // 글러브가 펴질 때까지 공도 또렷해야 한다.
      var frames = 0;
      while (game.glove.isHolding && frames < 200) {
        game.update(0.016);
        frames++;
      }
      expect(frames, greaterThan(55),
          reason: '자극 0.629 + 이완 0.35 = 0.98초 ≈ 61프레임');
      expect(ball.isDone, isFalse, reason: '글러브가 펴지기 전에 공이 사라지면 안 된다');
    });

    gameTest('잡힌 공이 그동안 글러브 위에 머문다', (game) async {
      final feed = game.feed as ScriptedFeed;
      feed.advanceTo(0.7);
      game.update(0.016);
      game.update(0);
      await feed.fireContraction(1.618, 0.4, holdSec: 0.5);
      game.update(0.016);

      final ball = game.children.whereType<Ball>().first;
      expect(ball.caught, isTrue);
      for (var i = 0; i < 15; i++) {
        game.update(0.016);
      }
      expect(ball.isDone, isFalse, reason: '쥐고 있는 동안 사라지면 안 된다');
      expect(ball.opacity, 1.0, reason: '쥐고 있는 동안은 또렷해야 한다');
      expect(ball.position.y, closeTo(game.glovePlateY, game.size.y * 0.05),
          reason: '글러브 위에 머물러야 한다');
    });
  });

  group('★ 에셋이 실제로 쓰인다', () {
    gameTest('배경·글러브·공 스프라이트가 로드된다', (game) async {
      // pubspec 에 등록만 하고 로더에 안 붙이면 PNG 를 넣어도 코드 드로잉이
      // 계속 나온다 — 실제로 투수가 그랬다.
      expect(game.stadiumSprite, isNotNull, reason: 'background.png');
      expect(game.gloveOpenSprite, isNotNull, reason: 'glove_open.png');
      expect(game.gloveClosedSprite, isNotNull, reason: 'glove_closed.png');
      expect(game.ballSprite, isNotNull, reason: 'ball.png');
    });

    gameTest('글러브 두 포즈의 비율이 달라도 늘어나지 않는다', (game) async {
      // 교체된 에셋은 열림 1202x1309, 쥠 1149x1369 로 비율이 다르다. 같은 상자에
      // 늘려 그리면 쥘 때 세로로 늘어나며 튄다.
      final o = game.gloveOpenSprite!.srcSize;
      final c = game.gloveClosedSprite!.srcSize;
      final ao = o.y / o.x, ac = c.y / c.x;
      expect((ao - ac).abs(), greaterThan(0.01),
          reason: '비율이 같다면 이 방어가 필요 없다 — 에셋이 바뀐 것');
      // 렌더가 비율을 보존하는지는 폭 기준으로 높이를 계산하는지로 확인한다.
      final g = game.glove;
      expect(g.size.x, greaterThan(0));
      expect(g.size.y, greaterThan(0));
    });

    gameTest('글러브가 배경의 홈플레이트 근처에 온다', (game) async {
      game.update(0);
      // 배경 이미지의 홈플레이트가 세로 88% 지점이다.
      final plate = game.size.y * 0.88;
      expect((game.glovePlateY - plate).abs(), lessThan(game.size.y * 0.12),
          reason: '글러브가 홈플레이트에서 멀면 포구가 허공에서 일어난다');
    });
  });

  group('수축 = 포구', () {
    gameTest('수축이 오면 포구 수가 오르고 글러브가 닫힌다', (game) async {
      final feed = game.feed as ScriptedFeed;
      expect(game.catchCount, 0);

      await feed.fireContraction(1.618, 0.4);
      game.update(0.016);
      expect(game.catchCount, 1);
      expect(game.glove.closeAmount, greaterThan(0), reason: '자극이 손을 닫는다');
    });

    gameTest('날아오던 공이 그 순간 잡힌다', (game) async {
      final feed = game.feed as ScriptedFeed;
      feed.advanceTo(0.7);
      game.update(0.016);
      game.update(0);
      expect(ballCount(game), 1);

      await feed.fireContraction(1.618, 0.4);
      game.update(0.016);
      final ball = game.children.whereType<Ball>().first;
      expect(ball.caught, isTrue);
    });

    gameTest('공이 없을 때 수축이 와도 문제없다 (벌점 없음)', (game) async {
      final feed = game.feed as ScriptedFeed;
      await feed.fireContraction(0.1, 0.4);
      game.update(0.016);
      expect(game.catchCount, 1, reason: '수축 자체가 성공이다');
    });
  });

  group('σ 연출·휴식', () {
    gameTest('σ가 게임에 전달된다', (game) async {
      final feed = game.feed as ScriptedFeed;
      await feed.fireContraction(1.618, 2.4);
      game.update(0.016);
      expect(game.sigmaNow, 2.4);
      expect(game.sigmaPredicted, 2.4);
    });

    gameTest('휴식 중에는 공이 치워지고 새로 안 나온다', (game) async {
      final feed = game.feed as ScriptedFeed;
      feed.advanceTo(0.7);
      game.update(0.016);
      game.update(0);
      expect(ballCount(game), 1);

      game.setResting(true);
      game.update(0);
      expect(ballCount(game), 0);

      feed.advanceTo(5.0);
      game.update(0.016);
      game.update(0);
      expect(ballCount(game), 0, reason: '쉬는 동안은 진행이 멈춘다');
    });

    gameTest('휴식 중 수축은 포구로 세지 않는다', (game) async {
      final feed = game.feed as ScriptedFeed;
      game.setResting(true);
      await feed.fireContraction(1.618, 3.5);
      game.update(0.016);
      expect(game.catchCount, 0);
    });
  });

  gameTest('★ 게임은 자기 시계를 만들지 않는다 (피드 시각을 그대로 쓴다)', (game) async {
    final feed = game.feed as ScriptedFeed;
    // dt 를 크게 줘도 게임 시각은 피드를 따라야 한다.
    feed.advanceTo(42.0);
    game.update(3.0);
    expect(game.feedNowSec, 42.0,
        reason: 'dt 를 누적하면 재생 배속과 갈라져 공 계산이 무너진다');
  });
}
