import 'dart:async';

import 'device_connection.dart';

/// 자극이 꺼진 이유. 세션 종료 코드(공통 컨텍스트 5장)로 이어진다.
enum StimStopReason {
  userStop,
  remoteStop,
  maxDuration,
  signalLost,
  deviceDisconnect,
  emergency,
  sessionEnd,
}

/// 자극 상태 변화 1건. 감사 로그용.
class StimTransition {
  final bool on;
  final StimStopReason? reason;
  final DateTime at;

  /// 명령이 실제로 기기에 전달됐는가. false 면 로컬만 꺼진 상태다.
  final bool delivered;

  const StimTransition({
    required this.on,
    required this.at,
    required this.delivered,
    this.reason,
  });

  @override
  String toString() => '${at.toIso8601String()} stim=${on ? 'ON' : 'OFF'}'
      '${reason == null ? '' : ' (${reason!.name})'}'
      '${delivered ? '' : ' [NOT DELIVERED]'}';
}

/// 로컬 자극 상한(초).
///
/// 펌웨어 `STIM_TIMEOUT_MS` 는 180초다. **로컬 자동 종료가 언제나 1차
/// 안전장치**여야 하므로(하드 제약 8) 이 값은 반드시 그보다 짧다.
/// 펌웨어 타임아웃이 먼저 걸리면 앱은 자극이 왜 멎었는지 모른 채
/// 게임을 계속 돌리게 된다.
const int kLocalMaxStimSeconds = 170;

/// 자극 데이터가 이만큼 끊기면 자극을 멈춘다(초).
const int kStimDataTimeoutSeconds = 5;

/// 자극 ON/OFF + BLE 끊김 페일세이프.
///
/// 안전 규칙:
/// - 링크가 끊기면 **즉시** 꺼진 것으로 본다. 확인을 기다리지 않는다.
///   (펌웨어도 `onDisconnect` 에서 `triggerStimulation(false)` 한다 —
///    양쪽에서 끈다.)
/// - 재연결해도 자동으로 켜지지 않는다. 환자가 모르는 사이 자극이
///   되살아나면 안 된다.
/// - 비상 정지는 잠금이다. 명시적으로 풀기 전까지 start 를 거부한다.
/// - 전송이 실패해도 로컬 상태는 꺼짐으로 바꾼다. 앱이 "자극 중"이라고
///   믿고 있으면 그 위의 안전 로직이 전부 어긋난다.
class StimController {
  StimController(
    this.link, {
    Duration? maxStimDuration,
    Duration? dataTimeout,
  })  : maxStimDuration =
            maxStimDuration ?? const Duration(seconds: kLocalMaxStimSeconds),
        dataTimeout =
            dataTimeout ?? const Duration(seconds: kStimDataTimeoutSeconds) {
    _linkSub = link.stateStream.listen(_onLinkState);
  }

  final DeviceLink link;
  final Duration maxStimDuration;
  final Duration dataTimeout;

  final _transitions = StreamController<StimTransition>.broadcast();

  bool _stimulating = false;
  bool _emergencyLocked = false;
  StimStopReason? _lastStopReason;
  Timer? _maxTimer;
  Timer? _dataTimer;
  StreamSubscription<LinkState>? _linkSub;

  bool get isStimulating => _stimulating;
  bool get isEmergencyLocked => _emergencyLocked;
  StimStopReason? get lastStopReason => _lastStopReason;

  /// 자극 상태 변화 스트림. 세션 로그·웹 이벤트로 그대로 흘려보낸다.
  Stream<StimTransition> get transitions => _transitions.stream;

  /// 자극을 켠다. 켜졌으면 true.
  Future<bool> start() async {
    if (_stimulating) return true;
    if (_emergencyLocked) return false;
    if (link.state != LinkState.connected) return false;

    try {
      await link.send({'cmd': 'trigger_stim', 'on': true});
    } catch (_) {
      _emit(on: false, reason: StimStopReason.deviceDisconnect, delivered: false);
      return false;
    }

    _stimulating = true;
    _lastStopReason = null;
    _armTimers();
    _emit(on: true, delivered: true);
    return true;
  }

  /// 자극을 끈다. 이미 꺼져 있으면 아무것도 보내지 않는다.
  Future<void> stop({required StimStopReason reason}) async {
    if (!_stimulating) return;
    _stimulating = false;
    _lastStopReason = reason;
    _cancelTimers();

    var delivered = true;
    try {
      await link.send({'cmd': 'trigger_stim', 'on': false});
    } catch (_) {
      // 링크가 죽었으면 펌웨어가 onDisconnect 에서 끈다.
      delivered = false;
    }
    _emit(on: false, reason: reason, delivered: delivered);
  }

  /// 통증 중단 — 다른 어떤 처리보다 우선한다.
  ///
  /// 자극 중이 아니어도 전송한다. 앱의 상태 인식이 틀렸을 수 있기 때문이다.
  Future<void> emergencyStop() async {
    _stimulating = false;
    _emergencyLocked = true;
    _lastStopReason = StimStopReason.emergency;
    _cancelTimers();

    var delivered = true;
    try {
      await link.send({'cmd': 'emergency'});
    } catch (_) {
      delivered = false;
    }
    _emit(on: false, reason: StimStopReason.emergency, delivered: delivered);
  }

  /// 비상 잠금 해제. 사용자가 명시적으로 확인했을 때만 부른다.
  void clearEmergency() => _emergencyLocked = false;

  /// RAW 표본이 도착했음을 알린다. 데이터 워치독을 되감는다.
  void noteDataReceived() {
    if (!_stimulating) return;
    _dataTimer?.cancel();
    _dataTimer = Timer(dataTimeout, () {
      unawaited(stop(reason: StimStopReason.signalLost));
    });
  }

  void _onLinkState(LinkState s) {
    if (s == LinkState.connected) return;
    if (!_stimulating) return;
    // 링크가 없으니 명령을 보낼 수 없다. 로컬 상태만 즉시 내린다.
    _stimulating = false;
    _lastStopReason = StimStopReason.deviceDisconnect;
    _cancelTimers();
    _emit(
      on: false,
      reason: StimStopReason.deviceDisconnect,
      delivered: false,
    );
  }

  void _armTimers() {
    _cancelTimers();
    _maxTimer = Timer(maxStimDuration, () {
      unawaited(stop(reason: StimStopReason.maxDuration));
    });
    _dataTimer = Timer(dataTimeout, () {
      unawaited(stop(reason: StimStopReason.signalLost));
    });
  }

  void _cancelTimers() {
    _maxTimer?.cancel();
    _maxTimer = null;
    _dataTimer?.cancel();
    _dataTimer = null;
  }

  void _emit({
    required bool on,
    required bool delivered,
    StimStopReason? reason,
  }) {
    if (_transitions.isClosed) return;
    _transitions.add(StimTransition(
      on: on,
      reason: reason,
      at: DateTime.now(),
      delivered: delivered,
    ));
  }

  Future<void> dispose() async {
    await stop(reason: StimStopReason.sessionEnd);
    await _linkSub?.cancel();
    _linkSub = null;
    _cancelTimers();
    await _transitions.close();
  }
}
