import 'dart:collection';

import '../signal/constants.dart';

/// 세션 종료 사유 (공통 컨텍스트 5장, DB `sessions.end_reason`).
///
/// **중단 사유를 뭉뚱그리면 안 된다.** 치료사가 "진짜 피로로 멈춘 것"과
/// "장비 문제로 멈춘 것"을 구분하지 못하면 그 위의 모든 해석이 오염된다.
enum SessionEndReason {
  fatigueThreshold('fatigue_threshold'),
  successRateDrop('success_rate_drop'),
  gameComplete('game_complete'),
  timeout('timeout'),
  userStop('user_stop'),
  remoteStop('remote_stop'),
  signalLost('signal_lost'),
  deviceDisconnect('device_disconnect'),
  error('error');

  const SessionEndReason(this.code);

  /// 앱·웹·DB 가 공유하는 문자열.
  final String code;
}

/// 종료 조건 평가기.
///
/// 자동 조건은 우선순위대로 본다.
///   1. 적응형 피로 임계 (연속 [kFatigueConsecutiveBursts] 버스트)
///   2. 수축 성공률 하락 (백업)
///   3. 세션 시간 상한 (백업)
///
/// **2·3번 백업은 반드시 살아 있어야 한다** — 적응형 기준은 보수적이라
/// 실측 58세션 중 47세션에서만 걸렸다. [kFatigueThresholdPct] 가 아직
/// null 이라 지금은 사실상 백업만으로 돈다.
///
/// 외부 사건(중단 버튼·기기 끊김)은 자동 조건을 **이긴다** — 그것이 실제로
/// 멈춘 이유다.
class EndConditionEvaluator {
  EndConditionEvaluator({
    this.fatigueThresholdPct = kFatigueThresholdPct,
    this.consecutiveBursts = kFatigueConsecutiveBursts,
    this.successWindow = kSuccessRateWindow,
    this.successDropRatio = kSuccessRateDropRatio,
    this.maxSessionSeconds = kSessionMaxMin * 60,
  });

  /// null 이면 피로 기반 종료를 걸지 않는다 (P0 확정 전).
  final double? fatigueThresholdPct;
  final int consecutiveBursts;
  final int successWindow;

  /// 초기 성공률 대비 **하락폭**. 0.40 이면 초기의 60% 이하로 떨어질 때 발동.
  ///
  /// 공통 컨텍스트 5장 표는 "초기 대비 40% 이하", 4장 상수 설명은
  /// "초기 대비 성공률 **하락폭**" 이라 읽는 방향이 갈린다.
  /// 더 일찍 멈추는(=환자에게 안전한) 하락폭 해석을 택했다.
  // TODO(P0): 두 해석 중 어느 쪽인지 확정 필요.
  final double successDropRatio;

  final int maxSessionSeconds;

  SessionEndReason? _external;
  SessionEndReason? _auto;

  int _fatigueRun = 0;
  final Queue<bool> _recent = Queue<bool>();
  final List<bool> _initial = <bool>[];

  /// 걸린 종료 사유. 없으면 null. 한 번 걸리면 유지된다(래치).
  SessionEndReason? get triggered => _external ?? _auto;

  bool get isTriggered => triggered != null;

  /// 초기 성공률 (기준선). 표본이 모자라면 null.
  double? get initialSuccessRate => _initial.length < successWindow
      ? null
      : _initial.where((v) => v).length / _initial.length;

  /// 최근 [successWindow] 버스트 성공률. 표본이 모자라면 null.
  double? get recentSuccessRate => _recent.length < successWindow
      ? null
      : _recent.where((v) => v).length / _recent.length;

  /// 외부 사건. 자동 조건을 이기고, 먼저 온 것이 남는다.
  void signal(SessionEndReason reason) {
    _external ??= reason;
  }

  void addBurst({
    required double fatiguePct,
    required bool contractionOk,
    required bool reliable,
    required double tSeconds,
  }) {
    if (isTriggered) return; // 래치
    _seen++;

    // --- 성공률 표본 ---
    if (_initial.length < successWindow) _initial.add(contractionOk);
    _recent.addLast(contractionOk);
    while (_recent.length > successWindow) {
      _recent.removeFirst();
    }

    // --- 1순위: 적응형 피로 ---
    // 신뢰도가 깨진 버스트는 피로 판정에 쓰지 않는다(공통 컨텍스트 2.4).
    final thr = fatigueThresholdPct;
    if (thr != null && reliable) {
      if (fatiguePct >= thr) {
        _fatigueRun++;
        if (_fatigueRun >= consecutiveBursts) {
          _auto = SessionEndReason.fatigueThreshold;
          return;
        }
      } else {
        _fatigueRun = 0;
      }
    }

    // --- 2순위: 성공률 하락 (백업) ---
    final init = initialSuccessRate;
    final recent = recentSuccessRate;
    if (init != null && recent != null && init > 0) {
      // 초기 표본이 최근 창에 그대로 남아 있으면 비교가 무의미하다.
      final haveFreshWindow = _seen >= successWindow * 2;
      if (haveFreshWindow && recent <= init * (1 - successDropRatio)) {
        _auto = SessionEndReason.successRateDrop;
        return;
      }
    }

    // --- 3순위: 시간 상한 (백업) ---
    if (tSeconds >= maxSessionSeconds) {
      _auto = SessionEndReason.timeout;
      return;
    }
  }

  int _seen = 0;

  void reset() {
    _external = null;
    _auto = null;
    _fatigueRun = 0;
    _recent.clear();
    _initial.clear();
    _seen = 0;
  }
}
