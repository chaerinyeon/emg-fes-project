import 'burst_segmenter.dart';
import 'constants.dart';
import 'stats.dart';

/// [E] 5~15ms 창 p2p + [F] 버스트당 중앙값 1개로 집계.
///
/// 창은 **밀리초로 정의**되고 샘플 수는 fs 에 따라 달라진다 — 1kHz 면 10칸,
/// 4kHz 면 40칸이다. 절대값보다 **상대 변화**로 해석해야 한다 — 환자 간 절대
/// 진폭 비교는 의미가 없다(하드 제약 6).
class MwaveExtractor {
  const MwaveExtractor._();

  /// 에폭 하나의 M-wave peak-to-peak.
  ///
  /// 창이 [kMwaveWindowStartMs] 포함 ~ [kMwaveWindowEndMs] 제외인 이유는
  /// 0ms 의 자극 아티팩트를 확실히 배제하기 위해서다.
  ///
  /// 창 경계를 에폭의 [PulseEpoch.clock] 으로 환산한다. 예전처럼 배열 인덱스를
  /// 곧 밀리초로 쓰면 4kHz 에서 창이 자극 후 1.25~3.75ms 로 밀려 — 즉 M-wave 가
  /// 아니라 자극 아티팩트를 재면서 — 아무 에러도 내지 않는다.
  static double pulseP2p(PulseEpoch e) {
    final from = e.clock.samples(kMwaveWindowStartMs);
    final to = e.clock.samples(kMwaveWindowEndMs);
    var lo = double.infinity;
    var hi = double.negativeInfinity;
    for (var d = from; d < to; d++) {
      if (d >= e.samples.length) break;
      final v = e.samples[d];
      if (v < lo) lo = v;
      if (v > hi) hi = v;
    }
    if (lo == double.infinity) return 0.0;
    return hi - lo;
  }

  /// 버스트 안 모든 펄스의 p2p.
  static List<double> pulseP2ps(BurstEpoch b) =>
      b.pulses.map(pulseP2p).toList(growable: false);

  /// [F] 버스트 대표값 = 펄스별 p2p 의 중앙값.
  ///
  /// 평균이 아니라 중앙값을 쓰는 이유는 버스트 안의 펄스 하나가 튀어도
  /// 대표값이 끌려가지 않게 하기 위해서다.
  static double? burstP2p(BurstEpoch b) {
    if (b.pulses.isEmpty) return null;
    return median(pulseP2ps(b));
  }
}
