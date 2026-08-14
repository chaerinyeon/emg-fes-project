import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/signal/burst_segmenter.dart';
import 'package:flutter_app/signal/constants.dart';
import 'package:flutter_app/signal/stim_detector.dart';

const int _dc = 1862;

/// 합성 세션을 만들어 detector→segmenter 로 흘린다.
///
/// [shape] 는 onset 기준 오프셋 → DC 로부터의 편차. 지정하지 않은 오프셋은 0.
class _Rig {
  _Rig({Map<int, int>? shape})
      : shape = shape ??
            const {
              0: 900, // 자극 아티팩트
              8: 400, // M-wave 양의 정점
              12: -300, // M-wave 음의 정점
            };

  final Map<int, int> shape;
  final bursts = <BurstEpoch>[];

  void run({int nBursts = 3, int period = kStimPeriodMs, int? preStimBias}) {
    final det = StimDetector(dcOffset: _dc.toDouble(), noiseSigma: 10.0);
    final seg = BurstSegmenter(dcOffset: _dc.toDouble());

    final onsets = <int>[];
    for (var b = 0; b < nBursts; b++) {
      for (var p = 0; p * 31 < kStimOnMs; p++) {
        onsets.add(b * period + p * 31);
      }
    }

    final end = nBursts * period + kStimOnMs + 200;
    for (var t = 0; t <= end; t++) {
      var v = _dc;
      for (final o in onsets) {
        final d = t - o;
        if (shape.containsKey(d)) v = _dc + shape[d]!;
        // 자극 직전 구간 오염 (실측: M-wave 피크의 20.2%)
        if (preStimBias != null && d >= -5 && d < 0) v = _dc + preStimBias;
      }
      seg.addSample(t, v);
      final e = det.add(t, v);
      if (e != null) {
        final closed = seg.addEvent(e);
        if (closed != null) bursts.add(closed);
      }
    }
    final tail = det.flush();
    if (tail != null) {
      final closed = seg.addEvent(tail);
      if (closed != null) bursts.add(closed);
    }
    final last = seg.flush();
    if (last != null) bursts.add(last);
  }
}

void main() {
  group('BurstSegmenter [C] — 버스트 분할', () {
    test('버스트 하나가 에폭 하나로 닫힌다', () {
      final rig = _Rig()..run(nBursts: 3);
      expect(rig.bursts.length, 3);
      expect(rig.bursts.map((b) => b.index).toList(), [0, 1, 2]);
    });

    test('버스트 안의 펄스가 모두 담긴다', () {
      final rig = _Rig()..run(nBursts: 3);
      // 591ms ON, 31ms 간격 → 20발 (p*31 < 591 → p=0..19)
      for (final b in rig.bursts) {
        expect(b.pulses.length, 20);
      }
    });

    test('버스트 onset은 첫 펄스의 자극 시점이다', () {
      final rig = _Rig()..run(nBursts: 3);
      expect(rig.bursts[0].onsetMs, 0);
      expect(rig.bursts[1].onsetMs, kStimPeriodMs);
      expect(rig.bursts[2].onsetMs, 2 * kStimPeriodMs);
    });

    test('에폭 샘플은 onset에서 시작한다', () {
      final rig = _Rig()..run(nBursts: 2);
      final p = rig.bursts.first.pulses.first;
      expect(p.onsetSample, 0);
      // fs=1000 이므로 31ms = 31 샘플. 4kHz 라면 124 가 된다.
      expect(p.samples.length, const SampleClock(kSampleRateHz).samples(kEpochLenMs));
    });
  });

  group('BurstSegmenter [D] — 에폭별 영점보정', () {
    test('영점은 자극 직전 구간에서 잡지 않는다 — 하드 제약 1 회귀', () {
      // 자극 직전 5샘플을 +200 으로 오염시킨다.
      // 영점을 거기서 잡으면 baseline 이 200 근처로 끌려간다.
      final rig = _Rig()..run(nBursts: 3, preStimBias: 200);
      final p = rig.bursts[1].pulses[5];
      expect(p.baseline.abs(), lessThan(50.0),
          reason: '자극 직전 오염(+200)이 baseline 에 새어 들어왔다');
    });

    test('영점 구간은 M-wave 창 이후다', () {
      expect(kEpochBaselineStartMs, greaterThanOrEqualTo(kMwaveWindowEndMs),
          reason: 'M-wave 를 영점으로 빼면 진폭이 깎인다');
      expect(kEpochBaselineEndMs, lessThanOrEqualTo(kEpochLenMs),
          reason: '다음 펄스 아티팩트를 영점에 넣으면 안 된다');
    });

    test('에폭 샘플은 영점이 빠진 값이다', () {
      // 영점 구간(18~28ms)에 일정한 +120 오프셋을 준다.
      final rig = _Rig(shape: {
        0: 900,
        8: 400,
        12: -300,
        for (var i = kEpochBaselineStartMs; i < kEpochBaselineEndMs; i++)
          i: 120,
      })
        ..run(nBursts: 3);

      final p = rig.bursts[1].pulses[5];
      expect(p.baseline, closeTo(120.0, 1e-9));
      // 영점을 뺐으므로 해당 구간은 0 근처
      expect(p.samples[kEpochBaselineStartMs].abs(), lessThan(1e-9));
    });

    test('영점 선택은 p2p를 바꾸지 않는다 (p2p는 오프셋 불변)', () {
      final a = _Rig()..run(nBursts: 3);
      final b = _Rig()..run(nBursts: 3, preStimBias: 200);

      double p2p(BurstEpoch e, int i) {
        final s = e.pulses[i].samples.sublist(
            kMwaveWindowStartMs, kMwaveWindowEndMs);
        return s.reduce((x, y) => x > y ? x : y) -
            s.reduce((x, y) => x < y ? x : y);
      }

      expect(p2p(a.bursts[1], 5), closeTo(p2p(b.bursts[1], 5), 1e-9));
    });
  });

  group('BurstSegmenter — 경계 처리', () {
    test('flush가 마지막 버스트를 내보낸다', () {
      final rig = _Rig()..run(nBursts: 1);
      expect(rig.bursts.length, 1);
    });

    test('에폭이 링버퍼를 넘어가면 해당 펄스는 버린다', () {
      // 링 용량보다 긴 공백 뒤의 펄스는 샘플을 구할 수 없어야 정상 처리
      final seg = BurstSegmenter();
      for (var t = 0; t < 10; t++) {
        seg.addSample(t, _dc);
      }
      final e = seg.addEvent(const StimEvent(
          tSample: 5, peakAbs: 900, isBurstStart: true, burstIndex: 0));
      expect(e, isNull);
      final closed = seg.flush();
      // onset+31 까지의 샘플이 없으므로 유효 펄스 0개
      expect(closed?.pulses ?? const [], isEmpty);
    });
  });
}
