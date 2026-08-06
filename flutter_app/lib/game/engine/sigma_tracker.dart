import 'dart:math' as math;
import '../../signal/stats.dart';

import '../model/zone.dart';

/// 근피로 SPC σ 추적 — `~/emgfes-data/fes_fatigue_spc.py` 의 실시간 이식.
///
/// 이 프로젝트의 SPC 결과 전부가 그 스크립트의 정의 위에 서 있으므로, 여기서는
/// 방법을 새로 만들지 않고 **그대로 옮긴다**. 파이썬과 같은 입력에 같은 출력을
/// 내는지는 `test/game/sigma_tracker_test.dart` 가 실측 세션 기준벡터로 검증한다.
///
/// 방법 요약:
///   특징      버스트당 1점, M-wave peak-to-peak (자극 후 5~15ms 창)
///   이상치    Hampel (창 7, 3σ) — 전극 글리치 제거
///   baseline  t ∈ [20, 90]초, mu0 = 중앙값, sd0 = 1.4826 × MAD (견고 통계)
///   평활      EWMA λ=0.15 (인과적)
///   σ         zsig = (mu0 − EWMA) / sd0   ← 진폭이 떨어지면 z가 오른다
///   존 도달   5연속 지속, 그리고 t ≥ 90초 이후만
///
/// ## 실시간에서 달라지는 점 — 3버스트 지연
///
/// Hampel 창은 자기 앞뒤 3점을 본다(`x[i-3 : i+4]`). 즉 **미래 3표본이 필요**하다.
/// 그래서 이 트래커는 버스트 i의 σ를 버스트 i+3이 도착해야 확정한다 — 버스트가
/// ≈1.6초 간격이므로 게이지가 약 5초 뒤처진다. 피로 게이지에서 5초 지연은
/// 무해하고, 그 대가로 오프라인 분석과 **정확히 같은 값**을 얻는다.
/// (근사 인과 Hampel로 지연을 없앨 수도 있지만 그러면 값이 갈라진다.)
///
/// 세션이 끝나 뒤 3점을 더 못 받을 때는 [flush] 로 꼬리를 확정한다. 파이썬의
/// 창 잘림(`hi = min(n, i+h+1)`)과 같은 처리다.
class SigmaTracker {
  // ── 오프라인 스크립트와 동일한 상수 ──────────────────────────────
  /// baseline 창 시작(초). 이 앞은 전극 안정화 구간이라 버린다.
  static const double baseT0 = 20.0;

  /// baseline 창 끝(초). 감시는 이 시점 이후에만 한다.
  static const double baseT1 = 90.0;

  /// EWMA 계수.
  static const double lambda = 0.15;

  /// 존 도달로 인정하는 연속 표본 수.
  static const int sustainedRun = 5;

  /// Hampel 창 크기(홀수).
  static const int hampelWindow = 7;

  /// Hampel 이상치 임계(σ 배수).
  static const double hampelNSigma = 3.0;

  /// MAD → 표준편차 환산 상수 (정규분포 가정).
  static const double madScale = 1.4826;

  /// baseline 창에 최소 이만큼은 있어야 정상 경로를 쓴다.
  static const int minBaselineSamples = 10;

  /// baseline 창이 부족할 때 대신 쓸 앞쪽 표본 수.
  static const int fallbackBaselineSamples = 20;

  /// baseline이 쓸 만하다고 보는 최소 변동계수(sd0/mu0).
  ///
  /// ★ 오프라인 스크립트에 없는, 실시간에만 필요한 안전장치다.
  /// 오프라인은 `sd0 = 1.4826·MAD + 1e-9` 로 두고 base_cv 를 기록만 한다 —
  /// 사람이 보고 판단하면 되기 때문이다. 그러나 실시간 게이지에서 신호가 죽거나
  /// 포화돼 baseline 이 완전히 평평하면 MAD=0 → sd0≈1e-9 → z 가 수십억으로 튀어
  /// **즉시 "위험"** 을 띄운다. 죽은 신호가 3σ 경보를 울리는 것은 아무 정보도
  /// 없다고 말하는 것보다 나쁘다. 그래서 이 경우 baseline 을 확정하지 않고
  /// "측정 중"으로 남긴다(게임 자체는 σ 없이도 진행된다).
  ///
  /// 1e-6 은 "신호가 문자 그대로 상수인가"만 걸러내는 값이다. 실측 세션의
  /// base_cv 는 0.065~0.226 이라 한참 위다. 임상적 품질 기준(예: cv가 얼마를
  /// 넘으면 baseline 불량으로 볼지)은 별개 문제로 남아 있다.
  static const double minBaseCv = 1e-6;

  static int get _halfWindow => hampelWindow ~/ 2;

  // ── 입력 버퍼 ────────────────────────────────────────────────────
  final List<double> _rawAmp = [];
  final List<double> _rawT = [];

  /// Hampel 확정된 진폭. 파이썬이 배열을 제자리 수정하며 훑는 것과 같게,
  /// 인덱스 i를 확정할 때 i보다 앞은 **이미 보정된 값**을 창에 넣는다.
  final List<double> _amp = [];
  final List<double> _t = [];

  // ── 파생 상태 ────────────────────────────────────────────────────
  final List<double> _zsig = [];
  double? _mu0;
  double? _sd0;
  double? _t1;
  double? _t2;
  double? _t3;

  /// 확정된 버스트 수(= σ가 계산된 표본 수).
  int get length => _amp.length;

  /// baseline이 잡혔는가. 잡히기 전에는 σ가 없다 — 게이지는 "측정 중".
  bool get isBaselineEstablished => _mu0 != null && _sd0 != null;

  /// baseline 중앙값(진폭).
  double? get mu0 => _mu0;

  /// baseline 견고 표준편차.
  double? get sd0 => _sd0;

  /// baseline 품질 게이트. 크면 초기 구간이 이미 불안정했다는 뜻이다.
  double? get baseCv =>
      (_mu0 != null && _sd0 != null && _mu0! != 0) ? _sd0! / _mu0! : null;

  /// 현재 σ. baseline 전이면 null.
  double? get currentSigma => _zsig.isEmpty ? null : _zsig.last;

  /// 현재 존. baseline 전이면 null(정상으로 단정하지 않는다).
  FatigueZone? get currentZone {
    final z = currentSigma;
    return z == null ? null : zoneOf(z);
  }

  /// 1σ/2σ/3σ에 (지속) 도달한 시각(초). 아직이면 null.
  double? get t1 => _t1;
  double? get t2 => _t2;
  double? get t3 => _t3;

  /// 2σ→3σ 리드타임(초) — 선제 대응 여유.
  double? get leadTime2to3 =>
      (_t2 != null && _t3 != null) ? _t3! - _t2! : null;

  /// Hampel 확정된 진폭 계열. 오프라인 `hampel(amp)` 와 같아야 한다.
  List<double> get filteredAmplitudes => List.unmodifiable(_amp);

  /// 확정된 (시각, σ) 이력 — 게이지 타임라인용.
  List<({double t, double z})> get history => [
        for (var i = 0; i < _zsig.length; i++) (t: _t[i], z: _zsig[i]),
      ];

  /// 버스트 1개 도착. [tSec]은 세션 시작 기준 초, [amp]는 M-wave peak-to-peak.
  ///
  /// 버스트 경계 판정(펄스 묶기)은 호출자가 한다 — 이 클래스는 버스트당 1점을
  /// 받는다는 전제로 동작한다.
  void addBurst(double tSec, double amp) {
    _rawT.add(tSec);
    _rawAmp.add(amp);
    // 인덱스 i는 i+3 이 도착해야 Hampel 창이 다 찬다.
    while (_amp.length + _halfWindow + 1 <= _rawAmp.length) {
      _finalizeOne(truncated: false);
    }
    _recompute();
  }

  /// 세션 종료 — 남은 꼬리(마지막 3점)를 잘린 창으로 확정한다.
  void flush() {
    while (_amp.length < _rawAmp.length) {
      _finalizeOne(truncated: true);
    }
    _recompute();
  }

  /// 다음 인덱스 하나를 Hampel 적용해 확정.
  void _finalizeOne({required bool truncated}) {
    final i = _amp.length;
    final lo = math.max(0, i - _halfWindow);
    final hi = math.min(_rawAmp.length, i + _halfWindow + 1);
    if (!truncated && hi < i + _halfWindow + 1) return;

    // 창 구성: i 앞은 보정된 값, i 이후는 원값 — 파이썬의 제자리 수정과 동일.
    final win = <double>[
      for (var j = lo; j < hi; j++) j < i ? _amp[j] : _rawAmp[j],
    ];
    final m = median(win);
    final mad = median([for (final v in win) (v - m).abs()]) + 1e-9;

    final x = _rawAmp[i];
    _amp.add((x - m).abs() > hampelNSigma * madScale * mad ? m : x);
    _t.add(_rawT[i]);
  }

  /// baseline·EWMA·σ·존도달을 확정분 전체에서 다시 계산한다.
  ///
  /// 매번 전체를 훑지만 버스트는 ≈1.6초에 1개뿐이라 비용이 무의미하고, 대신
  /// 파이썬 코드와 한 줄씩 대조할 수 있게 남는다.
  void _recompute() {
    _zsig.clear();
    _t1 = _t2 = _t3 = null;
    if (_amp.isEmpty) return;

    _establishBaseline();
    final mu0 = _mu0, sd0 = _sd0;
    if (mu0 == null || sd0 == null) return;

    // EWMA — 인과적. z[0] = amp[0].
    var ewma = _amp[0];
    for (var i = 0; i < _amp.length; i++) {
      if (i > 0) ewma = lambda * _amp[i] + (1 - lambda) * ewma;
      _zsig.add((mu0 - ewma) / sd0);
    }

    _t1 = _firstSustained(1.0);
    _t2 = _firstSustained(2.0);
    _t3 = _firstSustained(3.0);
  }

  /// baseline 창 [20, 90]초의 중앙값·MAD. 표본이 모자라면 앞쪽 구간으로 대체.
  void _establishBaseline() {
    // 아직 90초를 지나지 않았으면 baseline을 확정하지 않는다 — 감시 시작 전이다.
    if (_t.last < baseT1) {
      _mu0 = _sd0 = null;
      return;
    }
    var win = <double>[
      for (var i = 0; i < _amp.length; i++)
        if (_t[i] >= baseT0 && _t[i] <= baseT1) _amp[i],
    ];
    if (win.length < minBaselineSamples) {
      // 파이썬의 대체 경로: 앞쪽 max(20, n/8) 표본.
      final n = math.max(fallbackBaselineSamples, _amp.length ~/ 8);
      win = _amp.take(n).toList();
    }
    if (win.isEmpty) {
      _mu0 = _sd0 = null;
      return;
    }
    final m = median(win);
    final sd = madScale * median([for (final v in win) (v - m).abs()]) + 1e-9;

    // 신호가 사실상 상수면 baseline 을 못 쓴다 — 위 minBaseCv 주석 참고.
    if (m == 0 || sd / m.abs() < minBaseCv) {
      _mu0 = _sd0 = null;
      return;
    }
    _mu0 = m;
    _sd0 = sd;
  }

  /// σ가 [threshold] 이상인 상태가 [sustainedRun] 연속 유지된 첫 시각.
  /// baseline 창이 끝나기 전(t < 90초)은 세지 않는다.
  double? _firstSustained(double threshold) {
    var run = 0;
    for (var i = 0; i < _zsig.length; i++) {
      if (_t[i] < baseT1) continue;
      run = _zsig[i] >= threshold ? run + 1 : 0;
      if (run >= sustainedRun) return _t[i - sustainedRun + 1];
    }
    return null;
  }


  /// 새 세션 시작.
  void reset() {
    _rawAmp.clear();
    _rawT.clear();
    _amp.clear();
    _t.clear();
    _zsig.clear();
    _mu0 = _sd0 = null;
    _t1 = _t2 = _t3 = null;
  }
}
