import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/signal/burst_segmenter.dart';
import 'package:flutter_app/signal/constants.dart';
import 'package:flutter_app/signal/mwave_extractor.dart';

PulseEpoch _epoch(Map<int, double> shape, {int onsetMs = 0}) {
  final s = List<double>.generate(
      kEpochLenMs, (d) => shape[d] ?? 0.0,
      growable: false);
  return PulseEpoch(onsetMs: onsetMs, samples: s, baseline: 0.0);
}

BurstEpoch _burst(List<double> p2ps) {
  // 각 펄스가 정확히 주어진 p2p 를 갖도록 창 안에 +v/2, -v/2 를 심는다.
  final pulses = <PulseEpoch>[];
  for (var i = 0; i < p2ps.length; i++) {
    pulses.add(_epoch({8: p2ps[i] / 2, 12: -p2ps[i] / 2}, onsetMs: i * 31));
  }
  return BurstEpoch(index: 0, onsetMs: 0, pulses: pulses);
}

void main() {
  group('MwaveExtractor [E] — 펄스별 p2p', () {
    test('창은 5~15ms, 정확히 10샘플이다', () {
      expect(kMwaveWindowEndMs - kMwaveWindowStartMs, 10,
          reason: '1kHz 이므로 5~15ms 는 10샘플');
    });

    test('p2p는 창 안의 최대−최소다', () {
      final e = _epoch({8: 400.0, 12: -300.0});
      expect(MwaveExtractor.pulseP2p(e), closeTo(700.0, 1e-9));
    });

    test('창 밖의 값은 p2p에 들어가지 않는다', () {
      // 0ms 의 자극 아티팩트(+5000)와 20ms 의 큰 값은 무시되어야 한다.
      final e = _epoch({0: 5000.0, 8: 400.0, 12: -300.0, 20: -9000.0});
      expect(MwaveExtractor.pulseP2p(e), closeTo(700.0, 1e-9));
    });

    test('창 경계는 시작 포함·끝 제외다', () {
      final withStart = _epoch({kMwaveWindowStartMs: 100.0});
      expect(MwaveExtractor.pulseP2p(withStart), closeTo(100.0, 1e-9));

      final atEnd = _epoch({kMwaveWindowEndMs: 100.0});
      expect(MwaveExtractor.pulseP2p(atEnd), closeTo(0.0, 1e-9));
    });

    test('평평한 에폭의 p2p는 0이다', () {
      expect(MwaveExtractor.pulseP2p(_epoch({})), closeTo(0.0, 1e-9));
    });
  });

  group('MwaveExtractor [F] — 버스트당 1개로 집계', () {
    test('버스트 p2p는 펄스 p2p의 중앙값이다', () {
      final b = _burst([100, 200, 300, 400, 500]);
      expect(MwaveExtractor.burstP2p(b), closeTo(300.0, 1e-6));
    });

    test('짝수 개면 가운데 둘의 평균이다', () {
      final b = _burst([100, 200, 300, 400]);
      expect(MwaveExtractor.burstP2p(b), closeTo(250.0, 1e-6));
    });

    test('중앙값은 펄스 하나짜리 이상치에 흔들리지 않는다', () {
      final clean = _burst([100, 110, 120, 130, 140]);
      final withGlitch = _burst([100, 110, 120, 130, 99999]);
      expect(MwaveExtractor.burstP2p(withGlitch),
          closeTo(MwaveExtractor.burstP2p(clean)!, 1e-6));
    });

    test('펄스가 없으면 null이다', () {
      final b = BurstEpoch(index: 0, onsetMs: 0, pulses: const []);
      expect(MwaveExtractor.burstP2p(b), isNull);
    });

    test('펄스별 p2p 목록을 그대로 얻을 수 있다', () {
      final b = _burst([100, 200, 300]);
      final list = MwaveExtractor.pulseP2ps(b);
      expect(list.length, 3);
      expect(list[0], closeTo(100.0, 1e-6));
      expect(list[2], closeTo(300.0, 1e-6));
    });
  });
}
