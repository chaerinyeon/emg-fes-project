import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_app/signal/constants.dart';
import 'package:flutter_app/signal/signal_pipeline.dart';

/// 자극 검출 임계는 **한 번 정하고 끝이 아니어야 한다.**
///
/// 임계는 측정 시작 직후 [kArtifactScaleWindowMs] 한 창의 99.5백분위수로
/// 정해진다. 그 창에 몸을 뒤척인 흔적이 하나만 들어가도 임계가 그 크기에
/// 맞춰지고, 진짜 자극은 그 아래로 깔려 **세션이 끝날 때까지** 안 잡힌다.
/// 화면에는 「곧 함께 시작합니다」만 남고 아무도 이유를 모른다.
///
/// 여기서는 그 상황을 일부러 만들고, 파이프라인이 스스로 빠져나오는지 본다.

const int _fs = kDeviceSampleRateHz;

/// 자극 1발. 3ms 정점의 종 모양 + 앞쪽 아티팩트.
double _pulse(double dtMs, {required double gain}) {
  if (dtMs < 0 || dtMs >= 31.0) return 0.0;
  final artifact = dtMs < 2.0 ? -1.0 * gain * math.exp(-dtMs / 0.55) : 0.0;
  final d = dtMs - 3.0;
  final mwave = dtMs >= 1.5 ? 0.5 * gain * math.exp(-(d * d) / 9.0) : 0.0;
  return artifact + mwave;
}

/// [tMs] 에서의 ADC. [gain] 이 자극 세기다.
double _signalAt(double tMs, {required double dc, required double gain}) {
  final noise = 3.0 * math.sin(tMs * 0.71) + 2.0 * math.cos(tMs * 1.93);
  final phase = tMs % kStimPeriodMs;
  if (phase >= kStimOnMs) return dc + noise;
  return dc + noise + _pulse(phase % 31.0, gain: gain);
}

/// [durationMs] 동안 흘린다. [glitchAtMs] 가 있으면 그 시각에 아주 큰
/// 움직임 아티팩트를 한 번 섞는다 — 임계를 망가뜨리는 그 사건이다.
({List<BurstResult> bursts, SignalPipeline pipe}) _run({
  required int durationMs,
  required double gain,
  double? glitchAtMs,
  // ADC 범위(0~4095) 안이어야 한다. 1900 + 4000 = 5900 은 레일로 걸러져
  // 임계를 못 올린다 — 그건 이 테스트가 재현하려는 사건이 아니다.
  // 몸을 뒤척일 때 실제로 나오는 크기는 이 정도다.
  double glitchAmp = 2000,
}) {
  final p = SignalPipeline(fs: _fs);
  final out = <BurstResult>[];
  final n = durationMs * _fs ~/ 1000;
  for (var i = 0; i < n; i++) {
    final tMs = i * 1000.0 / _fs;
    var v = _signalAt(tMs, dc: 1900, gain: gain);
    // 폭이 좁으면 99.5백분위수를 못 밀어낸다 — 5초 창의 상위 0.5%가
    // 100표본이라 그보다 길어야 한다. 몸을 뒤척이는 아티팩트의 실제
    // 길이(~100ms)면 480표본이라 충분히 지배한다.
    if (glitchAtMs != null && (tMs - glitchAtMs).abs() < 60.0) {
      v += glitchAmp;
    }
    final r = p.addSample(i, v.round());
    if (r != null) out.add(r);
  }
  return (bursts: out, pipe: p);
}

void main() {
  _railTests();

  group('임계 한 번 잘못 잡히면 세션이 죽는다 — 그 전제를 확인한다', () {
    test('정상 신호에서는 버스트가 잡힌다', () {
      final r = _run(durationMs: 12000, gain: 900);
      expect(r.bursts, isNotEmpty);
      expect(r.pipe.detectedPulses, greaterThan(0));
    });

    test('도입부 글리치가 임계를 자극보다 높이 올린다', () {
      // 글리치는 임계 추정 창(측정 시작 후 5초) 안에 있다. 검출기는 그 창을
      // 다 채운 뒤에야 생기므로 6초까지 흘리고, 재조정 시한(8초) 전에 멈춘다.
      final r = _run(durationMs: 6000, gain: 300, glitchAtMs: 1200);

      expect(r.pipe.stimThreshold, isNotNull);
      expect(r.pipe.stimThreshold!, greaterThan(300),
          reason: '자극 진폭보다 임계가 높아졌다 — 이게 세션을 죽이는 상태다');
      expect(r.pipe.retuneCount, 0, reason: '아직 재조정 전이다');
      expect(r.bursts, isEmpty, reason: '이 상태로 두면 게임이 시작되지 않는다');
    });
  });

  group('스스로 빠져나온다', () {
    test('펄스가 0인 채 시간이 지나면 임계를 다시 잡는다', () {
      final r = _run(durationMs: 20000, gain: 300, glitchAtMs: 1200);

      expect(r.pipe.retuneCount, greaterThan(0),
          reason: '기다려서 해결될 일이 아니면 스스로 다시 잡아야 한다');
      expect(r.pipe.detectedPulses, greaterThan(0),
          reason: '다시 잡은 뒤에는 자극을 찾아야 한다');
      expect(r.bursts, isNotEmpty);
    });

    test('검출이 되고 있으면 임계를 흔들지 않는다', () {
      final r = _run(durationMs: 20000, gain: 900);
      expect(r.pipe.detectedPulses, greaterThan(0));
      expect(r.pipe.retuneCount, 0,
          reason: '잘 되는 중에 임계가 바뀌면 세기가 달라 보이고 피로로 잘못 읽힌다');
    });

    test('손으로도 다시 맞출 수 있다', () {
      final p = SignalPipeline(fs: _fs);
      // 캘리브 전에는 할 일이 없다.
      expect(p.retuneStimDetection(), isFalse);

      final n = 8000 * _fs ~/ 1000;
      for (var i = 0; i < n; i++) {
        final tMs = i * 1000.0 / _fs;
        p.addSample(i, _signalAt(tMs, dc: 1900, gain: 900).round());
      }
      expect(p.retuneStimDetection(), isTrue);
      expect(p.retuneCount, greaterThan(0));
    });
  });

  group('진단 지표', () {
    test('검출 펄스·버스트를 폐기 전 기준으로 센다', () {
      final r = _run(durationMs: 12000, gain: 900);
      expect(r.pipe.detectedPulses, greaterThan(0));
      expect(r.pipe.detectedBursts, greaterThan(0));
      // 정상 신호에서는 버리는 버스트가 없어야 한다.
      expect(r.pipe.discardedBursts, 0);
    });

    test('자극이 없으면 펄스도 0이다 — 화면이 이 둘을 구분해야 한다', () {
      final p = SignalPipeline(fs: _fs);
      final n = 12000 * _fs ~/ 1000;
      for (var i = 0; i < n; i++) {
        // 잡음만. 자극 없음.
        final tMs = i * 1000.0 / _fs;
        final v = 1900 + 3.0 * math.sin(tMs * 0.71);
        p.addSample(i, v.round());
      }
      expect(p.detectedPulses, 0);
      expect(p.discardedBursts, 0);
    });
  });
}

/// 깨진 표본(ADC 레일)이 검출을 망가뜨리지 않는다.
///
/// 2026-08-13 실기기 파일에서 0 인 표본이 0.57% 나왔다. `|0 − 1875| = 1875`
/// 는 어떤 실제 자극 아티팩트보다 커서 두 군데를 동시에 망가뜨렸다 —
/// 아티팩트 규모 백분위수를 독차지해 임계를 656 으로 올렸고, 그 자체가
/// 임계를 넘어 가짜 펄스로 잡혔다.
void _railTests() {
  /// [railEvery] 표본마다 한 번씩 ADC 0 을 섞는다.
  ({List<BurstResult> bursts, SignalPipeline pipe}) runWithRails({
    required int durationMs,
    required double gain,
    int? railEvery,
  }) {
    final p = SignalPipeline(fs: _fs);
    final out = <BurstResult>[];
    final n = durationMs * _fs ~/ 1000;
    for (var i = 0; i < n; i++) {
      final tMs = i * 1000.0 / _fs;
      final adc = (railEvery != null && i % railEvery == 0)
          ? 0
          : _signalAt(tMs, dc: 1900, gain: gain).round();
      final r = p.addSample(i, adc);
      if (r != null) out.add(r);
    }
    return (bursts: out, pipe: p);
  }

  group('깨진 표본(ADC 레일)', () {
    test('아티팩트 규모를 레일이 정하지 않는다', () {
      // 0.5% 정도 섞는다 — 실측과 같은 비율.
      final r = runWithRails(durationMs: 12000, gain: 900, railEvery: 200);
      expect(r.pipe.artifactScale, isNotNull);
      expect(r.pipe.artifactScale!, lessThan(1500),
          reason: '|0 − DC| 는 1900 이다. 그게 규모가 되면 임계가 665 로 뛴다');
    });

    test('레일이 가짜 펄스를 만들지 않는다', () {
      // 자극 없이 레일만. 펄스가 잡히면 그건 전부 가짜다.
      final r = runWithRails(durationMs: 12000, gain: 0, railEvery: 200);
      expect(r.pipe.detectedPulses, 0,
          reason: '깨진 표본이 자극으로 읽히면 주기 추정까지 흔들린다');
    });

    test('레일이 섞여도 진짜 자극은 그대로 잡는다', () {
      final clean = runWithRails(durationMs: 12000, gain: 900);
      final dirty = runWithRails(durationMs: 12000, gain: 900, railEvery: 200);

      expect(dirty.pipe.detectedBursts, greaterThan(0));
      expect(dirty.bursts, isNotEmpty);
      // 레일 때문에 버스트를 잃지 않는다.
      expect(dirty.pipe.detectedBursts,
          closeTo(clean.pipe.detectedBursts.toDouble(), 2));
    });
  });
}
