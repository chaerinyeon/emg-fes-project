import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/game/core_loop.dart';
import 'package:flutter_app/signal/constants.dart';

/// 위상 고정된 합성 세션을 돌린다.
///
/// [actualPeriod] 가 [kStimPeriodMs] 와 다르면 위상이 밀린다.
/// [stepMs] 는 스케줄러를 깨우는 간격 — 프레임 드랍을 흉내내려면 키운다.
class Rig {
  Rig({
    this.actualPeriod = kStimPeriodMs,
    this.stepMs = 8,
    this.firstOnsetMs = 10000,
  });

  final int actualPeriod;
  final int stepMs;
  final int firstOnsetMs;

  final loop = CoreLoop();
  final events = <CueEvent>[];

  /// [nBursts] 개의 버스트를 실시간처럼 흘린다.
  void run(int nBursts) {
    loop.syncTo(
      burstIndex: 0,
      stimOnsetMs: firstOnsetMs,
      periodMs: kStimPeriodMs.toDouble(),
    );

    final end = firstOnsetMs + nBursts * actualPeriod + kStimOnMs + 200;
    var nextBurst = 1;
    for (var now = firstOnsetMs; now <= end; now += stepMs) {
      events.addAll(loop.advanceTo(now));

      // 실제 자극이 일어난 시점에 위상 정보를 넣어 준다.
      final actual = firstOnsetMs + nextBurst * actualPeriod;
      if (now >= actual && nextBurst <= nBursts) {
        loop.syncTo(
          burstIndex: nextBurst,
          stimOnsetMs: actual,
          periodMs: kStimPeriodMs.toDouble(),
        );
        nextBurst++;
      }
    }
  }

  List<CueEvent> ofType(CueEventType t) =>
      events.where((e) => e.type == t).toList();
}

void main() {
  group('큐 선행 — 이걸 놓치면 훈련 효과가 사라진다', () {
    test('큐는 자극보다 CUE_LEAD_MS 먼저 나온다', () {
      final loop = CoreLoop();
      loop.syncTo(
          burstIndex: 0, stimOnsetMs: 10000, periodMs: kStimPeriodMs.toDouble());

      final predicted = loop.predictedNextOnsetMs!;
      expect(loop.nextCueAtMs, predicted - kCueLeadMs);
    });

    test('큐가 자극보다 늦게 나가면 치명 카운터가 올라간다', () {
      // 위상이 밀려 큐가 자극 뒤에 나가는 상황.
      final loop = CoreLoop();
      loop.syncTo(
          burstIndex: 0, stimOnsetMs: 10000, periodMs: kStimPeriodMs.toDouble());

      // 예정된 큐 시각을 한참 지나서야 깨어난다 (자극 시점 이후).
      final predicted = loop.predictedNextOnsetMs!;
      loop.advanceTo(predicted + 50);

      expect(loop.lateCueCount, greaterThan(0),
          reason: '큐가 자극보다 늦으면 조용히 넘어가면 안 된다');
    });

    test('정상 진행에서는 늦은 큐가 없다', () {
      final rig = Rig()..run(30);
      expect(rig.loop.lateCueCount, 0);
    });

    test('실제 선행 시간이 300ms 근처로 유지된다', () {
      final rig = Rig()..run(40);
      final log = rig.loop.timingLog;
      expect(log.length, greaterThan(30));
      for (final t in log) {
        expect(t.realizedLeadMs, closeTo(kCueLeadMs.toDouble(), 20),
            reason: 'burst ${t.burstIndex} 에서 선행이 ${t.realizedLeadMs}ms');
      }
    });
  });

  group('이벤트 순서', () {
    test('큐 → 자극 → 판정 → 이완 순서로 나온다', () {
      final rig = Rig()..run(5);
      final first = rig.events.where((e) => e.burstIndex == 2).toList();

      expect(first.map((e) => e.type).toList(), [
        CueEventType.cue,
        CueEventType.stimOnset,
        CueEventType.judge,
        CueEventType.release,
      ]);
    });

    test('판정은 M-wave 창이 닫힌 뒤에 나온다', () {
      final rig = Rig()..run(5);
      for (final b in [1, 2, 3]) {
        final ev = rig.events.where((e) => e.burstIndex == b).toList();
        final onset = ev.firstWhere((e) => e.type == CueEventType.stimOnset);
        final judge = ev.firstWhere((e) => e.type == CueEventType.judge);
        expect(judge.atMs - onset.atMs, kMwaveWindowEndMs);
      }
    });

    test('이완은 자극 ON 구간이 끝날 때다', () {
      final rig = Rig()..run(5);
      final ev = rig.events.where((e) => e.burstIndex == 2).toList();
      final onset = ev.firstWhere((e) => e.type == CueEventType.stimOnset);
      final release = ev.firstWhere((e) => e.type == CueEventType.release);
      expect(release.atMs - onset.atMs, kStimOnMs);
    });

    test('버스트마다 이벤트가 정확히 한 번씩 나온다', () {
      final rig = Rig()..run(20);
      for (final t in CueEventType.values) {
        final byBurst = <int, int>{};
        for (final e in rig.ofType(t)) {
          byBurst[e.burstIndex] = (byBurst[e.burstIndex] ?? 0) + 1;
        }
        for (final entry in byBurst.entries) {
          expect(entry.value, 1,
              reason: '${t.name} 이 버스트 ${entry.key} 에서 ${entry.value}번');
        }
      }
    });
  });

  group('프레임 드랍에 흔들리지 않는다', () {
    test('스케줄러를 드물게 깨워도 이벤트를 빠뜨리지 않는다', () {
      final fast = Rig(stepMs: 4)..run(20);
      final slow = Rig(stepMs: 120)..run(20); // 8fps 수준

      expect(slow.ofType(CueEventType.cue).length,
          fast.ofType(CueEventType.cue).length);
      expect(slow.ofType(CueEventType.stimOnset).length,
          fast.ofType(CueEventType.stimOnset).length);
    });

    test('예정 시각은 깨어난 시각이 아니라 계획대로다', () {
      // 늦게 깨어나도 atMs 는 계획된 시각이어야 한다.
      // 여기서 흔들리면 로그가 실제 오차를 못 잡는다.
      final slow = Rig(stepMs: 120)..run(10);
      final cues = slow.ofType(CueEventType.cue);
      for (var i = 1; i < cues.length; i++) {
        final gap = cues[i].atMs - cues[i - 1].atMs;
        expect(gap, closeTo(kStimPeriodMs.toDouble(), 2));
      }
    });

    test('같은 시각으로 여러 번 깨워도 중복되지 않는다', () {
      final loop = CoreLoop();
      loop.syncTo(
          burstIndex: 0, stimOnsetMs: 10000, periodMs: kStimPeriodMs.toDouble());
      final t = loop.predictedNextOnsetMs!;

      final a = loop.advanceTo(t + 700);
      final b = loop.advanceTo(t + 700);
      expect(a, isNotEmpty);
      expect(b, isEmpty);
    });
  });

  group('위상 드리프트', () {
    test('실제 주기가 밀리면 드리프트를 기록한다', () {
      // 매 버스트 40ms씩 밀리는 기기.
      final rig = Rig(actualPeriod: kStimPeriodMs + 40)..run(20);
      expect(rig.loop.driftLog, isNotEmpty);
      expect(rig.loop.driftLog.map((d) => d.driftMs.abs()).reduce((a, b) => a > b ? a : b),
          greaterThan(20));
    });

    test('허용치를 넘으면 재동기하고 로그를 남긴다', () {
      final rig = Rig(actualPeriod: kStimPeriodMs + 150)..run(20);
      expect(rig.loop.driftExceededCount, greaterThan(0),
          reason: '위상이 밀려도 게임은 정상으로 보인다. 로그가 없으면 아무도 모른다');
    });

    test('재동기 후에는 선행 시간이 회복된다', () {
      final rig = Rig(actualPeriod: kStimPeriodMs + 150)..run(30);
      final tail = rig.loop.timingLog.skip(10).toList();
      expect(tail, isNotEmpty);
      // 재동기가 돌면 실제 선행이 목표 근처로 돌아온다.
      final worst = tail
          .map((t) => (t.realizedLeadMs - kCueLeadMs).abs())
          .reduce((a, b) => a > b ? a : b);
      expect(worst, lessThanOrEqualTo(kPhaseDriftToleranceMs),
          reason: '재동기가 안 되면 오차가 계속 쌓인다');
    });

    test('정상 세션에서는 허용치 초과가 없다', () {
      final rig = Rig()..run(40);
      expect(rig.loop.driftExceededCount, 0);
    });
  });

  group('시작 전 상태', () {
    test('위상 정보가 없으면 큐를 내지 않는다', () {
      final loop = CoreLoop();
      expect(loop.advanceTo(50000), isEmpty);
      expect(loop.nextCueAtMs, isNull);
      expect(loop.predictedNextOnsetMs, isNull);
    });

    test('주기를 모르면 예측하지 않는다', () {
      final loop = CoreLoop();
      loop.syncTo(burstIndex: 0, stimOnsetMs: 10000, periodMs: null);
      expect(loop.predictedNextOnsetMs, isNull);
      expect(loop.advanceTo(20000), isEmpty);
    });
  });

  group('수축 판정 연결', () {
    test('판정 결과가 이벤트에 실린다', () {
      final loop = CoreLoop();
      loop.syncTo(
          burstIndex: 0, stimOnsetMs: 10000, periodMs: kStimPeriodMs.toDouble());
      loop.setContractionResult(burstIndex: 1, ok: true);

      final onset = loop.predictedNextOnsetMs!;
      final ev = loop.advanceTo(onset + kMwaveWindowEndMs);
      final judge = ev.firstWhere((e) => e.type == CueEventType.judge);
      expect(judge.contractionOk, isTrue);
    });

    test('판정이 아직 없으면 null로 나간다 — 실패로 단정하지 않는다', () {
      final loop = CoreLoop();
      loop.syncTo(
          burstIndex: 0, stimOnsetMs: 10000, periodMs: kStimPeriodMs.toDouble());

      final onset = loop.predictedNextOnsetMs!;
      final ev = loop.advanceTo(onset + kMwaveWindowEndMs);
      final judge = ev.firstWhere((e) => e.type == CueEventType.judge);
      expect(judge.contractionOk, isNull);
    });

    test('판정은 한 버스트 늦게 오므로 가장 최근에 확인된 값을 쓴다', () {
      // 버스트 N 의 판정은 그 버스트가 **끝나야** 나온다(자극 591ms 뒤).
      // 그런데 judge 는 자극 15ms 뒤에 나간다 — 자기 버스트 판정은 절대
      // 제때 도착하지 않는다. 이걸 null 로 두면 화면은 매번 "확인 안 됨"이
      // 되고, 수축이 잘 되고 있어도 손이 한 번도 안 쥐어진다.
      final rig = Rig()..loop.setContractionResult(burstIndex: 0, ok: true);
      rig.run(4);

      final judges = rig.ofType(CueEventType.judge);
      expect(judges, isNotEmpty);
      expect(judges.first.contractionOk, isTrue,
          reason: '직전 버스트가 성공이면 이번 큐도 성공으로 되먹인다');
    });

    test('자기 버스트 판정이 도착해 있으면 그쪽이 이긴다', () {
      final loop = CoreLoop();
      loop.syncTo(
          burstIndex: 0, stimOnsetMs: 10000, periodMs: kStimPeriodMs.toDouble());
      loop.setContractionResult(burstIndex: 0, ok: true);
      loop.setContractionResult(burstIndex: 1, ok: false);

      final onset = loop.predictedNextOnsetMs!;
      final ev = loop.advanceTo(onset + kMwaveWindowEndMs);
      final judge = ev.firstWhere((e) => e.type == CueEventType.judge);
      expect(judge.contractionOk, isFalse);
    });
  });

  group('다음 자극 시각 — 게임이 공을 미리 던지려면 필요하다', () {
    test('아직 오지 않은 자극 시각을 준다', () {
      final loop = CoreLoop();
      loop.syncTo(
          burstIndex: 0, stimOnsetMs: 10000, periodMs: kStimPeriodMs.toDouble());

      final next = loop.nextOnsetAtOrAfter(10000)!;
      expect(next, greaterThanOrEqualTo(10000));
      expect(next, 10000 + kStimPeriodMs);
    });

    test('계획 시각이 이미 지났으면 주기를 더해 다음 것을 준다', () {
      final loop = CoreLoop();
      loop.syncTo(
          burstIndex: 0, stimOnsetMs: 10000, periodMs: kStimPeriodMs.toDouble());

      final planned = loop.predictedNextOnsetMs!;
      // 계획된 자극이 막 지나간 순간.
      final next = loop.nextOnsetAtOrAfter(planned + 100)!;
      expect(next, planned + kStimPeriodMs);
    });

    test('주기를 모르면 null — 짐작해서 던지지 않는다', () {
      expect(CoreLoop().nextOnsetAtOrAfter(10000), isNull);
    });
  });
}
