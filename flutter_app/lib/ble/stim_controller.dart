import 'dart:async';

import '../signal/constants.dart';
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

/// 펌웨어 `STIM_TIMEOUT_MS` (초).
///
/// **펌웨어를 고치면 이 값도 같이 고친다.** 아래 상한들이 전부 여기서
/// 유도되므로, 이 한 줄만 맞으면 앱은 어떤 펌웨어 값에서도 안전하다.
///
/// 검증 기록 — 왜 이게 지금까지 문제되지 않았나:
/// 레거시 앱은 `trigger_stim` 을 한 번도 보내지 않았다. 그래서 실측 88세션
/// 내내 펌웨어의 `isStimulating` 은 false 였고(마사지기를 손으로 켰다),
/// 이 타임아웃도 BLE 끊김 페일세이프도 **한 번도 발동한 적이 없다**.
/// 세션이 중앙 10.2분씩 이어진 것도 그 때문이다.
/// 앱이 자극을 `trigger_stim` 으로 몰기 시작하면 둘 다 비로소 실재한다.
const int kFirmwareStimTimeoutSeconds = 180;

/// 펌웨어 타임아웃까지 남겨 두는 여유(초).
const int kStimSafetyMarginSeconds = 10;

/// 자극 상한을 정한다.
///
/// 세션 상한과 "펌웨어 타임아웃 − 여유" 중 **짧은 쪽**.
/// 순수 함수라 펌웨어 값을 바꿔가며 정책을 검증할 수 있다.
int effectiveStimCapSeconds({
  required int firmwareTimeoutS,
  required int sessionMaxS,
  int margin = kStimSafetyMarginSeconds,
}) {
  final fwCap = firmwareTimeoutS - margin;
  final safeFw = fwCap < 1 ? (firmwareTimeoutS / 2).floor() : fwCap;
  return sessionMaxS < safeFw ? sessionMaxS : safeFw;
}

const int _specSessionMaxSeconds = kSessionMaxMin * 60;
const int _firmwareCapSeconds =
    kFirmwareStimTimeoutSeconds - kStimSafetyMarginSeconds;

/// 로컬 자극 상한(초).
///
/// **로컬 자동 종료가 언제나 1차 안전장치**여야 한다(하드 제약 8).
/// 펌웨어 타임아웃이 먼저 걸리면 앱은 자극이 왜 멎었는지 모른 채 게임을
/// 계속 돌린다 — 화면의 손은 쥐어지는데 실제 수축은 없는 상태가 된다.
const int kLocalMaxStimSeconds = _specSessionMaxSeconds < _firmwareCapSeconds
    ? _specSessionMaxSeconds
    : _firmwareCapSeconds;

/// 실질 세션 상한(초).
///
/// 세션이 자극보다 오래 살아 있으면 안 되므로 자극 상한과 같다.
///
/// 현 펌웨어(180초)에서는 **170초 = 2.8분**이다. 스펙의 15분을 쓰려면
/// 펌웨어 `STIM_TIMEOUT_MS` 를 960000(16분)으로 올리고 위
/// [kFirmwareStimTimeoutSeconds] 를 960 으로 맞추면 자동으로 900초가 된다.
const int kEffectiveSessionMaxSeconds = kLocalMaxStimSeconds;

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
    this.manual = false,
  })  : maxStimDuration =
            maxStimDuration ?? const Duration(seconds: kLocalMaxStimSeconds),
        dataTimeout =
            dataTimeout ?? const Duration(seconds: kStimDataTimeoutSeconds) {
    _linkSub = link.stateStream.listen(_onLinkState);
  }

  final DeviceLink link;
  final Duration maxStimDuration;
  final Duration dataTimeout;

  /// 자극기를 사람이 손으로 켜고 끄는가.
  ///
  /// true 면 `trigger_stim` 을 **보내지 않는다.** 마사지기가 펌웨어에 아직
  /// 배선되지 않아 그 명령이 아무 데도 닿지 않기 때문이다. 상태 추적과
  /// 전이 로그는 그대로 남긴다 — 세션 기록에서 자극 구간이 사라지면
  /// 그 세션은 나중에 해석할 수 없다.
  ///
  /// **여기서 잃는 것:** 앱이 자극을 끌 수 없다. 워치독도, 최대 시간도,
  /// 비상 정지도 사람에게 "끄세요"라고 말할 수 있을 뿐이다. 화면은 이걸
  /// 숨기지 않아야 한다.
  final bool manual;

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

    if (!manual) {
      try {
        await link.send({'cmd': 'trigger_stim', 'on': true});
      } catch (_) {
        _emit(
            on: false, reason: StimStopReason.deviceDisconnect, delivered: false);
        return false;
      }
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

    // 수동 모드에서는 보낼 곳이 없다. delivered:false 로 남겨 기록이
    // "앱이 껐다"고 말하지 않게 한다 — 실제로 끄는 것은 사람이다.
    var delivered = false;
    if (!manual) {
      delivered = true;
      try {
        await link.send({'cmd': 'trigger_stim', 'on': false});
      } catch (_) {
        // 링크가 죽었으면 펌웨어가 onDisconnect 에서 끈다.
        delivered = false;
      }
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
