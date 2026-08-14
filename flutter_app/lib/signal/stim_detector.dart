import 'dart:math' as math;

import 'constants.dart';
import 'stats.dart';

/// 검출된 자극 펄스 1발.
class StimEvent {
  /// 자극 시점(그룹의 argmax), **샘플 인덱스**. M-wave 창의 onset = 0 이다.
  ///
  /// 밀리초가 아니다 — fs 가 1000 이 아니면 두 값은 다르다.
  final int tSample;
  final double peakAbs; // 정점의 |신호 − DC|
  final bool isBurstStart;
  final int burstIndex; // 0부터

  const StimEvent({
    required this.tSample,
    required this.peakAbs,
    required this.isBurstStart,
    required this.burstIndex,
  });

  @override
  String toString() =>
      'StimEvent(i=$tSample, peak=${peakAbs.toStringAsFixed(1)}, '
      'burst=$burstIndex${isBurstStart ? ' START' : ''})';
}

/// 위상 드리프트 진단 기록.
///
/// 위상이 밀려도 게임은 정상으로 보인다. 로그가 없으면 훈련 효과만
/// 조용히 사라지고 아무도 감지하지 못한다.
class PhaseDriftLog {
  final int burstIndex;
  final int actualOnsetMs;
  final int predictedOnsetMs;
  final double driftMs;
  final bool exceeded;

  const PhaseDriftLog({
    required this.burstIndex,
    required this.actualOnsetMs,
    required this.predictedOnsetMs,
    required this.driftMs,
    required this.exceeded,
  });

  @override
  String toString() => 'burst=$burstIndex actual=$actualOnsetMs '
      'predicted=$predictedOnsetMs drift=${driftMs.toStringAsFixed(1)}ms'
      '${exceeded ? ' EXCEEDED' : ''}';
}

/// [B] 자극 검출 · 주기 추정 · 위상 고정 · 드리프트 보정.
///
/// 펌웨어가 자극 트리거를 보내주지 못하므로 raw 에서 직접 찾는다.
///
/// 임계는 **적응형**이다. 고정 임계 1000 을 쓰면 아티팩트 진폭대
/// 900~1300 의 하단에 걸려 버스트를 통째로 놓친다.
///
/// 불응기는 in-burst ISI(실측 31ms)보다 반드시 작아야 한다. 과거 펌웨어의
/// `MW_REFRACTORY_MS = 40` 은 주기보다 커서 자극의 절반만 검출했다.
class StimDetector {
  StimDetector({
    required this.dcOffset,
    required this.noiseSigma,
    this.artifactScale,
    this.clock = const SampleClock(kSampleRateHz),
  })  : assert(artifactScale == null || artifactScale > 0),
        threshold = thresholdFor(
            artifactScale: artifactScale, noiseSigma: noiseSigma),
        _refractory = SampleClock(clock.fs).samples(kPulseRefractoryMs),
        _burstGap = SampleClock(clock.fs).samples(kBurstGapMs),
        _periodMin = SampleClock(clock.fs).samples(kPeriodSearchMinMs),
        _periodMax = SampleClock(clock.fs).samples(kPeriodSearchMaxMs),
        _driftTolerance =
            SampleClock(clock.fs).samples(kPhaseDriftToleranceMs);

  final double dcOffset;
  final double noiseSigma;

  /// ms 상수 ↔ 샘플 수 환산. 이 검출기의 모든 내부 시각은 샘플 인덱스다.
  final SampleClock clock;

  // ms 상수를 fs 로 환산해 둔 것들. 매 샘플 나눗셈을 피한다.
  final int _refractory;
  final int _burstGap;
  final int _periodMin;
  final int _periodMax;
  final int _driftTolerance;

  /// 세션 도입부에서 관측된 아티팩트 진폭 규모 (|신호−DC| 의 고백분위수).
  ///
  /// 잡음 배수만으로 임계를 정하면, 캘리브 창이 유난히 조용한 세션에서
  /// 임계가 아티팩트보다 한참 아래로 내려가 한 자극이 여러 번 검출된다.
  final double? artifactScale;

  /// 적응형 자극 후보 임계 (|신호 − DC| 기준).
  final double threshold;

  /// 임계 계산식. 재추정([SignalPipeline.retuneStimDetection])이 같은 식을
  /// 써야 하므로 생성자에서 꺼내 둔다 — 두 곳에 적어 두면 한쪽만 바뀐다.
  static double thresholdFor({
    required double? artifactScale,
    required double noiseSigma,
  }) =>
      artifactScale != null
          ? math.max(artifactScale * kArtifactScaleFrac, kStimThresholdFloorAdc)
          : math.max(
              noiseSigma * kStimThresholdNoiseMult, kStimThresholdFloorAdc);

  // --- 그룹 상태 (모두 샘플 인덱스) ---
  bool _inGroup = false;
  int _groupStartT = 0;
  int _groupPeakT = 0;
  double _groupPeakAbs = 0.0;

  // --- 펄스·버스트 ---
  int? _lastPulseT;
  int _burstIndex = -1;
  int _pulseCount = 0;
  final List<int> _burstOnsets = <int>[];

  // --- 위상 ---
  double? _periodSamples;
  int? _phaseOrigin;
  int _phaseOriginBurstIndex = 0;
  double? _lastDriftMs;
  int _driftExceededCount = 0;
  final List<PhaseDriftLog> _driftLog = <PhaseDriftLog>[];

  /// 추정된 자극 주기(ms). 확정 전에는 null.
  ///
  /// 내부는 샘플로 세지만 밖으로는 ms 로 말한다 — 저장 스키마
  /// (`stim_period_ms`)와 게임 큐가 ms 계약 위에 있다.
  double? get periodMs =>
      _periodSamples == null ? null : clock.toMs(_periodSamples!);

  /// 위상이 고정된 첫 버스트의 자극 시점(샘플 인덱스).
  int? get firstBurstOnsetSample =>
      _burstOnsets.isEmpty ? null : _burstOnsets.first;

  /// 마지막으로 관측된 버스트 자극 시점(샘플 인덱스).
  int? get lastBurstOnsetSample =>
      _burstOnsets.isEmpty ? null : _burstOnsets.last;

  /// 다음 자극이 일어날 것으로 예측되는 시점(ms). 게임 큐는 여기서
  /// [kCueLeadMs] 만큼 앞서 나가야 한다.
  int? get predictedNextBurstOnsetMs {
    if (_periodSamples == null || _burstOnsets.isEmpty) return null;
    return clock.toMs(_predictOnsetFor(_burstIndex + 1)).round();
  }

  double? get lastDriftMs => _lastDriftMs;
  int get driftExceededCount => _driftExceededCount;
  List<PhaseDriftLog> get driftLog => List.unmodifiable(_driftLog);

  int get pulseCount => _pulseCount;
  int get burstCount => _burstOnsets.length;
  List<int> get burstOnsets => List.unmodifiable(_burstOnsets);

  /// 버스트당 검출 이벤트 수. 신뢰도 게이팅의 1차 지표.
  double get eventsPerBurst =>
      _burstOnsets.isEmpty ? 0.0 : _pulseCount / _burstOnsets.length;

  /// 샘플 1개를 넣는다. 이번 샘플로 **확정된** 펄스가 있으면 반환한다.
  ///
  /// 그룹은 **그룹 시작으로부터** [kPulseRefractoryMs] 가 지나야 닫힌다.
  /// "마지막 임계 초과 샘플" 기준으로 재면 M-wave(5~15ms)가 다음 펄스(31ms)
  /// 까지 사슬처럼 이어져 두 펄스가 하나로 병합된다.
  StimEvent? add(int sampleIdx, int adc) {
    final dev = (adc - dcOffset).abs();

    if (dev > threshold) {
      StimEvent? closed;
      if (_inGroup && (sampleIdx - _groupStartT) > _refractory) {
        closed = _closeGroup();
      }
      if (!_inGroup) {
        _inGroup = true;
        _groupStartT = sampleIdx;
        _groupPeakT = sampleIdx;
        _groupPeakAbs = dev;
      } else if (dev > _groupPeakAbs) {
        _groupPeakAbs = dev;
        _groupPeakT = sampleIdx;
      }
      return closed;
    }

    if (_inGroup && (sampleIdx - _groupStartT) > _refractory) {
      return _closeGroup();
    }
    return null;
  }

  /// 스트림 끝에서 열려 있는 그룹을 마무리한다.
  StimEvent? flush() => _inGroup ? _closeGroup() : null;

  StimEvent? _closeGroup() {
    if (!_inGroup) return null;
    _inGroup = false;

    final t = _groupPeakT;
    final isBurstStart =
        _lastPulseT == null || (t - _lastPulseT!) > _burstGap;
    _lastPulseT = t;
    _pulseCount++;

    if (isBurstStart) {
      _burstIndex++;
      _burstOnsets.add(t);
      _updatePeriod();
      _updatePhase(t);
    }

    return StimEvent(
      tSample: t,
      peakAbs: _groupPeakAbs,
      isBurstStart: isBurstStart,
      burstIndex: _burstIndex,
    );
  }

  /// 버스트 간격의 중앙값으로 주기를 추정한다.
  ///
  /// 공통 컨텍스트는 자기상관을 명시하지만, 확정된 onset 열에서는 중앙값이
  /// 같은 값을 더 싸게 주고 누락에도 강하다([estimatePeriodByAutocorrelation]
  /// 은 검증용으로 남겨 둔다).
  void _updatePeriod() {
    if (_burstOnsets.length < 4) return;
    final valid = <double>[];
    for (var i = 1; i < _burstOnsets.length; i++) {
      final d = (_burstOnsets[i] - _burstOnsets[i - 1]).toDouble();
      if (d >= _periodMin && d <= _periodMax) valid.add(d);
    }
    if (valid.length < 3) return;
    _periodSamples = median(valid);
  }

  int _predictOnsetFor(int burstIndex) {
    final origin = _phaseOrigin ?? _burstOnsets.first;
    final steps = burstIndex - _phaseOriginBurstIndex;
    return (origin + steps * _periodSamples!).round();
  }

  void _updatePhase(int actualOnset) {
    if (_periodSamples == null) return;

    if (_phaseOrigin == null) {
      _phaseOrigin = actualOnset;
      _phaseOriginBurstIndex = _burstIndex;
      return;
    }

    final predicted = _predictOnsetFor(_burstIndex);
    final driftSamples = (actualOnset - predicted).toDouble();
    final exceeded = driftSamples.abs() > _driftTolerance;

    // 진단 로그는 사람이 읽는 것이라 ms 로 남긴다.
    final drift = clock.toMs(driftSamples);
    _lastDriftMs = drift;
    if (exceeded) _driftExceededCount++;
    _driftLog.add(PhaseDriftLog(
      burstIndex: _burstIndex,
      actualOnsetMs: clock.toMs(actualOnset).round(),
      predictedOnsetMs: clock.toMs(predicted).round(),
      driftMs: drift,
      exceeded: exceeded,
    ));

    // 주기적 재정렬 + 허용치 초과 시 즉시 재동기.
    final due = (_burstIndex - _phaseOriginBurstIndex) >=
        kPhaseResyncEveryBursts;
    if (exceeded || due) {
      _phaseOrigin = actualOnset;
      _phaseOriginBurstIndex = _burstIndex;
    }
  }

  /// 자기상관 기반 주기 추정 (오프라인·검증용).
  ///
  /// onset 이진열에 대해 [kPeriodSearchMinMs]~[kPeriodSearchMaxMs] 구간의
  /// lag 을 훑어 일치 수가 최대인 lag 을 고른다. numpy 없이 정수 연산만 쓴다.
  static double? estimatePeriodByAutocorrelation(List<int> onsetsMs,
      {int toleranceMs = 3}) {
    if (onsetsMs.length < 4) return null;
    final set = onsetsMs.toSet();
    var bestLag = -1;
    var bestScore = 0;
    for (var lag = kPeriodSearchMinMs; lag <= kPeriodSearchMaxMs; lag++) {
      var score = 0;
      for (final o in onsetsMs) {
        for (var d = -toleranceMs; d <= toleranceMs; d++) {
          if (set.contains(o + lag + d)) {
            score++;
            break;
          }
        }
      }
      if (score > bestScore) {
        bestScore = score;
        bestLag = lag;
      }
    }
    if (bestLag < 0 || bestScore < 3) return null;
    return bestLag.toDouble();
  }
}
