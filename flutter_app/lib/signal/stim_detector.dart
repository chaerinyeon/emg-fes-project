import 'dart:math' as math;

import 'constants.dart';
import 'stats.dart';

/// 검출된 자극 펄스 1발.
class StimEvent {
  /// 자극 시점(그룹의 argmax). 이 값이 M-wave 창의 onset = 0ms 다.
  final int tMs;
  final double peakAbs; // 정점의 |신호 − DC|
  final bool isBurstStart;
  final int burstIndex; // 0부터

  const StimEvent({
    required this.tMs,
    required this.peakAbs,
    required this.isBurstStart,
    required this.burstIndex,
  });

  @override
  String toString() =>
      'StimEvent(t=$tMs, peak=${peakAbs.toStringAsFixed(1)}, '
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
  })  : assert(artifactScale == null || artifactScale > 0),
        threshold = artifactScale != null
            ? math.max(
                artifactScale * kArtifactScaleFrac, kStimThresholdFloorAdc)
            : math.max(
                noiseSigma * kStimThresholdNoiseMult, kStimThresholdFloorAdc);

  final double dcOffset;
  final double noiseSigma;

  /// 세션 도입부에서 관측된 아티팩트 진폭 규모 (|신호−DC| 의 고백분위수).
  ///
  /// 잡음 배수만으로 임계를 정하면, 캘리브 창이 유난히 조용한 세션에서
  /// 임계가 아티팩트보다 한참 아래로 내려가 한 자극이 여러 번 검출된다.
  final double? artifactScale;

  /// 적응형 자극 후보 임계 (|신호 − DC| 기준).
  final double threshold;

  // --- 그룹 상태 ---
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
  double? _periodMs;
  int? _phaseOriginMs;
  int _phaseOriginBurstIndex = 0;
  double? _lastDriftMs;
  int _driftExceededCount = 0;
  final List<PhaseDriftLog> _driftLog = <PhaseDriftLog>[];

  /// 추정된 자극 주기. 확정 전에는 null.
  double? get periodMs => _periodMs;

  /// 위상이 고정된 첫 버스트의 자극 시점.
  int? get firstBurstOnsetMs =>
      _burstOnsets.isEmpty ? null : _burstOnsets.first;

  /// 마지막으로 관측된 버스트 자극 시점.
  int? get lastBurstOnsetMs => _burstOnsets.isEmpty ? null : _burstOnsets.last;

  /// 다음 자극이 일어날 것으로 예측되는 시점. 게임 큐는 여기서 [kCueLeadMs]
  /// 만큼 앞서 나가야 한다.
  int? get predictedNextBurstOnsetMs {
    if (_periodMs == null || _burstOnsets.isEmpty) return null;
    return _predictOnsetFor(_burstIndex + 1);
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
  StimEvent? add(int tMs, int adc) {
    final dev = (adc - dcOffset).abs();

    if (dev > threshold) {
      StimEvent? closed;
      if (_inGroup && (tMs - _groupStartT) > kPulseRefractoryMs) {
        closed = _closeGroup();
      }
      if (!_inGroup) {
        _inGroup = true;
        _groupStartT = tMs;
        _groupPeakT = tMs;
        _groupPeakAbs = dev;
      } else if (dev > _groupPeakAbs) {
        _groupPeakAbs = dev;
        _groupPeakT = tMs;
      }
      return closed;
    }

    if (_inGroup && (tMs - _groupStartT) > kPulseRefractoryMs) {
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
        _lastPulseT == null || (t - _lastPulseT!) > kBurstGapMs;
    _lastPulseT = t;
    _pulseCount++;

    if (isBurstStart) {
      _burstIndex++;
      _burstOnsets.add(t);
      _updatePeriod();
      _updatePhase(t);
    }

    return StimEvent(
      tMs: t,
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
      if (d >= kPeriodSearchMinMs && d <= kPeriodSearchMaxMs) valid.add(d);
    }
    if (valid.length < 3) return;
    _periodMs = median(valid);
  }

  int _predictOnsetFor(int burstIndex) {
    final origin = _phaseOriginMs ?? _burstOnsets.first;
    final steps = burstIndex - _phaseOriginBurstIndex;
    return (origin + steps * _periodMs!).round();
  }

  void _updatePhase(int actualOnsetMs) {
    if (_periodMs == null) return;

    if (_phaseOriginMs == null) {
      _phaseOriginMs = actualOnsetMs;
      _phaseOriginBurstIndex = _burstIndex;
      return;
    }

    final predicted = _predictOnsetFor(_burstIndex);
    final drift = (actualOnsetMs - predicted).toDouble();
    final exceeded = drift.abs() > kPhaseDriftToleranceMs;

    _lastDriftMs = drift;
    if (exceeded) _driftExceededCount++;
    _driftLog.add(PhaseDriftLog(
      burstIndex: _burstIndex,
      actualOnsetMs: actualOnsetMs,
      predictedOnsetMs: predicted,
      driftMs: drift,
      exceeded: exceeded,
    ));

    // 주기적 재정렬 + 허용치 초과 시 즉시 재동기.
    final due = (_burstIndex - _phaseOriginBurstIndex) >=
        kPhaseResyncEveryBursts;
    if (exceeded || due) {
      _phaseOriginMs = actualOnsetMs;
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
