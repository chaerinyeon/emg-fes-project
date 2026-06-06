import '../core/subject_category.dart';
import 'control_chart.dart';

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

/// fatigue 판정 엔진.
///
/// RMS / MDF / M-wave 임계치는 운동 초반 표본으로 학습한 관리도(SPC)의 UCL / LCL.
/// (기존 +20% / -3% 같은 하드코딩 슬로프 임계는 사용하지 않음)
///
/// 통일 판정 규칙 (모든 환자 분류 동일):
///   피로 = (RMS > UCL  AND  MDF < LCL)
///          OR
///          (M-wave 진폭 < LCL  AND  면적 < LCL  AND  잠복기 > UCL)
/// — 각 그룹 내부는 AND, 두 그룹 사이는 OR.
///
/// 5x 연속 카운터로 노이즈 방지. 펌웨어의 fd 필드와 독립적으로 동작.
class FatigueEngine {
  SubjectCategory category;
  double rmsThreshold;
  double mdfThreshold;
  int consecutiveTrigger;

  // 개인화 임계치(관리도) — 운동 초반 표본으로 mean ± k·σ 학습.
  // RMS·MDF: 1Hz 갱신 → 8점이면 8초
  // M-wave: 3초 burst 당 1점 → 6점이면 ~18초
  final ControlChart rmsChart;
  final ControlChart mdfChart;
  final ControlChart mwAmpChart;
  final ControlChart mwAreaChart;
  final ControlChart mwLatChart;

  // 가장 최근 M-wave 측정값 (CC 비교용으로 보관)
  double? _lastMwAmp;
  double? _lastMwArea;
  double? _lastMwLat;

  int mwSeen = 0;
  // UI 표시 호환용 — baseline mean 대비 percent decline / latency delta
  double? lastAmpDeclinePct;
  double? lastAreaDeclinePct;
  double? lastLatencyDeltaMs;

  // 호환 alias (MwavePanel 등에서 사용)
  double? get mwAmpBase => mwAmpChart.mean;
  double? get mwAreaBase => mwAreaChart.mean;
  double? get mwLatBase => mwLatChart.mean;

  int consecutive = 0;
  bool _latched = false;

  FatigueEngine({
    required this.category,
    this.rmsThreshold = 20.0,
    this.mdfThreshold = -3.0,
    this.consecutiveTrigger = 5,
    double sigmaMultiplier = 3.0,
  })  : rmsChart = ControlChart(sigmaMultiplier: sigmaMultiplier),
        mdfChart = ControlChart(sigmaMultiplier: sigmaMultiplier),
        // M-wave 는 burst 당 1점이라 sample 도착이 느림 → baseline 6점
        mwAmpChart = ControlChart(
            baselineSamples: 6, sigmaMultiplier: sigmaMultiplier),
        mwAreaChart = ControlChart(
            baselineSamples: 6, sigmaMultiplier: sigmaMultiplier),
        mwLatChart = ControlChart(
            baselineSamples: 6, sigmaMultiplier: sigmaMultiplier);

  void resetSession() {
    mwSeen = 0;
    lastAmpDeclinePct = null;
    lastAreaDeclinePct = null;
    lastLatencyDeltaMs = null;
    _lastMwAmp = null;
    _lastMwArea = null;
    _lastMwLat = null;
    rmsChart.reset();
    mdfChart.reset();
    mwAmpChart.reset();
    mwAreaChart.reset();
    mwLatChart.reset();
    consecutive = 0;
    _latched = false;
  }

  void _ingestMw(double amp, double area, double lat) {
    mwSeen++;
    _lastMwAmp = amp;
    _lastMwArea = area;
    _lastMwLat = lat;
    // 관리도 학습 — 6점 모이면 mean·stddev 확정
    mwAmpChart.ingest(amp);
    mwAreaChart.ingest(area);
    mwLatChart.ingest(lat);
    // UI 호환용 baseline mean 대비 percent
    final aBase = mwAmpChart.mean;
    if (aBase != null && aBase > 0) {
      lastAmpDeclinePct = 100.0 * (aBase - amp) / aBase;
    }
    final areaBase = mwAreaChart.mean;
    if (areaBase != null && areaBase > 0) {
      lastAreaDeclinePct = 100.0 * (areaBase - area) / areaBase;
    }
    final lBase = mwLatChart.mean;
    if (lBase != null) {
      lastLatencyDeltaMs = lat - lBase;
    }
  }

  /// M-wave 관리도 위반 판정 (그룹 내부 AND):
  ///   진폭 < LCL  AND  면적 < LCL  AND  잠복기 > UCL  (셋 다 위반해야 성립)
  bool _mwFatigue(List<String> reasons) {
    if (!mwAmpChart.isEstablished ||
        !mwAreaChart.isEstablished ||
        !mwLatChart.isEstablished) {
      return false;
    }
    final amp = _lastMwAmp;
    final area = _lastMwArea;
    final lat = _lastMwLat;
    final ampBelow = amp != null && mwAmpChart.belowLower(amp);
    final areaBelow = area != null && mwAreaChart.belowLower(area);
    final latAbove = lat != null && mwLatChart.exceedsUpper(lat);
    final triggered = ampBelow && areaBelow && latAbove;
    if (triggered) {
      reasons.add('M-wave 진폭 < LCL');
      reasons.add('M-wave 면적 < LCL');
      reasons.add('M-wave 잠복기 > UCL');
    }
    return triggered;
  }

  /// 매 BLE 메시지마다 호출. raw 메트릭을 받아 카테고리별로 판정.
  /// rmsSlope/mdfSlope는 historyCount >= 30 일 때만 의미 있음.
  /// mw* 값이 null이면 M-wave 부분은 건너뜀.
  /// rms/mdf 값은 1Hz 갱신 시점에만 non-null — 관리도(SPC) 학습/체크에 사용.
  /// 자극(FES) 중에만 관리도 표본을 수집하고, 자극 중 위반 시 fatigue 후보.
  FatigueResult update({
    required double rmsSlope,
    required double mdfSlope,
    required int historyCount,
    double? rms,
    double? mdf,
    bool isStimulating = false,
    double? mwAmp,
    double? mwArea,
    double? mwLatency,
  }) {
    if (mwAmp != null && mwArea != null && mwLatency != null) {
      _ingestMw(mwAmp, mwArea, mwLatency);
    }

    // ---- 관리도 — 자극 중 RMS/MDF 값(절대값) 표본 학습 ----
    // (slope SPC 는 baseline 이 거의 0 이라 band 가 너무 좁게 학습됨 → 사용 안 함)
    if (isStimulating) {
      if (rms != null) rmsChart.ingest(rms);
      if (mdf != null) mdfChart.ingest(mdf);
    }

    // 판정·연속카운터는 1Hz full 샘플(rms/mdf 동반)에서만 갱신한다.
    // 중간 10Hz(M-wave/env) 메시지가 consecutive 를 리셋하면 5연속이 누적되지
    // 않아 RMS/MDF 경로 검출이 영영 발화하지 못한다.
    final isDecisionTick = rms != null || mdf != null;
    if (!isDecisionTick) {
      return FatigueResult(
        detected: _latched,
        justTriggered: false,
        reasons: const [],
        consecutive: consecutive,
        consecutiveTrigger: consecutiveTrigger,
      );
    }

    final reasons = <String>[];

    // 관리도 기반 RMS/MDF 이상 판정 (개인화 임계치)
    // — 자극 중에만, 현재 값을 학습된 UCL/LCL 과 비교.
    final rmsHigh = rmsChart.isEstablished &&
        isStimulating && rms != null && rmsChart.exceedsUpper(rms);
    final mdfLow = mdfChart.isEstablished &&
        isStimulating && mdf != null && mdfChart.belowLower(mdf);

    // ---- 통일 판정 규칙 (모든 환자 분류 동일) ----
    //   (RMS>UCL AND MDF<LCL)  OR  (진폭<LCL AND 면적<LCL AND 잠복기>UCL)
    //   두 그룹 각각은 내부 AND, 두 그룹 사이는 OR.
    final rmsMdfGroup = rmsHigh && mdfLow;
    final mwGroup = _mwFatigue(reasons);     // 성립 시 reasons 에 M-wave 항목 추가
    if (rmsMdfGroup) {
      reasons.add('RMS > UCL');
      reasons.add('MDF < LCL');
    }
    final fatigueCond = rmsMdfGroup || mwGroup;

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
