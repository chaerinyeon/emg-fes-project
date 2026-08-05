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
  SessionMachine(this.stim, {EndConditionEvaluator? endConditions})
      : end = endConditions ?? EndConditionEvaluator() {
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
  void submitAttachmentCheck(AttachmentCheck result) {
    if (_state != SessionState.attachmentCheck) return;
    _lastCheck = result;
    if (!result.passed) return; // 재부착 안내를 띄우고 머문다
    _go(SessionState.intensityWizard);
  }

  /// 강도 마법사 결과.
  ///
  /// 목표는 `events/burst >= [kMinEventsPerBurst]` 를 만족하는 **최소** 강도다.
  /// 못 넘으면 통과시키지 않는다 — 신호가 안 잡히는 채로 게임에 들어가면
  /// 화면의 손이 내내 안 쥐어진다.
  void submitIntensity({required int level, required double eventsPerBurst}) {
    if (_state != SessionState.intensityWizard) return;
    if (eventsPerBurst < kMinEventsPerBurst) return;
    _intensity = level.clamp(kMinIntensityLevel, kMaxIntensityLevel);
    _go(SessionState.syncing);
  }

  /// 동기화 진행. [tSeconds] 가 [kSyncWindowS] 를 넘으면 playing.
  void onSyncProgress(double tSeconds) {
    if (_state != SessionState.syncing) return;
    _lastTSeconds = tSeconds;
    if (tSeconds >= kSyncWindowS) _go(SessionState.playing);
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
