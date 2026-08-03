import 'dart:math' as math;

/// 미래 σ 예측 — 선제 경고.
///
/// ## 두 층의 역할 분담
///
/// - **SPC σ** = 1차 라벨. 인과적·실시간·자기기준이고 학습 데이터가 없어도
///   동작한다. 지금 이미 지쳤는지를 말한다.
/// - **예측 σ** = 앞으로 지칠지를 미리 말한다. SPC 가 사후 확인이라면 이쪽은
///   예고다. 위험(3σ)에 닿기 전에 개입할 시간을 벌어주는 것이 목적이다.
///
/// 게이지에는 둘을 **겹쳐** 표시한다(실선 바늘 = 현재, 점선 바늘 = 예측).
///
/// ## 지금 구현
///
/// LSTM 모델은 아직 없다. 그 자리를 비워두되 화면이 돌아가야 하므로, 최근
/// 구간의 추세를 최소제곱 직선으로 잡아 [horizonSec] 뒤를 외삽한다.
/// 실측 세션에서 σ 상승이 완만한 단조 구간이라 직선 외삽도 방향은 맞게 나온다.
///
/// TODO(LSTM): `tflite_flutter` 로 학습 모델을 로드해 [push] 안을 교체한다.
///   입력은 최근 σ 시퀀스(+ 원한다면 M-wave 진폭·간격), 출력은 horizon 뒤 σ.
///   교체해도 이 클래스의 바깥 계약([push] → 예측 σ)은 그대로 유지한다.
class SigmaPredictor {
  SigmaPredictor({
    this.horizonSec = 30.0,
    this.windowSec = 60.0,
    this.maxSigma = 6.0,
  });

  /// 몇 초 뒤를 내다보는가.
  final double horizonSec;

  /// 추세를 잡는 데 쓰는 최근 구간(초).
  final double windowSec;

  /// 예측값 상한 — 외삽이 폭주해 게이지가 튀지 않게 자른다.
  final double maxSigma;

  final List<double> _t = [];
  final List<double> _z = [];

  /// 마지막 예측값.
  double? get lastPrediction => _last;
  double? _last;

  /// 새 (시각, σ) 를 넣고 [horizonSec] 뒤의 예측 σ 를 돌려준다.
  double push(double tSec, double sigma) {
    _t.add(tSec);
    _z.add(sigma);
    // 창 밖은 버린다.
    while (_t.length > 2 && tSec - _t.first > windowSec) {
      _t.removeAt(0);
      _z.removeAt(0);
    }

    // 표본이 적으면 추세를 말할 수 없다 — 현재값을 그대로 예측으로 쓴다.
    if (_t.length < 5) return _last = sigma;

    // 최소제곱 직선.
    final n = _t.length;
    final meanT = _t.reduce((a, b) => a + b) / n;
    final meanZ = _z.reduce((a, b) => a + b) / n;
    var num = 0.0, den = 0.0;
    for (var i = 0; i < n; i++) {
      final dt = _t[i] - meanT;
      num += dt * (_z[i] - meanZ);
      den += dt * dt;
    }
    final slope = den == 0 ? 0.0 : num / den;

    // 회복(하강) 중이라면 미래를 낙관하지 않는다. 예측은 경고용이므로
    // 아래로 내리는 쪽은 보수적으로 — 현재값 밑으로는 내려가지 않게 둔다.
    final raw = sigma + slope * horizonSec;
    return _last = math.max(sigma, math.min(raw, maxSigma));
  }

  void reset() {
    _t.clear();
    _z.clear();
    _last = null;
  }
}
