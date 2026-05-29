import '../core/subject_category.dart';

/// fatigue 판정 1회 결과.
class FatigueResult {
  final bool detected; // latched 상태 (5x consecutive 도달 후 true 유지)
  final bool justTriggered; // 이번 update에서 처음 detected=true가 됐는지
  final List<String> reasons; // 어떤 조건이 만족됐는지 (UI 표시용)
  final int consecutive;
  final int consecutiveTrigger;
  const FatigueResult({
    required this.detected,
    required this.justTriggered,
    required this.reasons,
    required this.consecutive,
    required this.consecutiveTrigger,
  });
}

/// 환자 분류별 fatigue 판정 엔진.
/// - A (건강): RMS slope + MDF slope 이중 조건
/// - B (불완전마비): RMS / MDF / M-wave 중 2개 이상 만족
/// - C (완전마비): M-wave 변화 단독
///
/// 5x 연속 카운터로 노이즈 방지. 펌웨어의 fd 필드와 독립적으로 동작.
class FatigueEngine {
  SubjectCategory category;
  double rmsThreshold;
  double mdfThreshold;
  int consecutiveTrigger;

  // M-wave 임계값
  static const int mwBaselineSamples = 10;
  static const double mwAmpDeclinePctTrigger = 30.0; // baseline 대비 30% 감소
  static const double mwAreaDeclinePctTrigger = 30.0;
  static const double mwLatencyDelayMsTrigger = 2.0; // baseline 대비 2ms 지연

  // baseline 수집용 시드
  final List<double> _mwAmpSeed = [];
  final List<double> _mwAreaSeed = [];
  final List<double> _mwLatSeed = [];

  double? mwAmpBase;
  double? mwAreaBase;
  double? mwLatBase;
  int mwSeen = 0;
  double? lastAmpDeclinePct;
  double? lastAreaDeclinePct;
  double? lastLatencyDeltaMs;

  int consecutive = 0;
  bool _latched = false;

  FatigueEngine({
    required this.category,
    this.rmsThreshold = 20.0,
    this.mdfThreshold = -3.0,
    this.consecutiveTrigger = 5,
  });

  void resetSession() {
    _mwAmpSeed.clear();
    _mwAreaSeed.clear();
    _mwLatSeed.clear();
    mwAmpBase = null;
    mwAreaBase = null;
    mwLatBase = null;
    mwSeen = 0;
    lastAmpDeclinePct = null;
    lastAreaDeclinePct = null;
    lastLatencyDeltaMs = null;
    consecutive = 0;
    _latched = false;
  }

  void _ingestMw(double amp, double area, double lat) {
    mwSeen++;
    if (mwAmpBase == null) {
      _mwAmpSeed.add(amp);
      _mwAreaSeed.add(area);
      _mwLatSeed.add(lat);
      if (_mwAmpSeed.length >= mwBaselineSamples) {
        mwAmpBase = _mean(_mwAmpSeed);
        mwAreaBase = _mean(_mwAreaSeed);
        mwLatBase = _mean(_mwLatSeed);
      }
    }
    if (mwAmpBase != null && mwAmpBase! > 0) {
      lastAmpDeclinePct = 100.0 * (mwAmpBase! - amp) / mwAmpBase!;
    }
    if (mwAreaBase != null && mwAreaBase! > 0) {
      lastAreaDeclinePct = 100.0 * (mwAreaBase! - area) / mwAreaBase!;
    }
    if (mwLatBase != null) {
      lastLatencyDeltaMs = lat - mwLatBase!;
    }
  }

  double _mean(List<double> xs) =>
      xs.isEmpty ? 0 : xs.reduce((a, b) => a + b) / xs.length;

  bool _mwFatigue(List<String> reasons) {
    if (mwAmpBase == null) return false;
    final ampDrop = (lastAmpDeclinePct ?? 0) >= mwAmpDeclinePctTrigger;
    final areaDrop = (lastAreaDeclinePct ?? 0) >= mwAreaDeclinePctTrigger;
    final latDelay = (lastLatencyDeltaMs ?? 0) >= mwLatencyDelayMsTrigger;
    // 진폭+면적 동반 감소 OR 잠복기 의미있게 증가
    final triggered = (ampDrop && areaDrop) || latDelay;
    if (triggered) {
      if (ampDrop && areaDrop) reasons.add('M-wave 진폭·면적 감소');
      if (latDelay) reasons.add('M-wave 잠복기 지연');
    }
    return triggered;
  }

  /// 매 BLE 메시지마다 호출. raw 메트릭을 받아 카테고리별로 판정.
  /// rmsSlope/mdfSlope는 historyCount >= 30 일 때만 의미 있음.
  /// mw* 값이 null이면 M-wave 부분은 건너뜀.
  FatigueResult update({
    required double rmsSlope,
    required double mdfSlope,
    required int historyCount,
    double? mwAmp,
    double? mwArea,
    double? mwLatency,
  }) {
    if (mwAmp != null && mwArea != null && mwLatency != null) {
      _ingestMw(mwAmp, mwArea, mwLatency);
    }

    final reasons = <String>[];
    final slopeReady = historyCount >= 30;
    final rmsCond = slopeReady && rmsSlope > rmsThreshold;
    final mdfCond = slopeReady && mdfSlope < mdfThreshold;

    bool fatigueCond;
    switch (category) {
      case SubjectCategory.healthy:
        // A: RMS slope ↑ AND MDF slope ↓
        fatigueCond = rmsCond && mdfCond;
        if (rmsCond) reasons.add('RMS slope ↑');
        if (mdfCond) reasons.add('MDF slope ↓');
        break;
      case SubjectCategory.incomplete:
        // B: RMS / MDF / M-wave 중 2개 이상 만족
        int positives = 0;
        if (rmsCond) {
          positives++;
          reasons.add('RMS slope ↑');
        }
        if (mdfCond) {
          positives++;
          reasons.add('MDF slope ↓');
        }
        if (_mwFatigue(reasons)) positives++;
        fatigueCond = positives >= 2;
        break;
      case SubjectCategory.complete:
        // C: M-wave 변화 단독
        fatigueCond = _mwFatigue(reasons);
        break;
    }

    bool justTriggered = false;
    if (fatigueCond) {
      consecutive++;
      if (consecutive >= consecutiveTrigger && !_latched) {
        _latched = true;
        justTriggered = true;
      }
    } else {
      consecutive = 0;
      _latched = false;
    }

    return FatigueResult(
      detected: _latched,
      justTriggered: justTriggered,
      reasons: List.unmodifiable(reasons),
      consecutive: consecutive,
      consecutiveTrigger: consecutiveTrigger,
    );
  }
}
