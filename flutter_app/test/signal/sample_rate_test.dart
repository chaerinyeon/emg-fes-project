import 'dart:math' as math;

import 'package:flutter_app/signal/constants.dart';
import 'package:flutter_app/signal/signal_pipeline.dart';
import 'package:flutter_test/flutter_test.dart';

/// 샘플레이트 독립성 — 펌웨어가 1kHz→4kHz 로 올라가도 신호엔진이 같은 결론을
/// 내야 한다.
///
/// ## 왜 이 테스트가 필요한가
///
/// 파이프라인의 시간축은 오래도록 "1샘플 = 1ms" 였다. 링버퍼 인덱스가 곧
/// 밀리초였고([BurstSegmenter]), M-wave 창은 `samples[5..15]` 로 잘랐다.
/// 4kHz 입력을 그대로 먹이면 **에러 없이** 창이 자극 후 1.25~3.75ms 로 밀린다 —
/// M-wave 가 아니라 자극 아티팩트를 재게 되고, 아무도 그걸 눈치채지 못한다.
///
/// 그래서 같은 물리 신호를 두 레이트로 샘플링해 결과를 맞대 본다. 오프라인
/// 데이터셋(64세션)은 영원히 1kHz 이므로 **두 레이트를 모두 지원해야 한다.**

/// 자극 1발의 파형 — 자극 시점 기준 경과 [dtMs] 밀리초에서의 값.
///
/// 2026-07-17 STA 실측 평균파형을 모사한다.
///   0ms=−1042 · 1ms=−585 · 2ms=+362 · 3ms=+546(정점) · 4ms=+493 · 5ms=+352
/// 0~1ms 는 자극의 용량성 스파이크, 2~15ms 가 M-wave 본체다.
double _pulseShape(double dtMs) {
  if (dtMs < 0 || dtMs >= 31.0) return 0.0;
  // 자극 아티팩트 — 큰 음의 스파이크가 ~1.5ms 만에 사그라든다.
  final artifact = dtMs < 2.0 ? -1100.0 * math.exp(-dtMs / 0.55) : 0.0;
  // M-wave — 3ms 정점의 종 모양, 15ms 쯤 바닥.
  final d = dtMs - 3.0;
  final mwave = dtMs >= 1.5 ? 560.0 * math.exp(-(d * d) / 9.0) : 0.0;
  return artifact + mwave;
}

/// 시각 [tMs] 에서의 ADC 값. **표본이 아니라 연속 함수** — 두 레이트가 같은
/// 물리 신호를 보게 하려면 시간의 함수여야 한다.
double _signalAt(double tMs, {required double dc}) {
  // 결정적 잡음. Random 을 쓰면 두 레이트가 다른 잡음을 보게 된다.
  final noise = 3.0 * math.sin(tMs * 0.71) + 2.0 * math.cos(tMs * 1.93);

  final phase = tMs % kStimPeriodMs;
  if (phase >= kStimOnMs) return dc + noise; // 쉼 구간

  // 버스트 안: 31ms 간격 펄스열.
  const isi = 31.0;
  final since = phase % isi;
  return dc + noise + _pulseShape(since);
}

/// [fs] Hz 로 [durationMs] 만큼 샘플링해 파이프라인에 흘린다.
List<BurstResult> _runAt(int fs, int durationMs, {double dc = 1900.0}) {
  final p = SignalPipeline(fs: fs);
  final out = <BurstResult>[];
  final n = durationMs * fs ~/ 1000;
  for (var i = 0; i < n; i++) {
    final tMs = i * 1000.0 / fs;
    final adc = _signalAt(tMs, dc: dc).round();
    final r = p.addSample(i, adc);
    if (r != null) out.add(r);
  }
  out.addAll(p.flush());
  return out;
}

void main() {
  group('샘플레이트 독립성', () {
    const durationMs = 16000; // 약 10 버스트

    test('기본 fs 는 1000 — 기존 호출부가 그대로 돈다', () {
      expect(SignalPipeline().fs, kSampleRateHz);
      expect(kSampleRateHz, 1000);
    });

    test('1kHz 와 4kHz 가 같은 수의 버스트를 낸다', () {
      final a = _runAt(1000, durationMs);
      final b = _runAt(4000, durationMs);

      expect(a.length, greaterThan(5), reason: '1kHz 에서 버스트가 나와야 한다');
      expect(b.length, a.length,
          reason: '1kHz ${a.length}개 vs 4kHz ${b.length}개');
    });

    test('버스트 시각이 두 레이트에서 일치한다 (±3ms)', () {
      final a = _runAt(1000, durationMs);
      final b = _runAt(4000, durationMs);

      for (var i = 0; i < math.min(a.length, b.length); i++) {
        expect((a[i].tSeconds - b[i].tSeconds).abs(), lessThan(0.003),
            reason: '버스트 $i: 1kHz ${a[i].tSeconds}s vs 4kHz ${b[i].tSeconds}s');
      }
    });

    test('버스트당 검출 펄스 수가 일치한다 (±1)', () {
      final a = _runAt(1000, durationMs);
      final b = _runAt(4000, durationMs);

      for (var i = 0; i < math.min(a.length, b.length); i++) {
        expect((a[i].eventsInBurst - b[i].eventsInBurst).abs(), lessThanOrEqualTo(1),
            reason: '버스트 $i: 1kHz ${a[i].eventsInBurst} vs '
                '4kHz ${b[i].eventsInBurst}');
      }
    });

    // 4kHz 는 같은 창을 4배 촘촘히 보므로 p2p 가 조금 더 크게 잡힌다(진짜
    // 극값을 놓칠 확률이 줄어든다). 방향이 반대이거나 배수로 벌어지면
    // 창이 어긋난 것이다.
    test('M-wave p2p 가 두 레이트에서 같은 크기대다 (±20%)', () {
      final a = _runAt(1000, durationMs);
      final b = _runAt(4000, durationMs);

      for (var i = 0; i < math.min(a.length, b.length); i++) {
        final lo = math.min(a[i].p2pRaw, b[i].p2pRaw);
        final hi = math.max(a[i].p2pRaw, b[i].p2pRaw);
        expect(hi / lo, lessThan(1.20),
            reason: '버스트 $i: 1kHz ${a[i].p2pRaw.toStringAsFixed(0)} vs '
                '4kHz ${b[i].p2pRaw.toStringAsFixed(0)}');
      }
    });

    // 창이 밀리면 가장 먼저 무너지는 지점. 자극 아티팩트(0~1ms, 진폭 ~1100)를
    // M-wave(정점 ~560)로 착각하면 p2p 가 1500 넘게 튄다.
    test('4kHz 에서 자극 아티팩트를 M-wave 로 착각하지 않는다', () {
      final b = _runAt(4000, durationMs);
      expect(b, isNotEmpty);
      for (final r in b) {
        expect(r.p2pRaw, lessThan(1200.0),
            reason: 'p2p ${r.p2pRaw.toStringAsFixed(0)} — '
                '아티팩트(~1100)가 창에 들어왔다');
      }
    });

    test('추정 자극 주기는 fs 와 무관하게 ms 단위로 같다', () {
      for (final fs in [1000, 4000]) {
        final p = SignalPipeline(fs: fs);
        final n = 3 * kStimPeriodMs * fs ~/ 1000 + fs * 6;
        for (var i = 0; i < n; i++) {
          p.addSample(i, _signalAt(i * 1000.0 / fs, dc: 1900.0).round());
        }
        p.flush();
        final period = p.periodMs;
        expect(period, isNotNull, reason: 'fs=$fs 에서 주기 추정 실패');
        expect((period! - kStimPeriodMs).abs(), lessThan(40),
            reason: 'fs=$fs 주기 $period ms');
      }
    });
  });
}
