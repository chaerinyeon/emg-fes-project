import 'dart:typed_data';
import 'stats.dart';

import 'constants.dart';
import 'stim_detector.dart';

/// 자극 1발분 에폭. 샘플은 이미 영점보정이 끝난 값이다.
class PulseEpoch {
  /// 자극 시점 (에폭의 0ms).
  final int onsetMs;

  /// onset..onset+[kEpochLenMs)-1 의 영점보정된 샘플.
  final List<double> samples;

  /// 이 에폭에서 뺀 영점 값 (DC 제거 후 기준).
  final double baseline;

  const PulseEpoch({
    required this.onsetMs,
    required this.samples,
    required this.baseline,
  });
}

/// 버스트 1회분. 게임의 "쥠/폄 1회"와 1:1 대응한다.
class BurstEpoch {
  final int index;

  /// 버스트 첫 펄스의 자극 시점.
  final int onsetMs;

  final List<PulseEpoch> pulses;

  const BurstEpoch({
    required this.index,
    required this.onsetMs,
    required this.pulses,
  });

  double get tSeconds => onsetMs / 1000.0;
}

/// [C] 버스트 분할 + [D] 에폭별 영점보정.
///
/// **자극 직전 구간을 영점 기준으로 쓰지 않는다** (하드 제약 1).
/// 실측에서 자극 직전 5샘플이 M-wave 피크의 중앙 20.2% 크기로 오염되어
/// 있었고, 88세션 중 74세션이 10%를 넘었다. 영점은 M-wave 창이 끝난 뒤
/// (다음 펄스 아티팩트가 오기 전) [kEpochBaselineStartMs]~
/// [kEpochBaselineEndMs] 구간의 **중앙값**으로 잡는다. 중앙값을 쓰는 이유는
/// 이 구간 끝자락이 다음 펄스의 전조에 살짝 물릴 수 있기 때문이다.
class BurstSegmenter {
  BurstSegmenter({this.dcOffset = 0.0});

  /// [A] 에서 구한 DC offset. 에폭 샘플에서 미리 빼 둔다.
  final double dcOffset;

  final Float64List _ringAdc = Float64List(kSampleRingMs);
  final Int32List _ringT = Int32List(kSampleRingMs)
    ..fillRange(0, kSampleRingMs, -1);

  int? _pendingIndex;
  int? _pendingOnset;
  final List<int> _pendingPulseOnsets = <int>[];

  void addSample(int tMs, int adc) {
    if (tMs < 0) return;
    final i = tMs % kSampleRingMs;
    _ringAdc[i] = adc.toDouble();
    _ringT[i] = tMs;
  }

  /// 확정된 펄스를 넣는다. 새 버스트가 시작되면 **직전** 버스트를 닫아 반환한다.
  BurstEpoch? addEvent(StimEvent e) {
    BurstEpoch? closed;
    if (e.isBurstStart) {
      closed = _close();
      _pendingIndex = e.burstIndex;
      _pendingOnset = e.tMs;
      _pendingPulseOnsets.clear();
    }
    if (_pendingOnset != null) _pendingPulseOnsets.add(e.tMs);
    return closed;
  }

  /// 스트림 끝에서 마지막 버스트를 닫는다.
  BurstEpoch? flush() => _close();

  BurstEpoch? _close() {
    if (_pendingOnset == null) return null;

    final pulses = <PulseEpoch>[];
    for (final onset in _pendingPulseOnsets) {
      final epoch = _cut(onset);
      if (epoch != null) pulses.add(epoch);
    }

    final out = BurstEpoch(
      index: _pendingIndex!,
      onsetMs: _pendingOnset!,
      pulses: pulses,
    );
    _pendingIndex = null;
    _pendingOnset = null;
    _pendingPulseOnsets.clear();
    return out;
  }

  PulseEpoch? _cut(int onsetMs) {
    final raw = List<double>.filled(kEpochLenMs, 0.0);
    for (var d = 0; d < kEpochLenMs; d++) {
      final v = _sampleAt(onsetMs + d);
      if (v == null) return null; // 에폭이 링을 벗어났다 — 버린다
      raw[d] = v - dcOffset;
    }

    final base = <double>[];
    for (var d = kEpochBaselineStartMs; d < kEpochBaselineEndMs; d++) {
      base.add(raw[d]);
    }
    final baseline = median(base);

    final zeroed = List<double>.generate(kEpochLenMs, (d) => raw[d] - baseline,
        growable: false);

    return PulseEpoch(
        onsetMs: onsetMs, samples: zeroed, baseline: baseline);
  }

  double? _sampleAt(int tMs) {
    if (tMs < 0) return null;
    final i = tMs % kSampleRingMs;
    return _ringT[i] == tMs ? _ringAdc[i] : null;
  }

}
