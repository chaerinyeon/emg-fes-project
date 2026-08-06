import 'dart:collection';
import 'stats.dart';

import 'constants.dart';

/// [G] Hampel 이상치 필터.
///
/// 전극 순간 접촉 불량으로 생기는 글리치를 제거한다. 실측에서 이 필터
/// 하나로 최대 피로도가 52%(글리치)에서 27.4%(실제)로 정정됐다.
/// **생략하면 피로도가 과대평가된다.**
///
/// 지속되는 레벨 시프트(세션당 평균 4.1회)는 뭉개지 않는다. 그건 [H] 가
/// 구간으로 잡아야 할 신호이지 글리치가 아니다.
class HampelFilter {
  const HampelFilter._();

  /// 중심창 Hampel — 오프라인 Python 파이프라인과 1:1 대조용.
  ///
  /// 미래 표본을 쓰므로 **인과적이지 않다**. 실시간에는 [OnlineHampel] 을 쓴다.
  /// 가장자리는 창을 잘라서 처리한다(Python 구현과 동일).
  static List<double> applyCentered(
    List<double> x, {
    int k = kHampelK,
    double sigma = kHampelSigma,
  }) {
    final n = x.length;
    final out = List<double>.of(x);
    if (n == 0) return out;
    final h = k ~/ 2;

    for (var i = 0; i < n; i++) {
      final lo = i - h < 0 ? 0 : i - h;
      final hi = i + h + 1 > n ? n : i + h + 1;
      final win = x.sublist(lo, hi);
      final med = median(win);
      final dev = win.map((v) => (v - med).abs()).toList(growable: false);
      final mad = median(dev) + 1e-9;
      if ((x[i] - med).abs() > sigma * kMadToSigma * mad) out[i] = med;
    }
    return out;
  }

}

/// 인과 Hampel — 실시간 경로용.
///
/// 지금 값을 **직전 k개(자기 자신 포함)** 만으로 판정한다. 미래를 기다리지
/// 않으므로 지연이 0이다. 중심창보다 약간 둔하지만, 게임 피드백이 3버스트
/// (약 4.9초) 늦는 것보다 낫다.
class OnlineHampel {
  OnlineHampel({this.k = kHampelK, this.sigma = kHampelSigma});

  final int k;
  final double sigma;

  final Queue<double> _win = Queue<double>();

  /// 워밍업(창이 절반도 안 찼을 때)에는 판정하지 않고 통과시킨다.
  int get _minForJudgement => (k ~/ 2) + 1;

  double add(double v) {
    _win.addLast(v);
    while (_win.length > k) {
      _win.removeFirst();
    }
    if (_win.length < _minForJudgement) return v;

    final win = _win.toList(growable: false);
    final med = median(win);
    final dev = win.map((w) => (w - med).abs()).toList(growable: false);
    final mad = median(dev) + 1e-9;

    if ((v - med).abs() > sigma * kMadToSigma * mad) {
      // 글리치로 판정 — 대표값은 중앙값으로 바꾸되, 창에는 원값을 남겨
      // 새 레벨이 실제로 지속되면 자연히 받아들여지게 한다.
      return med;
    }
    return v;
  }

  void reset() => _win.clear();
}
