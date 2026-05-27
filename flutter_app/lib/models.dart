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
}
