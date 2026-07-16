import 'dart:math';

/// 개인화 임계치를 위한 단일 변수 관리도(SPC chart).
///
/// 운동 초반(아직 안 지친 상태)의 처음 [baselineSamples] 측정값을 모아
/// 평균(중심선)과 표준편차를 잡고, 평균 ± [sigmaMultiplier] × σ 를 정상 범위로 둔다.
///
/// 사용 예 — RMS 는 위쪽 경계(UCL), MDF 는 아래쪽 경계(LCL)만 의미가 있음.
class ControlChart {
  ControlChart({
    this.baselineSamples = 8,
    this.sigmaMultiplier = 2.0,
  });

  final int baselineSamples;
  final double sigmaMultiplier;

  final List<double> _samples = [];
  double? mean;
  double? stddev;

  bool get isEstablished => mean != null && stddev != null;
  int get sampleCount => _samples.length;

  double? get upperLimit =>
      isEstablished ? mean! + sigmaMultiplier * stddev! : null;
  double? get lowerLimit =>
      isEstablished ? mean! - sigmaMultiplier * stddev! : null;

  /// 새 측정점 추가. baseline 수집이 끝나면 mean/stddev 확정.
  void ingest(double value) {
    if (isEstablished) return;
    _samples.add(value);
    if (_samples.length >= baselineSamples) {
      final m = _samples.reduce((a, b) => a + b) / _samples.length;
      final variance = _samples
              .map((x) => (x - m) * (x - m))
              .reduce((a, b) => a + b) /
          _samples.length;
      mean = m;
      stddev = sqrt(variance);
    }
  }

  bool exceedsUpper(double value) =>
      upperLimit != null && value > upperLimit!;
  bool belowLower(double value) =>
      lowerLimit != null && value < lowerLimit!;

  void reset() {
    _samples.clear();
    mean = null;
    stddev = null;
  }
}
