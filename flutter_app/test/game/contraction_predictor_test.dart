import 'package:flutter_app/game/engine/burst_aggregator.dart';
import 'package:flutter_app/game/engine/contraction_predictor.dart';
import 'package:flutter_test/flutter_test.dart';

/// 실시간 동기 규칙 검증.
///
/// 공은 0.95초 전에 던져야 하는데 실시간에서는 다음 수축 시각을 모른다.
/// 그래서 "직전 수축 + 관측 주기" 로 예측하는데, 그게 언제 맞고 언제 포기해야
/// 하는지가 이 게임이 실기기에서 제대로 도는지를 가른다.
void main() {
  const period = 1.618; // 실측 중앙값
  final p = ContractionPredictor();

  double? eta({
    required double now,
    double? last,
    double periodSec = period,
  }) =>
      p.predict(nowSec: now, lastContractionSec: last, periodSec: periodSec);

  group('기본 예측', () {
    test('직전 수축 + 주기', () {
      expect(eta(now: 10.2, last: 10.0), closeTo(11.618, 1e-9));
    });

    test('첫 수축 전에는 예측하지 않는다', () {
      expect(eta(now: 5, last: null), isNull,
          reason: '근거 없이 던지면 공이 엉뚱한 때 도착한다 — 화면은 자극 대기 중으로 간다');
    });

    test('주기를 모르면 예측하지 않는다', () {
      expect(eta(now: 10, last: 9, periodSec: 0), isNull);
    });
  });

  group('★ 검출을 놓쳐도 리듬이 멈추지 않는다', () {
    test('예측이 지나갔으면 주기 단위로 민다', () {
      // 수축을 하나 놓쳐 이미 한 주기가 지나갔다.
      final e = eta(now: 12.0, last: 10.0);
      expect(e, closeTo(13.236, 1e-9), reason: '10 + 1.618×2');
      expect(e!, greaterThan(12.0), reason: '예측은 항상 미래여야 한다');
    });

    test('두 번 놓쳐도 다음 박자를 가리킨다', () {
      final e = eta(now: 13.5, last: 10.0);
      expect(e, closeTo(14.854, 1e-9), reason: '10 + 1.618×3');
    });

    test('놓친 뒤 예측이 원래 격자 위에 남는다', () {
      // 자극은 계속 1.618초 격자로 오고 있다. 검출만 놓친 것이므로 격자를
      // 벗어나면 안 된다.
      final e = eta(now: 15.0, last: 10.0)!;
      final k = (e - 10.0) / period;
      expect(k, closeTo(k.roundToDouble(), 1e-9),
          reason: '예측이 격자에서 밀리면 이후 공이 계속 어긋난다');
    });
  });

  group('자극이 멈추면 포기한다', () {
    test('3주기를 넘겨 비면 null', () {
      // 10.0 이후 5주기(≈8초) 동안 아무것도 안 왔다.
      expect(eta(now: 10 + period * 5, last: 10.0), isNull,
          reason: '꺼진 자극에 헛공을 계속 던지면 안 된다');
    });

    test('경계 — 3주기까지는 버틴다', () {
      expect(eta(now: 10 + period * 2.5, last: 10.0), isNotNull);
    });

    test('포기 기준은 조절 가능하다', () {
      final strict = ContractionPredictor(missedPeriodsBeforeGiveUp: 1);
      expect(
        strict.predict(
            nowSec: 10 + period * 2.5,
            lastContractionSec: 10.0,
            periodSec: period),
        isNull,
      );
    });
  });

  group('주기 학습 — 예측의 근거', () {
    test('관측으로 실측 주기에 수렴한다', () {
      final agg = BurstAggregator();
      var t = 0.0;
      for (var i = 0; i < 30; i++) {
        agg.addPulse(t * 1000, 1000);
        t += period;
      }
      expect(agg.periodSec, closeTo(period, 0.005));
    });

    test('관측 전에는 실측 공칭값을 쓴다', () {
      expect(BurstAggregator().periodSec, kNominalBurstPeriodSec);
    });

    test('자극이 끊겼다 재개돼도 엉뚱한 주기를 배우지 않는다', () {
      final agg = BurstAggregator();
      var t = 0.0;
      for (var i = 0; i < 10; i++) {
        agg.addPulse(t * 1000, 1000);
        t += period;
      }
      final learned = agg.periodSec;
      agg.addPulse((t + 40) * 1000, 1000); // 40초 공백 후 재개
      expect(agg.periodSec, closeTo(learned, 1e-9),
          reason: '40초를 주기로 배우면 공이 영영 안 날아온다');
    });

    test('주기가 바뀌면 몇 박자 안에 따라간다', () {
      final agg = BurstAggregator();
      var t = 0.0;
      for (var i = 0; i < 20; i++) {
        agg.addPulse(t * 1000, 1000);
        t += period;
      }
      // 치료사가 자극 주기를 2.0초로 바꿨다.
      for (var i = 0; i < 20; i++) {
        agg.addPulse(t * 1000, 1000);
        t += 2.0;
      }
      expect(agg.periodSec, closeTo(2.0, 0.02));
    });
  });

  test('★ 예측 오차가 비행시간에 비해 무시할 수준이다', () {
    // 실측 지터: min 1.615 / max 1.622 → ±3.5ms.
    const jitter = 0.0035;
    const flight = 0.95;
    expect(jitter / flight, lessThan(0.005),
        reason: '주기가 흔들리면 공 도착과 수축이 어긋난다 — 실측은 0.37%');

    final early = eta(now: 10.2, last: 10.0, periodSec: 1.615)!;
    final late = eta(now: 10.2, last: 10.0, periodSec: 1.622)!;
    expect((late - early).abs(), lessThan(0.01));
  });
}
