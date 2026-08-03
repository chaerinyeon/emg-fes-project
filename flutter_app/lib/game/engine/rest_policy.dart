/// 강판/휴식 이벤트 규칙. 순수 Dart.
///
/// σ가 게임에 개입하는 **유일한** 통로다(나머지는 색·조명 같은 연출뿐).
/// 점수 페널티는 없다 — 이 이벤트는 벌이 아니라 안전장치다.
///
/// ## 히스테리시스가 필요한 이유
///
/// 3σ에 닿을 때마다 곧바로 다시 무장하면, z가 3σ에 머무는 동안 휴식 오버레이가
/// 무한히 반복된다. 그래서 한 번 발동하면 z가 2σ 아래로 내려갔다 와야 다시
/// 걸린다. 그리고 쉬어도 회복이 안 됐다면(z ≥ 3σ) 재개시키지 않고 세션을
/// 끝내는 쪽으로 보낸다 — 무리한 재개를 막는 것이 목적이기 때문이다.
enum RestDecision {
  /// 다음 이닝 재개 + 트리거 재무장.
  resume,

  /// 재개하되 무장은 보류(z가 2σ 아래로 내려갈 때까지).
  resumeDisarmed,

  /// 회복되지 않음 — 재개하지 않고 세션 종료를 권한다.
  endSession,
}

class RestPolicy {
  RestPolicy({
    this.dangerSigma = 3.0,
    this.rearmSigma = 2.0,
    this.cooldownSec = 20.0,
  });

  /// 강판이 걸리는 σ.
  final double dangerSigma;

  /// 이 아래로 내려와야 트리거가 다시 무장된다.
  final double rearmSigma;

  /// 휴식 시간(초).
  final double cooldownSec;

  bool _armed = true;
  double? _restStartSec;

  /// 트리거가 무장돼 있는가.
  bool get isArmed => _armed;

  /// 휴식 중인가.
  bool get isResting => _restStartSec != null;

  /// 휴식 남은 시간(초). 휴식 중이 아니면 null.
  double? remainingSec(double nowSec) {
    final start = _restStartSec;
    if (start == null) return null;
    final left = cooldownSec - (nowSec - start);
    return left < 0 ? 0.0 : left;
  }

  /// 매 갱신마다 호출. 강판을 걸어야 하면 true.
  ///
  /// [sigma] 가 null(baseline 전·신호 불량)이면 아무 일도 하지 않는다 —
  /// 모르는 상태를 위험으로 단정하지 않는다.
  bool shouldTriggerRest(double nowSec, double? sigma) {
    if (sigma == null || isResting) return false;

    // 회복되면 다시 무장.
    if (!_armed && sigma < rearmSigma) _armed = true;

    if (_armed && sigma >= dangerSigma) {
      _restStartSec = nowSec;
      _armed = false;
      return true;
    }
    return false;
  }

  /// 쿨다운이 끝났는가.
  bool isCooldownOver(double nowSec) {
    final start = _restStartSec;
    return start != null && nowSec - start >= cooldownSec;
  }

  /// 휴식 종료 시점의 σ로 다음 행동을 정한다.
  RestDecision finishRest(double? sigma) {
    _restStartSec = null;
    if (sigma == null || sigma < rearmSigma) {
      _armed = true;
      return RestDecision.resume;
    }
    if (sigma < dangerSigma) {
      _armed = false;
      return RestDecision.resumeDisarmed;
    }
    return RestDecision.endSession;
  }

  void reset() {
    _armed = true;
    _restStartSec = null;
  }
}
