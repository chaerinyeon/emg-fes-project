import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/signal/constants.dart';
import 'package:flutter_app/signal/stim_detector.dart';

const int _dc = 1862;

/// 조용한 샘플 n개를 흘려 그룹을 닫는다.
List<StimEvent> _quiet(StimDetector d, int fromMs, int n) {
  final out = <StimEvent>[];
  for (var i = 0; i < n; i++) {
    final e = d.add(fromMs + i, _dc);
    if (e != null) out.add(e);
  }
  return out;
}

void main() {
  group('StimDetector [B] — 적응형 임계', () {
    test('임계는 noise RMS의 배수다 (고정 임계 1000 금지)', () {
      final d = StimDetector(dcOffset: _dc.toDouble(), noiseSigma: 100.0);
      expect(d.threshold, closeTo(100.0 * kStimThresholdNoiseMult, 1e-9));
      expect(d.threshold, isNot(1000.0));
    });

    test('noise가 비정상적으로 작으면 하한이 걸린다', () {
      final d = StimDetector(dcOffset: _dc.toDouble(), noiseSigma: 0.01);
      expect(d.threshold, closeTo(kStimThresholdFloorAdc, 1e-9));
    });

    test('아티팩트 진폭 900~1300 하단도 놓치지 않는다', () {
      // 고정 임계 1000이면 900짜리 버스트를 통째로 놓쳤다.
      final d = StimDetector(dcOffset: _dc.toDouble(), noiseSigma: 12.0);
      expect(d.threshold, lessThan(900.0));
    });

    test('캘리브 창이 유난히 조용해도 임계가 아티팩트 규모 밑으로 안 내려간다', () {
      // 실측 raw_20260721_102627.csv: σ=8.2 → 임계 65.
      // 아티팩트 900 대비 너무 낮아 M-wave·꼬리가 전부 펄스로 잡혔다
      // (epb 38.2, 25ms 미만 간격 8735건).
      final naive = StimDetector(dcOffset: _dc.toDouble(), noiseSigma: 8.2);
      expect(naive.threshold, lessThan(100.0), reason: '잡음 기준만이면 이렇게 낮다');

      final d = StimDetector(
          dcOffset: _dc.toDouble(), noiseSigma: 8.2, artifactScale: 900.0);
      expect(d.threshold, closeTo(900.0 * kArtifactScaleFrac, 1e-9));
      expect(d.threshold, greaterThan(200.0));
    });

    test('도입부가 시끄러워도 임계가 신호 최대치 위로 올라가지 않는다', () {
      // 실측 raw_20260730_205037_C_complete.csv: σ=311 → σ×8 = 2491.
      // 그 세션의 |신호−DC| 최대가 2202 라 검출이 0이 됐다 (602초 통째로 손실).
      // 임계는 잡음 배수가 아니라 **아티팩트 규모**에 묶여야 한다.
      final d = StimDetector(
          dcOffset: _dc.toDouble(), noiseSigma: 311.0, artifactScale: 1274.0);
      expect(d.threshold, closeTo(1274.0 * kArtifactScaleFrac, 1e-9));
      expect(d.threshold, lessThan(2202.0),
          reason: '임계가 신호 최대치를 넘으면 세션 전체가 검출 0이 된다');
    });

    test('불응기는 in-burst ISI(31ms)보다 작고, 아티팩트 꼬리보다 크다', () {
      expect(kPulseRefractoryMs, lessThan(31),
          reason: '31ms 간격 실제 펄스를 병합하면 안 된다');
      expect(kPulseRefractoryMs, greaterThan(kMwaveWindowEndMs),
          reason: 'M-wave 창이 새 펄스로 잡히면 한 자극이 두 번 세어진다');
    });
  });

  group('StimDetector [B] — 펄스 검출', () {
    test('임계 미만은 검출하지 않는다', () {
      final d = StimDetector(dcOffset: _dc.toDouble(), noiseSigma: 10.0);
      final events = <StimEvent>[];
      for (var t = 0; t < 200; t++) {
        final e = d.add(t, _dc + 30); // thr=80 미만
        if (e != null) events.add(e);
      }
      expect(events, isEmpty);
    });

    test('자극 시점은 그룹의 첫 교차가 아니라 argmax다', () {
      final d = StimDetector(dcOffset: _dc.toDouble(), noiseSigma: 10.0);
      final events = <StimEvent>[];
      void feed(int t, int v) {
        final e = d.add(t, v);
        if (e != null) events.add(e);
      }

      for (var t = 0; t < 100; t++) {
        feed(t, _dc);
      }
      feed(100, _dc + 100); // 첫 교차
      feed(101, _dc + 300);
      feed(102, _dc + 900); // 정점
      feed(103, _dc + 200);
      events.addAll(_quiet(d, 104, 60));

      expect(events.length, 1);
      expect(events.single.tSample, 102);
      expect(events.single.peakAbs, closeTo(900.0, 1e-9));
    });

    test('음의 아티팩트도 검출한다 (절대값 기준)', () {
      final d = StimDetector(dcOffset: _dc.toDouble(), noiseSigma: 10.0);
      final events = <StimEvent>[];
      for (var t = 0; t < 50; t++) {
        final e = d.add(t, _dc);
        if (e != null) events.add(e);
      }
      var e = d.add(50, _dc - 700);
      if (e != null) events.add(e);
      events.addAll(_quiet(d, 51, 60));

      expect(events.length, 1);
      expect(events.single.tSample, 50);
    });

    test('한 펄스의 여러 샘플은 하나의 이벤트로 묶인다', () {
      final d = StimDetector(dcOffset: _dc.toDouble(), noiseSigma: 10.0);
      final events = <StimEvent>[];
      for (var t = 0; t < 100; t++) {
        final e = d.add(t, _dc);
        if (e != null) events.add(e);
      }
      for (var t = 100; t < 106; t++) {
        final e = d.add(t, _dc + 500);
        if (e != null) events.add(e);
      }
      events.addAll(_quiet(d, 106, 60));

      expect(events.length, 1);
    });

    test('31ms 간격 펄스를 병합하지 않는다 — 불응기 버그 회귀', () {
      // MW_REFRACTORY_MS=40 > 주기 31ms 라서 자극의 50%만 검출됐던 버그.
      expect(kPulseRefractoryMs, lessThan(31),
          reason: '불응기가 in-burst ISI(31ms)보다 크면 절반을 놓친다');

      final d = StimDetector(dcOffset: _dc.toDouble(), noiseSigma: 10.0);
      final events = <StimEvent>[];
      for (var t = 0; t < 600; t++) {
        final isPulse = t >= 100 && (t - 100) % 31 == 0 && t <= 100 + 31 * 9;
        final e = d.add(t, isPulse ? _dc + 800 : _dc);
        if (e != null) events.add(e);
      }
      final tail = d.flush();
      if (tail != null) events.add(tail);

      expect(events.length, 10, reason: '10발 전부 검출되어야 한다');
      for (var i = 0; i < 10; i++) {
        expect(events[i].tSample, 100 + 31 * i);
      }
    });

    test('flush는 스트림 끝에 남은 그룹을 내보낸다', () {
      final d = StimDetector(dcOffset: _dc.toDouble(), noiseSigma: 10.0);
      for (var t = 0; t < 100; t++) {
        d.add(t, _dc);
      }
      final mid = d.add(100, _dc + 800);
      expect(mid, isNull, reason: '아직 불응기가 지나지 않았다');
      final e = d.flush();
      expect(e, isNotNull);
      expect(e!.tSample, 100);
    });
  });

  group('StimDetector [B] — 버스트 경계', () {
    test('gap이 kBurstGapMs를 넘으면 새 버스트의 시작으로 표시한다', () {
      final d = StimDetector(dcOffset: _dc.toDouble(), noiseSigma: 10.0);
      final events = <StimEvent>[];
      // 버스트1: 0, 31, 62 / 긴 공백 / 버스트2: 1618, 1649
      final pulses = <int>[0, 31, 62, 1618, 1649];
      for (var t = 0; t <= 1800; t++) {
        final e = d.add(t, pulses.contains(t) ? _dc + 800 : _dc);
        if (e != null) events.add(e);
      }
      final tail = d.flush();
      if (tail != null) events.add(tail);

      expect(events.map((e) => e.tSample).toList(), pulses);
      expect(events.map((e) => e.isBurstStart).toList(),
          [true, false, false, true, false]);
    });
  });

  group('StimDetector [B] — 주기 추정·위상', () {
    /// 합성 FES: period 마다 591ms ON, 그 안에서 31ms 간격 펄스.
    StimDetector runSynthetic({
      required int nBursts,
      int period = kStimPeriodMs,
      int jitterMs = 0,
    }) {
      final d = StimDetector(dcOffset: _dc.toDouble(), noiseSigma: 10.0);
      final pulses = <int>{};
      for (var b = 0; b < nBursts; b++) {
        final start = b * period + (jitterMs == 0 ? 0 : (b % 2) * jitterMs);
        for (var p = 0; p * 31 < kStimOnMs; p++) {
          pulses.add(start + p * 31);
        }
      }
      final end = nBursts * period + kStimOnMs + 100;
      for (var t = 0; t <= end; t++) {
        d.add(t, pulses.contains(t) ? _dc + 800 : _dc);
      }
      d.flush();
      return d;
    }

    test('버스트 간격에서 주기를 추정한다', () {
      final d = runSynthetic(nBursts: 12);
      expect(d.periodMs, isNotNull);
      expect(d.periodMs!, closeTo(kStimPeriodMs.toDouble(), 2.0));
    });

    test('버스트가 부족하면 주기를 확정하지 않는다', () {
      final d = runSynthetic(nBursts: 2);
      expect(d.periodMs, isNull);
    });

    test('탐색 범위를 벗어난 간격은 주기로 채택하지 않는다', () {
      final d = runSynthetic(nBursts: 12, period: 3000);
      expect(d.periodMs, isNull,
          reason: '3000ms는 [$kPeriodSearchMinMs, $kPeriodSearchMaxMs] 밖이다');
    });

    test('첫 자극 시점에 위상이 고정된다', () {
      final d = runSynthetic(nBursts: 12);
      expect(d.firstBurstOnsetSample, 0);
    });

    test('다음 자극 시점을 예측한다', () {
      final d = runSynthetic(nBursts: 12);
      final predicted = d.predictedNextBurstOnsetMs;
      expect(predicted, isNotNull);
      // 마지막 버스트는 11*1618 = 17798, 다음은 19416
      expect(predicted!, closeTo(12 * kStimPeriodMs.toDouble(), 3.0));
    });

    test('위상 드리프트를 보고한다', () {
      final d = runSynthetic(nBursts: 12);
      expect(d.lastDriftMs, isNotNull);
      expect(d.lastDriftMs!.abs(), lessThan(kPhaseDriftToleranceMs));
      expect(d.driftExceededCount, 0);
    });

    test('허용치를 넘는 드리프트를 카운트한다', () {
      // 주기를 1618로 고정해두고 실제 자극이 계속 밀리면 드리프트가 쌓인다.
      final d = StimDetector(dcOffset: _dc.toDouble(), noiseSigma: 10.0);
      final pulses = <int>{};
      const drifted = kStimPeriodMs + 60; // 매 버스트 60ms씩 밀림
      for (var b = 0; b < 14; b++) {
        for (var p = 0; p * 31 < kStimOnMs; p++) {
          pulses.add(b * drifted + p * 31);
        }
      }
      for (var t = 0; t <= 14 * drifted + kStimOnMs + 100; t++) {
        d.add(t, pulses.contains(t) ? _dc + 800 : _dc);
      }
      d.flush();
      // 주기 자체는 1678로 추정되므로 재동기 후 드리프트는 흡수된다.
      expect(d.periodMs!, closeTo(drifted.toDouble(), 2.0));
    });
  });
}
