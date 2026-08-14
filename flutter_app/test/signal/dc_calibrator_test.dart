import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/signal/constants.dart';
import 'package:flutter_app/signal/dc_calibrator.dart';

void main() {
  // 캘리브 창은 **시간**으로 정의된다(무자극 1~2초). 표본 개수로 세면 4kHz 에서
  // 창이 375ms 로 쪼그라든다 — 표본 수는 그대로라 통계는 멀쩡해 보이지만,
  // 자극 주기(1618ms = ON 591 + OFF 1027)에 비해 너무 짧아진다. 375ms 창은
  // 쉼 구간 안에 통째로 들어갈 수 있어서, 자극이 돌고 있는데도 "조용하다"고
  // 답하게 된다. 전극 판정의 근거 하나가 조용히 무력화되는 것이다.
  group('DcCalibrator — 샘플레이트', () {
    test('fs=1000 이면 창은 kDcCalibWindowMs 표본이다', () {
      final c = DcCalibrator();
      for (var i = 0; i < kDcCalibWindowMs - 1; i++) {
        c.add(1862);
      }
      expect(c.isCalibrated, isFalse);
      c.add(1862);
      expect(c.isCalibrated, isTrue);
    });

    test('fs=4000 이면 같은 시간을 채우는 데 4배의 표본이 든다', () {
      final c = DcCalibrator(clock: const SampleClock(4000));
      const need = kDcCalibWindowMs * 4;
      for (var i = 0; i < need - 1; i++) {
        c.add(1862);
      }
      expect(c.isCalibrated, isFalse, reason: '아직 1500ms 가 안 찼다');
      c.add(1862);
      expect(c.isCalibrated, isTrue);
    });

    // 이 테스트가 버그의 본체다. 자극이 창의 뒤쪽(1200ms 지점)에 있으면
    // 375ms 짜리 창은 그것을 아예 못 본다.
    test('fs=4000 에서 창 뒤쪽의 자극도 잡아낸다', () {
      final c = DcCalibrator(clock: const SampleClock(4000));
      const fs = 4000;
      final need = kDcCalibWindowMs * fs ~/ 1000; // 1500ms 분량
      final artifactAt = 1200 * fs ~/ 1000; // 1200ms 지점
      for (var i = 0; i < need; i++) {
        c.add(i == artifactAt ? 3000 : 1862);
      }
      expect(c.isCalibrated, isTrue);
      expect(c.looksQuiet, isFalse,
          reason: '1200ms 의 자극이 창 안에 들어와야 한다');
    });

    test('창 길이가 최소 표본 수 밑으로 내려가지 않는다', () {
      // 극단적으로 낮은 fs 에서도 중앙값·MAD 를 낼 만큼은 모은다.
      final c = DcCalibrator(clock: const SampleClock(50));
      for (var i = 0; i < kDcCalibMinSamples - 1; i++) {
        c.add(1862);
      }
      expect(c.isCalibrated, isFalse);
      c.add(1862);
      expect(c.isCalibrated, isTrue);
    });
  });

  group('DcCalibrator [A]', () {
    test('is not calibrated before the window is filled', () {
      final c = DcCalibrator();
      for (var i = 0; i < kDcCalibMinSamples - 1; i++) {
        c.add(1862);
      }
      expect(c.isCalibrated, isFalse);
      expect(c.offset, isNull);
    });

    test('offset은 조용한 창의 중앙값(=평균)이다', () {
      final c = DcCalibrator();
      // 1850 과 1870 을 번갈아 → 평균 1860
      for (var i = 0; i < kDcCalibWindowMs; i++) {
        c.add(i.isEven ? 1850 : 1870);
      }
      expect(c.isCalibrated, isTrue);
      expect(c.offset, closeTo(1860.0, 1e-9));
    });

    test('offset is not hardcoded — it tracks whatever the session baseline is',
        () {
      // 하드코딩 DC_OFFSET = 1862 가 과거 오류 원인이었다.
      // 기기·세션마다 다른 baseline 을 그대로 따라가야 한다.
      for (final baseline in [1723.0, 1862.0, 1954.0]) {
        final c = DcCalibrator();
        for (var i = 0; i < kDcCalibWindowMs; i++) {
          c.add(baseline.round());
        }
        expect(c.offset, closeTo(baseline, 1e-9));
      }
    });

    test('noiseSigma는 MAD 기반 산포다', () {
      final c = DcCalibrator();
      // ±10 구형파 → 중앙값 1860, MAD 10 → sigma = 10 × 1.4826
      for (var i = 0; i < kDcCalibWindowMs; i++) {
        c.add(i.isEven ? 1850 : 1870);
      }
      expect(c.noiseSigma, closeTo(10.0 * kMadToSigma, 1e-9));
    });

    test('noiseSigma of a pure-DC window is zero', () {
      final c = DcCalibrator();
      for (var i = 0; i < kDcCalibWindowMs; i++) {
        c.add(1862);
      }
      expect(c.noiseSigma, closeTo(0.0, 1e-9));
    });

    test('flags a window that contains stimulation artifact as unusable', () {
      final c = DcCalibrator();
      final rnd = math.Random(7);
      for (var i = 0; i < kDcCalibWindowMs; i++) {
        // 조용한 구간 + 한가운데 자극 아티팩트 한 방
        final quiet = 1860 + rnd.nextInt(11) - 5;
        c.add(i == kDcCalibWindowMs ~/ 2 ? 3000 : quiet);
      }
      expect(c.isCalibrated, isTrue,
          reason: '창은 채워졌다');
      expect(c.looksQuiet, isFalse,
          reason: '자극이 섞인 구간을 조용하다고 보면 임계가 통째로 틀어진다');
    });

    test('a genuinely quiet window is reported as quiet', () {
      final c = DcCalibrator();
      final rnd = math.Random(11);
      for (var i = 0; i < kDcCalibWindowMs; i++) {
        c.add(1860 + rnd.nextInt(11) - 5);
      }
      expect(c.looksQuiet, isTrue);
    });

    test('자극이 섞인 창에서도 offset이 baseline을 지킨다', () {
      // 오프라인 raw CSV 는 무자극 도입부가 없다 — t=0 부터 이미 자극 중이다.
      // 실측 raw_20260717_144215.csv: 첫 1500샘플 min=880 max=2559.
      final c = DcCalibrator();
      final rnd = math.Random(3);
      for (var i = 0; i < kDcCalibWindowMs; i++) {
        // 31ms 마다 자극 아티팩트 ±900
        if (i % 31 == 0) {
          c.add(1860 + 900);
        } else if (i % 31 == 12) {
          c.add(1860 - 900);
        } else {
          c.add(1860 + rnd.nextInt(11) - 5);
        }
      }
      expect(c.offset, closeTo(1860.0, 3.0),
          reason: '아티팩트가 offset 을 끌고 가면 이후 전 구간이 틀어진다');
    });

    test('자극이 섞인 창에서도 noise 추정이 부풀지 않는다', () {
      // 이게 부풀면 검출 임계가 아티팩트보다 높아져 버스트를 통째로 놓친다.
      final c = DcCalibrator();
      final rnd = math.Random(5);
      for (var i = 0; i < kDcCalibWindowMs; i++) {
        if (i % 31 == 0) {
          c.add(1860 + 900);
        } else if (i % 31 == 12) {
          c.add(1860 - 900);
        } else {
          c.add(1860 + rnd.nextInt(11) - 5);
        }
      }
      // 조용한 부분의 실제 산포는 ±5 수준이다.
      expect(c.noiseSigma, lessThan(30.0),
          reason: '아티팩트를 잡음으로 세면 임계가 900을 넘어 검출이 0이 된다');
    });

    test('extra samples after calibration do not move the offset', () {
      final c = DcCalibrator();
      for (var i = 0; i < kDcCalibWindowMs; i++) {
        c.add(1860);
      }
      final before = c.offset;
      for (var i = 0; i < 5000; i++) {
        c.add(3000); // 자극 시작
      }
      expect(c.offset, equals(before));
    });

    test('reset allows recalibration for a new session', () {
      final c = DcCalibrator();
      for (var i = 0; i < kDcCalibWindowMs; i++) {
        c.add(1860);
      }
      c.reset();
      expect(c.isCalibrated, isFalse);
      expect(c.offset, isNull);
    });
  });
}
