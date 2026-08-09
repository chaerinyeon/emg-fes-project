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
///          OR (M-wave 진폭 < LCL  AND  면적 < LCL)
/// — 각 그룹 내부는 AND, 두 그룹 사이는 OR.
/// 완전마비 환자는 RMS/MDF 그룹을 비활성화하고 M-wave만 사용한다.
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
    double sigmaMultiplier = 2.0,
  }) : rmsChart = ControlChart(sigmaMultiplier: sigmaMultiplier),
       mdfChart = ControlChart(sigmaMultiplier: sigmaMultiplier),
       // M-wave 는 burst 당 1점이라 sample 도착이 느림 → baseline 6점
       mwAmpChart = ControlChart(
         baselineSamples: 6,
         sigmaMultiplier: sigmaMultiplier,
       ),
       mwAreaChart = ControlChart(
         baselineSamples: 6,
         sigmaMultiplier: sigmaMultiplier,
       ),
       mwLatChart = ControlChart(
         baselineSamples: 6,
         sigmaMultiplier: sigmaMultiplier,
       );

  void resetSession() {
    mwSeen = 0;
    lastAmpDeclinePct = null;
    lastAreaDeclinePct = null;
    lastLatencyDeltaMs = null;
    _lastMwAmp = null;
    _lastMwArea = null;
    rmsChart.reset();
    mdfChart.reset();
    mwAmpChart.reset();
    mwAreaChart.reset();
    mwLatChart.reset();
    consecutive = 0;
    _latched = false;
  }

  void _ingestMw(double amp, double area, double? lat) {
    mwSeen++;
    _lastMwAmp = amp;
    _lastMwArea = area;
    // 관리도 학습 — 6점 모이면 mean·stddev 확정
    mwAmpChart.ingest(amp);
    mwAreaChart.ingest(area);
    if (lat != null) mwLatChart.ingest(lat);
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
    if (lBase != null && lat != null) {
      lastLatencyDeltaMs = lat - lBase;
    }
  }

  /// M-wave 관리도 위반 판정: 진폭 < LCL AND 면적 < LCL.
  /// 1kHz latency는 1ms 양자화와 artifact 경계에 민감해 판정에서 제외한다.
  bool _mwFatigue(List<String> reasons) {
    if (!mwAmpChart.isEstablished || !mwAreaChart.isEstablished) {
      return false;
    }
    final amp = _lastMwAmp;
    final area = _lastMwArea;
    final ampBelow = amp != null && mwAmpChart.belowLower(amp);
    final areaBelow = area != null && mwAreaChart.belowLower(area);
    final triggered = ampBelow && areaBelow;
    if (triggered) {
      reasons.add('M-wave 진폭 < LCL');
      reasons.add('M-wave 면적 < LCL');
    }
    return triggered;
  }

  /// 매 BLE 메시지마다 호출. raw 메트릭을 받아 카테고리별로 판정.
  /// rmsSlope/mdfSlope는 historyCount >= 30 일 때만 의미 있음.
  /// mw* 값이 null이면 M-wave 부분은 건너뜀.
  /// rms/mdf 값은 이제 10Hz 로 도착(매 메시지 non-null 가능)하지만, 관리도(SPC)
  /// 학습/판정·연속카운터는 [isFullTick](1Hz full 메시지)에서만 수행한다.
  /// 자극(FES) 중에만 관리도 표본을 수집하고, 자극 중 위반 시 fatigue 후보.
  FatigueResult update({
    required double rmsSlope,
    required double mdfSlope,
    required int historyCount,
    double? rms,
    double? mdf,
    bool isStimulating = false,
    bool isFullTick = false,
    double sessionElapsedSeconds = 0,
    double? mwAmp,
    double? mwArea,
    double? mwLatency,
    bool mwValid = true,
  }) {
    // 신뢰도(mwValid) 통과한 검출만 SPC baseline·판정에 반영.
    // 무효 검출(노이즈·창끝값)로 즉시 FES 차단이 오작동하는 것을 막는다.
    final baselineWindowOpen = sessionElapsedSeconds >= 30.0;
    if (baselineWindowOpen && mwValid && mwAmp != null && mwArea != null) {
      _ingestMw(mwAmp, mwArea, mwLatency);
    }

    // ---- 관리도 — 자극 중 RMS/MDF 값(절대값) 표본 학습 ----
    // (slope SPC 는 baseline 이 거의 0 이라 band 가 너무 좁게 학습됨 → 사용 안 함)
    // rms/mdf 가 10Hz 로 와도 학습은 1Hz(full tick)에서만 → 8표본=8초 가정 유지.
    if (category != SubjectCategory.complete &&
        baselineWindowOpen &&
        isStimulating &&
        isFullTick) {
      if (rms != null) rmsChart.ingest(rms);
      if (mdf != null) mdfChart.ingest(mdf);
    }

    // 판정·연속카운터는 1Hz full 메시지에서만 갱신한다.
    // 중간 10Hz(rms/mdf/M-wave/env) 메시지가 consecutive 를 리셋하면 5연속이
    // 누적되지 않아 RMS/MDF 경로 검출이 영영 발화하지 못한다.
    if (!isFullTick) {
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
    final rmsHigh =
        category != SubjectCategory.complete &&
        rmsChart.isEstablished &&
        isStimulating &&
        rms != null &&
        rmsChart.exceedsUpper(rms);
    final mdfLow =
        category != SubjectCategory.complete &&
        mdfChart.isEstablished &&
        isStimulating &&
        mdf != null &&
        mdfChart.belowLower(mdf);

    // ---- 통일 판정 규칙 (모든 환자 분류 동일) ----
    //   (RMS>UCL AND MDF<LCL) OR (진폭<LCL AND 면적<LCL)
    //   두 그룹 각각은 내부 AND, 두 그룹 사이는 OR.
    final rmsMdfGroup = rmsHigh && mdfLow;
    final mwGroup = _mwFatigue(reasons); // 성립 시 reasons 에 M-wave 항목 추가
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
