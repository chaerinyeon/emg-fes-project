class Sample {
  final double t;
  final double value;
  const Sample(this.t, this.value);
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
}
