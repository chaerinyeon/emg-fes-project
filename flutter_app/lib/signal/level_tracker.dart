import 'dart:collection';

import 'constants.dart';

/// [H] 적응형 레벨 구간 추적 + A_ref running-peak.
///
/// 세션 중 접촉·자세 변화로 진폭 레벨이 계단식으로 바뀐다(실측 세션당 평균
/// 4.1회). 이 계단을 피로로 세면 안 된다.
///
/// 시프트 판정은 **인접한 두 창의 중앙값 비교**로 한다.
/// 구간 시작값을 고정 기준선으로 쓰면, 300버스트에 걸친 완만한 −40% 피로가
/// 기준선에서 40% 벗어난 순간 "레벨 시프트"로 오인되고 A_ref 가 리셋되어
/// 피로를 영영 못 잡는다. 인접 창 비교는 **급격함**을 보므로 계단만 잡는다.
///
/// A_ref 는 현재 구간의 running-peak 다. 상승 중(전위증강)에는 A_ref 가 현재값을
/// 따라가므로 피로가 자동으로 0이 되고, 피크 이후 하락분만 피로로 계산된다.
class LevelTracker {
  LevelTracker({
    this.window = kLevelShiftWindow,
    this.sustain = kLevelShiftSustain,
    this.ratio = kLevelShiftRatio,
  });

  /// 비교 창 크기(버스트).
  final int window;

  /// 시프트로 인정하기 위해 이탈이 지속되어야 하는 버스트 수.
  final int sustain;

  /// 인접 창 중앙값이 이 비율 이상 벌어지면 시프트 후보.
  final double ratio;

  /// 최근 2*window 개를 보관 (최근 창 + 직전 창).
  final Queue<double> _recent = Queue<double>();

  int _segmentIndex = 0;
  double _aRef = 0.0;
  int _consecutiveExceed = 0;
  bool _justShifted = false;
  int _burstsInSegment = 0;

  /// 현재 레벨 구간 번호 (0부터).
  int get segmentIndex => _segmentIndex;

  /// 총 구간 수.
  int get segmentCount => _segmentIndex + 1;

  /// 현재 구간의 A_ref (running peak). 피로 0%의 기준 진폭.
  double get aRef => _aRef;

  /// 직전 [add] 에서 새 구간이 시작됐는가.
  bool get justShifted => _justShifted;

  /// 현재 구간에 쌓인 버스트 수.
  int get burstsInSegment => _burstsInSegment;

  void add(double p2p) {
    _justShifted = false;

    _recent.addLast(p2p);
    while (_recent.length > 2 * window) {
      _recent.removeFirst();
    }

    _burstsInSegment++;
    if (p2p > _aRef) _aRef = p2p;

    _detectShift(p2p);
  }

  void _detectShift(double p2p) {
    // 인접 두 창이 모두 차야 판정한다.
    if (_recent.length < 2 * window) return;
    // 시프트 직후에는 창이 아직 옛 레벨과 섞여 있으므로 잠시 쉰다.
    if (_burstsInSegment <= window) return;

    final xs = _recent.toList(growable: false);
    final prev = _median(xs.sublist(0, window));
    final curr = _median(xs.sublist(window));
    if (prev.abs() < 1e-12) return;

    final rel = (curr - prev).abs() / prev.abs();
    if (rel > ratio) {
      _consecutiveExceed++;
      if (_consecutiveExceed >= sustain) _startNewSegment();
    } else {
      _consecutiveExceed = 0;
    }
  }

  void _startNewSegment() {
    _segmentIndex++;
    _consecutiveExceed = 0;
    _justShifted = true;
    _burstsInSegment = 0;

    // 새 구간의 A_ref 는 시프트 이후 표본(최근 창)에서만 잡는다.
    // 이전 레벨의 피크를 물고 가면 접촉 변화가 통째로 피로로 잡힌다.
    final xs = _recent.toList(growable: false);
    final fresh = xs.sublist(xs.length - window);
    _aRef = fresh.reduce((a, b) => a > b ? a : b);
  }

  static double _median(List<double> xs) {
    final s = List<double>.of(xs)..sort();
    final n = s.length;
    if (n == 0) return 0.0;
    return n.isOdd ? s[n ~/ 2] : (s[n ~/ 2 - 1] + s[n ~/ 2]) / 2.0;
  }
}
