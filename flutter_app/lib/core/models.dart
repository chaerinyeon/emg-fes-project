class Sample {
  final double t;
  final double value;
  const Sample(this.t, this.value);
}

/// 오늘의 컨디션 — 세션 시작 전 사용자가 입력.
/// 모든 컨디션에 공통으로 **2σ 관리한계**를 적용(설계: SPC 2σ, 5초 지속).
/// 컨디션 값은 기록·코칭 노트·향후 자극 강도 추천용으로만 사용.
enum TodayCondition {
  good('좋음'),
  normal('보통'),
  tired('피곤함');

  final String label;
  const TodayCondition(this.label);

  /// 모든 컨디션 공통 — 관리한계 2σ.
  double get sigma => 2.0;
}

class AppStatus {
  bool isRunning = false;
  bool isStimulating = false;
  bool fatigueDetected = false;
  double rmsSlope = 0;
  double mdfSlope = 0;
  int historyCount = 0;
  int consecutive = 0; // 0~5
  int consecutiveTrigger = 5; // 펌웨어 기본값
  double rmsThreshold = 20.0;
  double mdfThreshold = -3.0;
  double baselineRms = 0;
  double rmsRatio = 1.0;
  String muscleState = 'idle';

  // 수축 상태머신 (펌웨어로부터)
  int contractState = 0; // 0=rest, 1=onset, 2=sustained
  int contractDurMs = 0; // 현재 수축 지속 시간 ms
  String lastContractType = '-'; // 'b'/'t'/'s'/'-'
  int lastContractDurMs = 0;
  double lastContractPeak = 0;
  int burstCount = 0;
  int sustainedCount = 0;
  int transientCount = 0;

  // 세션 중 관측된 최대 RMS (MVC 추정용)
  double sessionMaxRms = 0;

  // ===== M-wave (자극 응답 EMG) =====
  double mwAmp = 0; // 최신 peak-to-peak (ADC counts)
  double mwArea = 0; // 최신 정류 면적 (Σ|sample|)
  double mwLatency = 0; // 최신 peak까지의 ms
  bool mwValid = false; // 최신 검출의 신뢰도 판정 통과 여부 (펌웨어 mwv)
  int mwCount = 0; // 세션 누적 검출 수

  // 자체 fatigue 엔진 결과 (FatigueEngine이 채움)
  bool engineFatigueDetected = false;
  int engineConsecutive = 0;
  List<String> engineReasons = const [];

  // baseline / 변화율 (FatigueEngine이 채움 — UI 표시용)
  double? mwAmpBaseline;
  double? mwAreaBaseline;
  double? mwLatBaseline;
  double? mwAmpDeclinePct; // baseline 대비 % 감소 (양수=감소)
  double? mwAreaDeclinePct;
  double? mwLatencyDeltaMs; // baseline 대비 ms 증가 (양수=지연)

  // 가장 최근 1Hz RMS / MDF (관리도 표시용)
  double lastRms = 0;
  double lastMdf = 0;

  // 오늘의 컨디션 (세션 시작 셋업에서 설정)
  TodayCondition todayCondition = TodayCondition.normal;

  // 운동 전 플로우 결과 (표시·기록용 — 장치 제어 안 함)
  int? recommendedIntensity; // AI 권장 강도 % (40~90)

  // ===== 관리도(SPC) — 개인화 RMS/MDF 임계치 =====
  // FatigueEngine 이 매 update 시 채움. mean / UCL / LCL 은 8점 모이면 확정.
  double? rmsCcMean;
  double? rmsCcUcl;        // 평균 + 2σ
  double? mdfCcMean;
  double? mdfCcLcl;        // 평균 - 2σ
  int rmsCcSamples = 0;
  int mdfCcSamples = 0;

  // ===== 관리도(SPC) — 개인화 M-wave 임계치 (6점 학습) =====
  double? mwAmpCcMean;
  double? mwAmpCcLcl;       // 평균 - 2σ (진폭 하한)
  double? mwAreaCcMean;
  double? mwAreaCcLcl;
  double? mwLatCcMean;
  double? mwLatCcUcl;       // 평균 + 2σ (잠복기 상한)
}
