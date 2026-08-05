import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/session/end_conditions.dart';
import 'package:flutter_app/signal/constants.dart';

/// 버스트를 n개 흘린다.
void feed(
  EndConditionEvaluator e, {
  required int n,
  double fatigue = 0,
  bool ok = true,
  bool reliable = true,
  double startS = 60,
}) {
  for (var i = 0; i < n; i++) {
    e.addBurst(
      fatiguePct: fatigue,
      contractionOk: ok,
      reliable: reliable,
      tSeconds: startS + i * kStimPeriodMs / 1000.0,
    );
  }
}

void main() {
  group('종료 코드 — 공통 컨텍스트 5장', () {
    test('DB enum 문자열이 스펙과 정확히 일치한다', () {
      expect(SessionEndReason.fatigueThreshold.code, 'fatigue_threshold');
      expect(SessionEndReason.successRateDrop.code, 'success_rate_drop');
      expect(SessionEndReason.gameComplete.code, 'game_complete');
      expect(SessionEndReason.timeout.code, 'timeout');
      expect(SessionEndReason.userStop.code, 'user_stop');
      expect(SessionEndReason.remoteStop.code, 'remote_stop');
      expect(SessionEndReason.signalLost.code, 'signal_lost');
      expect(SessionEndReason.deviceDisconnect.code, 'device_disconnect');
      expect(SessionEndReason.error.code, 'error');
    });

    test('9종이 전부 있다 — 사유를 뭉뚱그리지 않는다', () {
      expect(SessionEndReason.values.length, 9);
    });
  });

  group('1순위 — 적응형 피로 임계', () {
    test('임계가 null이면 피로로는 끝나지 않는다', () {
      expect(kFatigueThresholdPct, isNull,
          reason: 'P0 확정 전이다. 이 테스트는 확정되면 바뀐다');

      final e = EndConditionEvaluator();
      feed(e, n: 500, fatigue: 99);
      expect(e.triggered, isNot(SessionEndReason.fatigueThreshold));
    });

    test('임계가 정해지면 연속 N버스트에서 발동한다', () {
      final e = EndConditionEvaluator(fatigueThresholdPct: 25);
      feed(e, n: kFatigueConsecutiveBursts - 1, fatigue: 30);
      expect(e.triggered, isNull);

      feed(e, n: 1, fatigue: 30);
      expect(e.triggered, SessionEndReason.fatigueThreshold);
    });

    test('중간에 임계 아래로 내려가면 연속 카운터가 리셋된다', () {
      final e = EndConditionEvaluator(fatigueThresholdPct: 25);
      feed(e, n: kFatigueConsecutiveBursts - 1, fatigue: 30);
      feed(e, n: 1, fatigue: 10);
      feed(e, n: kFatigueConsecutiveBursts - 1, fatigue: 30);
      expect(e.triggered, isNull);
    });

    test('신뢰도가 깨진 버스트는 피로 판정에 쓰지 않는다', () {
      // events/burst < 10 이면 피로도 판정 보류(공통 컨텍스트 2.4).
      final e = EndConditionEvaluator(fatigueThresholdPct: 25);
      feed(e, n: 100, fatigue: 99, reliable: false);
      expect(e.triggered, isNot(SessionEndReason.fatigueThreshold));
    });
  });

  group('2순위 — 성공률 하락 (백업)', () {
    test('백업 조건은 임계가 null이어도 동작한다', () {
      // 적응형 기준은 보수적이라 실측 58세션 중 47세션에서만 걸렸다.
      // 백업이 없으면 5~6세션에 하나꼴로 종료가 안 걸린다.
      final e = EndConditionEvaluator();
      feed(e, n: kSuccessRateWindow, ok: true);
      feed(e, n: kSuccessRateWindow, ok: false);
      expect(e.triggered, SessionEndReason.successRateDrop);
    });

    test('성공률이 유지되면 발동하지 않는다', () {
      final e = EndConditionEvaluator();
      feed(e, n: 400, ok: true);
      expect(e.triggered, isNull);
    });

    test('표본이 모자라면 판정하지 않는다', () {
      final e = EndConditionEvaluator();
      feed(e, n: kSuccessRateWindow - 1, ok: false);
      expect(e.triggered, isNull,
          reason: '초기 기준선이 잡히기 전에 끊으면 안 된다');
    });

    test('초기 대비 하락폭으로 판정한다', () {
      // 처음부터 성공률이 낮았던 세션을 "하락"으로 보면 안 된다.
      final e = EndConditionEvaluator();
      for (var i = 0; i < kSuccessRateWindow * 4; i++) {
        e.addBurst(
          fatiguePct: 0,
          contractionOk: i % 2 == 0, // 계속 50%
          reliable: true,
          tSeconds: 60 + i * 1.618,
        );
      }
      expect(e.triggered, isNull,
          reason: '내내 50%면 하락한 게 아니다');
    });
  });

  group('3순위 — 세션 시간 상한', () {
    test('상한에 도달하면 timeout이다', () {
      final e = EndConditionEvaluator();
      e.addBurst(
        fatiguePct: 0,
        contractionOk: true,
        reliable: true,
        tSeconds: kSessionMaxMin * 60 + 1,
      );
      expect(e.triggered, SessionEndReason.timeout);
    });

    test('상한 전에는 발동하지 않는다', () {
      final e = EndConditionEvaluator();
      e.addBurst(
        fatiguePct: 0,
        contractionOk: true,
        reliable: true,
        tSeconds: kSessionMaxMin * 60 - 10,
      );
      expect(e.triggered, isNull);
    });
  });

  group('외부 사건', () {
    test('사용자 중단은 즉시 걸린다', () {
      final e = EndConditionEvaluator();
      e.signal(SessionEndReason.userStop);
      expect(e.triggered, SessionEndReason.userStop);
    });

    test('기기 끊김·신호 소실·원격 중단·게임 완료가 각각 기록된다', () {
      for (final r in [
        SessionEndReason.deviceDisconnect,
        SessionEndReason.signalLost,
        SessionEndReason.remoteStop,
        SessionEndReason.gameComplete,
      ]) {
        final e = EndConditionEvaluator();
        e.signal(r);
        expect(e.triggered, r);
      }
    });

    test('외부 사건이 자동 조건을 이긴다 — 진짜 원인이 기록돼야 한다', () {
      // 장비 문제로 멈춘 걸 "피로로 멈춤"으로 적으면
      // 그 위의 모든 해석이 오염된다.
      final e = EndConditionEvaluator(fatigueThresholdPct: 25);
      feed(e, n: kFatigueConsecutiveBursts, fatigue: 30);
      expect(e.triggered, SessionEndReason.fatigueThreshold);

      final e2 = EndConditionEvaluator(fatigueThresholdPct: 25);
      e2.signal(SessionEndReason.deviceDisconnect);
      feed(e2, n: kFatigueConsecutiveBursts, fatigue: 30);
      expect(e2.triggered, SessionEndReason.deviceDisconnect);
    });

    test('첫 사건이 남는다 — 나중 것이 덮어쓰지 않는다', () {
      final e = EndConditionEvaluator();
      e.signal(SessionEndReason.userStop);
      e.signal(SessionEndReason.deviceDisconnect);
      expect(e.triggered, SessionEndReason.userStop);
    });
  });

  group('우선순위', () {
    test('피로가 성공률 하락보다 앞선다', () {
      final e = EndConditionEvaluator(fatigueThresholdPct: 25);
      feed(e, n: kSuccessRateWindow, ok: true, fatigue: 0);
      // 동시에 성립하도록: 성공 실패 + 높은 피로
      feed(e, n: kSuccessRateWindow, ok: false, fatigue: 30);
      expect(e.triggered, SessionEndReason.fatigueThreshold);
    });

    test('성공률 하락이 시간 상한보다 앞선다', () {
      // 두 조건이 **같은 버스트에서** 동시에 성립하도록 만든다.
      // 성공률 하락은 신선한 창이 다 차야 판정되므로, 마지막 한 발을
      // 시간 상한 너머에 놓는다.
      final e = EndConditionEvaluator();
      feed(e, n: kSuccessRateWindow, ok: true, startS: 1);
      feed(e, n: kSuccessRateWindow - 1, ok: false, startS: 200);
      expect(e.triggered, isNull, reason: '아직 창이 덜 찼다');

      e.addBurst(
        fatiguePct: 0,
        contractionOk: false,
        reliable: true,
        tSeconds: kSessionMaxMin * 60 + 1,
      );
      expect(e.triggered, SessionEndReason.successRateDrop);
    });
  });

  group('한 번 걸리면 유지된다', () {
    test('triggered는 래치된다', () {
      final e = EndConditionEvaluator();
      e.signal(SessionEndReason.userStop);
      feed(e, n: 10);
      expect(e.triggered, SessionEndReason.userStop);
    });
  });
}
