import 'constants.dart';

enum ReliabilityStatus {
  /// events/burst 와 검출률이 모두 기준 이상. 피로도 판정을 신뢰한다.
  ok,

  /// 기준 미달. **피로도 판정을 보류**하고 "센서 확인"을 띄운다.
  degraded,

  /// 검출 실패가 [kSignalLostTimeoutS] 지속. 자극 중단 → 부착 체크로.
  lost,
}

/// 신뢰도 게이팅 (공통 컨텍스트 2.4).
///
/// 실측 88세션 중 58세션만 이 기준을 통과했다.
/// **게이팅을 빼면 3분의 1은 틀린 값을 보여주게 된다.**
class ReliabilityGate {
  int _burstCount = 0;
  int _eventTotal = 0;
  double? _lastBurstAtS;
  double _nowS = 0.0;

  int get burstCount => _burstCount;

  double get eventsPerBurst =>
      _burstCount == 0 ? 0.0 : _eventTotal / _burstCount;

  /// 기대 펄스 수 대비 실제 검출 비율.
  double get detectRate => eventsPerBurst / kExpectedPulsesPerBurst;

  /// 버스트 하나가 처리됐음을 알린다.
  void addBurst({required int eventsInBurst, required double tSeconds}) {
    _burstCount++;
    _eventTotal += eventsInBurst;
    _lastBurstAtS = tSeconds;
    if (tSeconds > _nowS) _nowS = tSeconds;
  }

  /// 버스트가 없는 동안에도 시간을 흘려보낸다 (소실 감지용).
  void tick(double tSeconds) {
    if (tSeconds > _nowS) _nowS = tSeconds;
  }

  ReliabilityStatus get status {
    if (_lastBurstAtS != null &&
        (_nowS - _lastBurstAtS!) > kSignalLostTimeoutS) {
      return ReliabilityStatus.lost;
    }
    if (_burstCount == 0) return ReliabilityStatus.degraded;
    if (eventsPerBurst >= kMinEventsPerBurst && detectRate >= kMinDetectRate) {
      return ReliabilityStatus.ok;
    }
    return ReliabilityStatus.degraded;
  }

  /// 피로도 판정을 신뢰해도 되는가.
  bool get fatigueTrusted => status == ReliabilityStatus.ok;

  /// 세션 신뢰도 등급 (DB `sessions.reliability_grade`).
  String get grade {
    if (eventsPerBurst >= kGradeAEventsPerBurst &&
        detectRate >= kGradeADetectRate) {
      return 'A';
    }
    if (eventsPerBurst >= kMinEventsPerBurst && detectRate >= kMinDetectRate) {
      return 'B';
    }
    return 'C';
  }

  void reset() {
    _burstCount = 0;
    _eventTotal = 0;
    _lastBurstAtS = null;
    _nowS = 0.0;
  }
}
