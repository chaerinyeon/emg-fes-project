import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_app/game/core_loop.dart';
import 'package:flutter_app/game/data/fatigue_feed.dart';
import 'package:flutter_app/game/data/session_fatigue_feed.dart';
import 'package:flutter_app/signal/constants.dart';

/// 손으로 돌리는 시계. 테스트가 시간을 소모하지 않게 한다.
class FakeClock {
  int ms = 100000;
  int call() => ms;
}

void main() {
  late StreamController<CueEvent> cues;
  late CoreLoop loop;
  late FakeClock clock;
  late SessionFatigueFeed feed;

  setUp(() {
    cues = StreamController<CueEvent>.broadcast();
    loop = CoreLoop();
    clock = FakeClock();
    feed = SessionFatigueFeed(
      cues: cues.stream,
      loop: loop,
      clockMs: clock.call,
    );
  });

  tearDown(() async {
    feed.dispose();
    await cues.close();
  });

  CueEvent judge({required bool? ok, required int atMs}) => CueEvent(
        type: CueEventType.judge,
        burstIndex: 1,
        atMs: atMs,
        emittedAtMs: atMs,
        contractionOk: ok,
      );

  group('수축만 게임으로 흘린다', () {
    test('확인된 수축이 포구 이벤트가 된다', () async {
      await feed.start();
      final got = <ContractionEvent>[];
      feed.contractions.listen(got.add);

      cues.add(judge(ok: true, atMs: clock.ms + 500));
      await pumpEventQueue();

      expect(got, hasLength(1));
      expect(got.single.t, closeTo(0.5, 0.001),
          reason: '게임 시계는 피드 시작을 0으로 본다');
    });

    test('확인되지 않은 수축은 포구가 아니다 — 그렇다고 실패 연출도 없다', () async {
      await feed.start();
      final got = <ContractionEvent>[];
      feed.contractions.listen(got.add);

      cues.add(judge(ok: false, atMs: clock.ms));
      cues.add(judge(ok: null, atMs: clock.ms));
      await pumpEventQueue();

      expect(got, isEmpty);
    });

    test('큐·자극·이완은 포구가 아니다', () async {
      await feed.start();
      final got = <ContractionEvent>[];
      feed.contractions.listen(got.add);

      for (final t in [
        CueEventType.cue,
        CueEventType.stimOnset,
        CueEventType.release,
      ]) {
        cues.add(CueEvent(
            type: t, burstIndex: 1, atMs: clock.ms, emittedAtMs: clock.ms));
      }
      await pumpEventQueue();

      expect(got, isEmpty);
    });

    test('잡고 있는 시간은 자극 지속시간이다', () async {
      await feed.start();
      final got = <ContractionEvent>[];
      feed.contractions.listen(got.add);

      cues.add(judge(ok: true, atMs: clock.ms));
      await pumpEventQueue();

      expect(got.single.holdSec, closeTo(kStimOnMs / 1000, 0.001),
          reason: '자극이 나가는 동안 쥐고 있어야 "잡았다"로 읽힌다');
    });
  });

  group('피로 숫자는 게임에 들어가지 않는다', () {
    test('σ 스트림은 아무것도 내지 않는다', () async {
      await feed.start();
      final now = <double>[];
      final pred = <double>[];
      feed.sigmaNow.listen(now.add);
      feed.sigmaPredicted.listen(pred.add);

      await pumpEventQueue();

      expect(now, isEmpty);
      expect(pred, isEmpty);
      // 완료 기준: 앱 어디에도 피로도 숫자가 노출되지 않는다.
      // 게임 연출(존 색)까지 피로에 묶으면 그것도 피로 표시가 된다.
    });
  });

  group('게임의 시계', () {
    test('nowSec 는 피드가 시작된 시점을 0으로 흐른다', () async {
      await feed.start();
      expect(feed.nowSec, closeTo(0, 0.001));

      clock.ms += 2500;
      expect(feed.nowSec, closeTo(2.5, 0.001));
    });

    test('다음 포구 시각은 항상 앞을 가리킨다', () async {
      await feed.start();
      loop.syncTo(
        burstIndex: 0,
        stimOnsetMs: clock.ms,
        periodMs: kStimPeriodMs.toDouble(),
      );

      final eta = feed.nextContractionEta!;
      expect(eta, greaterThan(feed.nowSec),
          reason: '지나간 시각을 주면 공이 순간이동한다');
      expect(eta, closeTo(kStimPeriodMs / 1000, 0.01));
    });

    test('주기를 모르면 예고하지 않는다', () async {
      await feed.start();
      expect(feed.nextContractionEta, isNull);
    });
  });

  group('수명', () {
    test('dispose 는 원본 큐 스트림을 닫지 않는다', () async {
      await feed.start();
      feed.dispose();

      expect(cues.isClosed, isFalse,
          reason: '게임이 사라져도 세션은 계속 돌아야 한다');
    });
  });
}
