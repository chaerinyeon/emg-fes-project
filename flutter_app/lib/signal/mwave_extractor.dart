import 'burst_segmenter.dart';
import 'constants.dart';
import 'stats.dart';

/// [E] 5~15ms 창 p2p + [F] 버스트당 중앙값 1개로 집계.
///
/// 1kHz 이므로 창은 정확히 10 샘플이다. 절대값보다 **상대 변화**로 해석해야
/// 한다 — 환자 간 절대 진폭 비교는 의미가 없다(하드 제약 6).
class MwaveExtractor {
  const MwaveExtractor._();

  /// 에폭 하나의 M-wave peak-to-peak.
  ///
  /// 창이 [kMwaveWindowStartMs] 포함 ~ [kMwaveWindowEndMs] 제외인 이유는
  /// 0ms 의 자극 아티팩트를 확실히 배제하기 위해서다.
  static double pulseP2p(PulseEpoch e) {
    var lo = double.infinity;
    var hi = double.negativeInfinity;
    for (var d = kMwaveWindowStartMs; d < kMwaveWindowEndMs; d++) {
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
