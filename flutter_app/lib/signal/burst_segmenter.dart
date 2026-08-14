import 'dart:typed_data';
import 'stats.dart';

import 'constants.dart';
import 'stim_detector.dart';

/// 자극 1발분 에폭. 샘플은 이미 영점보정이 끝난 값이다.
class PulseEpoch {
  /// 자극 시점(샘플 인덱스). 에폭의 0 지점이다.
  final int onsetSample;

  /// onset 부터 [kEpochLenMs] 밀리초분의 영점보정된 샘플.
  ///
  /// 길이는 fs 에 따라 다르다 — 1kHz 면 31칸, 4kHz 면 124칸.
  /// **인덱스를 밀리초로 읽지 말 것.** [clock] 으로 환산한다.
  final List<double> samples;

  /// 이 에폭에서 뺀 영점 값 (DC 제거 후 기준).
  final double baseline;

  /// 이 에폭을 자른 샘플레이트. 창을 밀리초로 지정하려면 필요하다.
  final SampleClock clock;

  const PulseEpoch({
    required this.onsetSample,
    required this.samples,
    required this.baseline,
    required this.clock,
  });
}

/// 버스트 1회분. 게임의 "쥠/폄 1회"와 1:1 대응한다.
class BurstEpoch {
  final int index;

  /// 버스트 첫 펄스의 자극 시점(샘플 인덱스).
  final int onsetSample;

  final List<PulseEpoch> pulses;

  final SampleClock clock;

  const BurstEpoch({
    required this.index,
    required this.onsetSample,
    required this.pulses,
    required this.clock,
  });

  /// 세션 시작 기준 초.
  double get tSeconds => clock.seconds(onsetSample);

  /// 세션 시작 기준 밀리초. 게임 큐가 ms 계약이라 여기서 환산해 준다.
  int get onsetMs => clock.toMs(onsetSample).round();
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
  BurstSegmenter({
    this.dcOffset = 0.0,
    this.clock = const SampleClock(kSampleRateHz),
  })  : _ringLen = SampleClock(clock.fs).samples(kSampleRingMs),
        _epochLen = SampleClock(clock.fs).samples(kEpochLenMs),
        _baseStart = SampleClock(clock.fs).samples(kEpochBaselineStartMs),
        _baseEnd = SampleClock(clock.fs).samples(kEpochBaselineEndMs) {
    _ringAdc = Float64List(_ringLen);
    _ringT = Int32List(_ringLen)..fillRange(0, _ringLen, -1);
  }

  /// [A] 에서 구한 DC offset. 에폭 샘플에서 미리 빼 둔다.
  final double dcOffset;

  /// ms 상수 ↔ 샘플 수 환산.
  final SampleClock clock;

  // ms 상수를 fs 로 환산해 둔 것들.
  final int _ringLen;
  final int _epochLen;
  final int _baseStart;
  final int _baseEnd;

  late final Float64List _ringAdc;
  late final Int32List _ringT;

  int? _pendingIndex;
  int? _pendingOnset;
  final List<int> _pendingPulseOnsets = <int>[];

  void addSample(int sampleIdx, int adc) {
    if (sampleIdx < 0) return;
    final i = sampleIdx % _ringLen;
    _ringAdc[i] = adc.toDouble();
    _ringT[i] = sampleIdx;
  }

  /// 확정된 펄스를 넣는다. 새 버스트가 시작되면 **직전** 버스트를 닫아 반환한다.
  BurstEpoch? addEvent(StimEvent e) {
    BurstEpoch? closed;
    if (e.isBurstStart) {
      closed = _close();
      _pendingIndex = e.burstIndex;
      _pendingOnset = e.tSample;
      _pendingPulseOnsets.clear();
    }
    if (_pendingOnset != null) _pendingPulseOnsets.add(e.tSample);
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
      onsetSample: _pendingOnset!,
      pulses: pulses,
      clock: clock,
    );
    _pendingIndex = null;
    _pendingOnset = null;
    _pendingPulseOnsets.clear();
    return out;
  }

  PulseEpoch? _cut(int onsetSample) {
    final raw = List<double>.filled(_epochLen, 0.0);
    for (var d = 0; d < _epochLen; d++) {
      final v = _sampleAt(onsetSample + d);
      if (v == null) return null; // 에폭이 링을 벗어났다 — 버린다
      raw[d] = v - dcOffset;
    }

    final base = <double>[];
    for (var d = _baseStart; d < _baseEnd && d < _epochLen; d++) {
      base.add(raw[d]);
    }
    final baseline = median(base);

    final zeroed = List<double>.generate(_epochLen, (d) => raw[d] - baseline,
        growable: false);

    return PulseEpoch(
      onsetSample: onsetSample,
      samples: zeroed,
      baseline: baseline,
      clock: clock,
    );
  }

  double? _sampleAt(int sampleIdx) {
    if (sampleIdx < 0) return null;
    final i = sampleIdx % _ringLen;
    return _ringT[i] == sampleIdx ? _ringAdc[i] : null;
  }

}
