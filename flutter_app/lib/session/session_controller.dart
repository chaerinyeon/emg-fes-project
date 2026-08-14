import 'dart:async';

import '../ble/device_connection.dart';
import '../ble/stim_controller.dart';
import '../signal/constants.dart';
import 'end_conditions.dart';

/// 세션 상태 (앱 개발 프롬프트 3장 단계 3).
enum SessionState {
  idle,
  connecting,
  attachmentCheck,
  intensityWizard,

  /// 측정 시작을 기다린다. 게임 화면 위에 "측정 시작" 카드가 덮여 있다.
  ///
  /// ## 왜 이 상태가 따로 있는가
  ///
  /// 예전에는 강도를 확정하는 순간 곧바로 [syncing] 으로 넘어가 자극이 나가고
  /// 기준값 수집이 시작됐다. 그런데 그 시점은 환자가 아직 자세를 잡는 중이다 —
  /// 팔을 옮기고 손을 놓는 동작이 그대로 DC offset·잡음·A_ref 에 들어갔다.
  /// 기준값이 오염되면 그 위의 피로도 전부가 그만큼 틀어진다.
  ///
  /// 그래서 **"지금부터 잰다"를 사람이 선언**하게 한다. 여기서부터가 세션의
  /// t=0 이고, DC 보정도 baseline 도 피로도도 전부 이 지점 기준이다.
  readyToMeasure,

  /// 자극 주기 동기화 + A_ref 워밍업 30초.
  /// 사용자에게는 **튜토리얼 라운드**로 보인다 — 대기 화면을 만들면 이탈한다.
  syncing,
  playing,
  ending,
  report,
}

/// 부착 체크 3항목 (자동 판정).
class AttachmentCheck {
  /// 무자극 baseline noise + DC offset 이 정상 범위인가.
  final bool emgElectrodeOk;

  /// 최저 강도 테스트 펄스에서 M-wave 가 검출됐는가.
  final bool stimPadOk;

  /// 배터리·BLE 신호 세기.
  final bool deviceOk;

  const AttachmentCheck({
    required this.emgElectrodeOk,
    required this.stimPadOk,
    required this.deviceOk,
  });

  bool get passed => emgElectrodeOk && stimPadOk && deviceOk;

  /// 실패한 항목 이름 (재부착 안내용).
  List<String> get failures => [
        if (!emgElectrodeOk) 'emg_electrode',
        if (!stimPadOk) 'stim_pad',
        if (!deviceOk) 'device',
      ];
}

/// 최저·최고 강도 단계.
const int kMinIntensityLevel = 1;
const int kMaxIntensityLevel = 10;

/// 세션 상태머신.
///
/// 지키는 것:
/// - **부착 체크와 강도 마법사를 통과하지 않으면 playing 에 들어갈 수 없다.**
/// - 어느 단계에서든 중단하면 즉시 [SessionState.report] 로 가고,
///   가는 길에 자극이 꺼진다.
/// - 강도는 세션 중 **하향만** 가능하다.
/// - 종료 사유는 첫 번째 것이 남는다. 뭉뚱그리지 않는다.
///
/// 이름 주의: 레거시 `lib/services/session_controller.dart` 의
/// `SessionController` 와 별개다. 그쪽은 기존 화면이 쓰는 옛 세대라
/// 건드리지 않았다.
class SessionMachine {
  /// [endConditions] 를 주지 않으면 시간 상한을 [kEffectiveSessionMaxSeconds]
  /// 로 잡는다. 스펙의 15분이 아니라 **자극이 실제로 유지되는 시간**이다.
  /// 세션이 자극보다 오래 살아 있으면 화면의 손은 쥐어지는데 실제 수축은
  /// 없는 상태가 되고, 훈련 효과가 조용히 사라진다.
  SessionMachine(this.stim, {EndConditionEvaluator? endConditions})
      : end = endConditions ??
            EndConditionEvaluator(
                maxSessionSeconds: kEffectiveSessionMaxSeconds) {
    _linkSub = stim.link.stateStream.listen((s) {
      if (s == LinkState.connected) return;
      if (_state == SessionState.idle ||
          _state == SessionState.report ||
          _state == SessionState.ending) {
        return;
      }
      unawaited(stop(SessionEndReason.deviceDisconnect));
    });
  }

  final StimController stim;
  final EndConditionEvaluator end;

  final _states = StreamController<SessionState>.broadcast();
  StreamSubscription<LinkState>? _linkSub;

  SessionState _state = SessionState.idle;
  AttachmentCheck? _lastCheck;
  int _intensity = kMinIntensityLevel;
  final Set<String> _forcedGates = {};
  SessionEndReason? _endReason;
  int _repCount = 0;
  int _successCount = 0;
  double _lastTSeconds = 0;

  SessionState get state => _state;
  Stream<SessionState> get states => _states.stream;
  AttachmentCheck? get lastAttachmentCheck => _lastCheck;
  int get intensityLevel => _intensity;
  SessionEndReason? get endReason => _endReason;
  int get repCount => _repCount;
  int get successCount => _successCount;
  double get elapsedSeconds => _lastTSeconds;

  double get successRate => _repCount == 0 ? 0 : _successCount / _repCount;

  /// 세션 중 강도 상향은 언제나 막혀 있다. UI 표시용.
  bool get raiseIntensityBlocked => true;

  /// 사용자가 손으로 열고 들어온 관문들 (`attachment_check`, `intensity`).
  ///
  /// 세션 기록에 그대로 남는다. 자동 판정을 통과한 세션과 우회한 세션을
  /// 나중에 구분하지 못하면, 신호가 약한 줄 알면서 넣은 세션이 정상 세션과
  /// 섞여 데이터셋 전체의 기준점이 흐려진다.
  Set<String> get forcedGates => Set.unmodifiable(_forcedGates);

  /// 자동 판정 하나라도 우회했는가.
  bool get wasForced => _forcedGates.isNotEmpty;

  void _go(SessionState s) {
    if (_state == s) return;
    _state = s;
    if (!_states.isClosed) _states.add(s);
  }

  /// idle → connecting.
  Future<void> begin() async {
    if (_state != SessionState.idle) return;
    _go(SessionState.connecting);
  }

  /// 기기가 붙었다. connecting → attachmentCheck.
  void onLinkConnected() {
    if (_state != SessionState.connecting) return;
    _go(SessionState.attachmentCheck);
  }

  /// 부착 체크 결과. 통과해야만 다음 단계로 간다.
  ///
  /// [force] 는 자동 판정이 실패로 끝난 뒤 사용자가 그래도 진행하겠다고
  /// 정했을 때만 온다. 판정 자체를 건너뛰지는 않는다 — 결과는 그대로
  /// 기록하고, 우회했다는 사실만 [forcedGates] 에 얹는다.
  void submitAttachmentCheck(AttachmentCheck result, {bool force = false}) {
    if (_state != SessionState.attachmentCheck) return;
    _lastCheck = result;
    if (!result.passed) {
      if (!force) return; // 재부착 안내를 띄우고 머문다
      _forcedGates.add('attachment_check');
    }
    _go(SessionState.intensityWizard);
  }

  /// 강도 마법사 결과.
  ///
  /// 목표는 `events/burst >= [kMinEventsPerBurst]` 를 만족하는 **최소** 강도다.
  /// 못 넘으면 통과시키지 않는다 — 신호가 안 잡히는 채로 게임에 들어가면
  /// 화면의 손이 내내 안 쥐어진다.
  ///
  /// [force] 면 그걸 알고도 들어간다. 게임이 반응하지 않는 것은 우회의
  /// 결과지 고장이 아니므로, [forcedGates] 에 남겨 결과 화면이 그렇게
  /// 설명할 수 있게 한다.
  void submitIntensity({
    required int level,
    required double eventsPerBurst,
    bool force = false,
  }) {
    if (_state != SessionState.intensityWizard) return;
    if (eventsPerBurst < kMinEventsPerBurst) {
      if (!force) return;
      _forcedGates.add('intensity');
    }
    _intensity = level.clamp(kMinIntensityLevel, kMaxIntensityLevel);
    _go(SessionState.readyToMeasure);
  }

  /// "측정 시작" 을 눌렀다. readyToMeasure → syncing.
  ///
  /// 여기서부터 센서를 읽고 기준값을 잡는다. 자극은 영점 보정이 끝난 뒤에
  /// 켜진다 — 그 판단은 [SessionOrchestrator] 가 한다.
  void startMeasurement() {
    if (_state != SessionState.readyToMeasure) return;
    _go(SessionState.syncing);
  }

  /// 동기화 진행. [tSeconds] 가 [kSyncWindowS] 를 넘으면 playing.
  void onSyncProgress(double tSeconds) {
    if (_state != SessionState.syncing) return;
    _lastTSeconds = tSeconds;
    if (tSeconds >= kSyncWindowS) _go(SessionState.playing);
  }

  /// 동기화가 **막혔을 때만** 게임으로 보낸다.
  ///
  /// 정상 경로는 [onSyncProgress] 다 — 버스트가 [kSyncWindowS] 를 채워야
  /// 한다. 여기는 버스트가 하나도 오지 않는 상황을 위한 비상구다.
  ///
  /// 그 세션은 A_ref 가 서지 않았으므로 **피로 판정을 믿을 수 없다.**
  /// [forcedGates] 에 남겨, 나중에 그 세션을 정상 세션과 섞지 않게 한다.
  void skipSync() {
    if (_state != SessionState.syncing) return;
    _forcedGates.add('sync');
    _go(SessionState.playing);
  }

  /// 세션 중 강도 하향. 성공하면 true.
  bool lowerIntensity() {
    if (_intensity <= kMinIntensityLevel) return false;
    _intensity--;
    return true;
  }

  /// 버스트 1건. 종료 조건이 걸리면 스스로 끝낸다.
  Future<void> onBurst({
    required double fatiguePct,
    required bool contractionOk,
    required bool reliable,
    required double tSeconds,
  }) async {
    if (_state != SessionState.playing) return;

    _repCount++;
    if (contractionOk) _successCount++;
    _lastTSeconds = tSeconds;
    stim.noteDataReceived();

    end.addBurst(
      fatiguePct: fatiguePct,
      contractionOk: contractionOk,
      reliable: reliable,
      tSeconds: tSeconds,
    );

    final t = end.triggered;
    if (t != null) await stop(t);
  }

  /// 스테이지 목표 달성.
  Future<void> completeGame() => stop(SessionEndReason.gameComplete);

  /// 어느 단계에서든 즉시 종료한다. 첫 사유가 남는다.
  Future<void> stop(SessionEndReason reason) async {
    if (_state == SessionState.report || _state == SessionState.ending) return;
    _endReason = reason;
    end.signal(reason);
    _go(SessionState.ending);

    // 자극부터 끈다. 다른 어떤 처리보다 우선.
    if (reason == SessionEndReason.deviceDisconnect) {
      // 링크가 없으니 보낼 수 없다. StimController 가 이미 로컬로 내렸다.
    } else {
      await stim.stop(reason: _toStimReason(reason));
    }

    _go(SessionState.report);
  }

  /// 통증 중단 — 자극을 먼저 끊고 세션을 닫는다.
  Future<void> emergencyStop() async {
    await stim.emergencyStop();
    await stop(SessionEndReason.userStop);
  }

  static StimStopReason _toStimReason(SessionEndReason r) => switch (r) {
        SessionEndReason.userStop => StimStopReason.userStop,
        SessionEndReason.remoteStop => StimStopReason.remoteStop,
        SessionEndReason.signalLost => StimStopReason.signalLost,
        SessionEndReason.deviceDisconnect => StimStopReason.deviceDisconnect,
        SessionEndReason.timeout => StimStopReason.maxDuration,
        _ => StimStopReason.sessionEnd,
      };

  Future<void> dispose() async {
    await _linkSub?.cancel();
    _linkSub = null;
    await stim.dispose();
    await _states.close();
  }
}
