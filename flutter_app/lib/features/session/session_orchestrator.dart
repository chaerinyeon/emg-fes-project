import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../ble/device_connection.dart';
import '../../ble/stim_controller.dart';
import '../../data/local/session_store.dart';
import '../../data/remote/sync_service.dart';
import '../../game/core_loop.dart';
import '../../session/end_conditions.dart';
import '../../session/session_controller.dart';
import '../../signal/constants.dart';
import '../../signal/fatigue_engine.dart';
import '../../signal/reliability.dart';
import '../../signal/signal_pipeline.dart';

/// 화면이 읽는 신호 품질. **숫자가 아니라 상태다.**
enum SignalStatus { good, checkSensor, lost }

/// [SignalPipeline] → [SessionMachine] → [CoreLoop] → 저장/업로드를 잇는 조립부.
///
/// 화면은 이 클래스만 본다. 피로도 퍼센트는 **밖으로 내보내지 않는다**
/// (완료 기준: 앱 어디에도 피로도 퍼센트 숫자가 노출되지 않는다).
/// 피로는 수축 성공률이 떨어지고 화면의 손이 잘 안 쥐어지는 것으로
/// 저절로 드러난다.
class SessionOrchestrator extends ChangeNotifier {
  SessionOrchestrator({
    required this.link,
    required this.store,
    this.sync,
    required this.sessionId,
    required this.patientId,
    required this.deviceId,
    this.gameId = 'fishing',
    this.stageId = 'stage_1',
    this.appVersion = '1.0.0',
    this.fwVersion = 'unknown',
    DateTime Function()? now,
    int Function()? clockMs,
  }) : _now = now ?? DateTime.now,
       _clockMs = clockMs ?? (() => DateTime.now().millisecondsSinceEpoch) {
    stim = StimController(link);
    machine = SessionMachine(stim);
    machine.states.listen((_) => notifyListeners());
  }

  final DeviceLink link;
  final SessionStore store;
  final SyncService? sync;
  final String sessionId;
  final String patientId;
  final String deviceId;
  final String gameId;
  final String stageId;
  final String appVersion;
  final String fwVersion;

  final DateTime Function() _now;
  final int Function() _clockMs;

  late final StimController stim;
  late final SessionMachine machine;

  final SignalPipeline pipeline = SignalPipeline();
  final CoreLoop loop = CoreLoop();

  StreamSubscription<(int, int)>? _sampleSub;
  Timer? _cueTimer;

  final List<BurstRow> _pendingRows = <BurstRow>[];
  DateTime? _startedAt;

  // --- 화면이 읽는 상태 ---

  /// 화면의 손 상태.
  HandState hand = HandState.open;

  /// 큐가 나갔는가 (자극 300ms 전부터 자극까지). 손이 "쥐어지는 중".
  bool cueActive = false;

  /// 오늘 쥔 횟수.
  int get repCount => machine.repCount;

  SessionState get state => machine.state;
  SessionEndReason? get endReason => machine.endReason;
  int get intensityLevel => machine.intensityLevel;
  AttachmentCheck? get lastCheck => machine.lastAttachmentCheck;

  SignalStatus signal = SignalStatus.good;

  /// 마지막 수축 성공 여부. 이펙트·햅틱 트리거용.
  bool? lastContractionOk;

  /// 성공 이펙트를 한 번만 터뜨리기 위한 카운터.
  int successPulse = 0;

  /// 세션 경과(초).
  double elapsedS = 0;

  // --- 수명주기 ---

  Future<void> begin() async {
    _startedAt = _now();
    await machine.begin();

    _sampleSub = rawSamples(link.rawPackets).listen(_onSample);

    // 큐 스케줄러는 **렌더 루프가 아니라** 별도 타이머로 돈다.
    // 프레임이 밀려도 타이밍이 밀리면 안 된다.
    _cueTimer = Timer.periodic(const Duration(milliseconds: 8), (_) {
      _pumpCues();
    });

    if (link.state == LinkState.connected) machine.onLinkConnected();
    notifyListeners();
  }

  /// 부착 체크 3항목 자동 판정.
  ///
  /// 화면이 "느낌"으로 정하지 않고 실제 신호에서 뽑는다.
  /// - EMG 전극: DC 캘리브가 끝났고, 그 구간이 조용했고, 잡음이 정상 범위인가.
  ///   ([DcCalibrator.looksQuiet] 이 false 면 자극이 섞였거나 전극이 뜬 것)
  /// - 자극 패드: 자극이 실제로 검출됐는가 (버스트가 잡혔는가).
  /// - 기기: 링크가 붙어 있는가.
  AttachmentCheck runAttachmentCheck() {
    final calibrated = pipeline.dcOffset != null;
    final noise = pipeline.noiseSigma;

    return AttachmentCheck(
      emgElectrodeOk:
          calibrated &&
          pipeline.dcWindowLooksQuiet &&
          noise > 0 &&
          noise < kAttachMaxNoiseSigma,
      // TODO(P0): 최저 강도 테스트 펄스 1회를 쏘고 M-wave 검출을 보는 방식으로
      //           바꾼다. 지금은 이미 들어온 자극이 검출됐는지로 대신한다.
      stimPadOk: pipeline.reliability.burstCount > 0,
      deviceOk: link.state == LinkState.connected,
    );
  }

  void submitAttachmentCheck(AttachmentCheck r) {
    machine.submitAttachmentCheck(r);
    notifyListeners();
  }

  /// 강도 한 단계를 실제로 걸어 보고 events/burst 를 잰다.
  ///
  /// 자극을 켜고 몇 버스트를 흘려보낸 뒤 끈다. 강도 자체는 기기 다이얼로
  /// 조절되므로(오므론 HV-F022-V), 여기서 하는 일은 "이 단계에서 신호가
  /// 잡히는가"를 재는 것뿐이다.
  Future<double> measureIntensity(
    int level, {
    Duration window = const Duration(seconds: 6),
  }) async {
    final before = pipeline.reliability.burstCount;
    await stim.start();
    await Future<void>.delayed(window);
    await stim.stop(reason: StimStopReason.sessionEnd);

    final gate = pipeline.reliability;
    if (gate.burstCount <= before) return 0;
    return gate.eventsPerBurst;
  }

  void submitIntensity({required int level, required double eventsPerBurst}) {
    machine.submitIntensity(level: level, eventsPerBurst: eventsPerBurst);
    notifyListeners();
  }

  bool lowerIntensity() {
    final ok = machine.lowerIntensity();
    notifyListeners();
    return ok;
  }

  /// 중단 버튼. 자극이 **가장 먼저** 꺼진다.
  Future<void> stopByUser() => _finish(SessionEndReason.userStop);

  /// 통증 중단 — 다른 어떤 처리보다 우선.
  Future<void> emergencyStop() async {
    await stim.emergencyStop();
    await _finish(SessionEndReason.userStop);
  }

  void _onSample((int, int) s) {
    final (t, adc) = s;
    final r = pipeline.addSample(t, adc);
    if (r == null) return;
    _onBurst(r);
  }

  void _onBurst(BurstResult r) {
    elapsedS = r.tSeconds;

    // 위상을 게임 루프에 물린다.
    loop.syncTo(
      burstIndex: r.index,
      stimOnsetMs: r.stimOnsetMs,
      periodMs: pipeline.periodMs,
    );
    loop.setContractionResult(burstIndex: r.index, ok: r.contractionOk);

    // 신호 품질 — 숫자가 아니라 상태로.
    signal = switch (pipeline.reliability.status) {
      ReliabilityStatus.ok => SignalStatus.good,
      ReliabilityStatus.degraded => SignalStatus.checkSensor,
      ReliabilityStatus.lost => SignalStatus.lost,
    };
    if (r.advice == FatigueAdvice.checkSensor) {
      signal = SignalStatus.checkSensor;
    }

    _pendingRows.add(
      BurstRow(
        sessionId: sessionId,
        tS: r.tSeconds,
        p2p: r.p2p,
        fatigue: r.fatiguePct,
        contractionOk: r.contractionOk,
        valid: r.reliable,
      ),
    );

    if (machine.state == SessionState.syncing) {
      machine.onSyncProgress(r.tSeconds);
    } else if (machine.state == SessionState.playing) {
      unawaited(
        machine.onBurst(
          fatiguePct: r.fatiguePct,
          contractionOk: r.contractionOk,
          reliable: r.reliable,
          tSeconds: r.tSeconds,
        ),
      );
    }

    unawaited(_pushLive());

    if (machine.state == SessionState.report) {
      unawaited(_finish(machine.endReason ?? SessionEndReason.error));
    }
    notifyListeners();
  }

  void _pumpCues() {
    final events = loop.advanceTo(_clockMs());
    if (events.isEmpty) return;

    for (final e in events) {
      switch (e.type) {
        case CueEventType.cue:
          cueActive = true;
        case CueEventType.stimOnset:
          break;
        case CueEventType.judge:
          lastContractionOk = e.contractionOk;
          hand = handStateFor(
            stimOn: true,
            contractionOk: e.contractionOk ?? false,
          );
          if (e.contractionOk == true) successPulse++;
        case CueEventType.release:
          cueActive = false;
          hand = HandState.open;
      }
    }
    notifyListeners();
  }

  Future<void> _pushLive() async {
    final s = sync;
    if (s == null) return;
    await s.pushLive(
      LiveRow(
        sessionId: sessionId,
        updatedAt: _now(),
        elapsedS: elapsedS.round(),
        repCount: repCount,
        fatigue: 0, // 웹에만 있는 값. 앱은 계산해 보내지 않는다.
        successRate50: machine.successRate,
        signalQuality: signal.name,
        state: machine.state.name,
      ),
    );
  }

  bool _finished = false;

  Future<void> _finish(SessionEndReason reason) async {
    if (_finished) return;
    _finished = true;

    await machine.stop(reason);
    await _sampleSub?.cancel();
    _sampleSub = null;
    _cueTimer?.cancel();
    _cueTimer = null;

    final gate = pipeline.reliability;
    await store.saveSession(
      SessionSummary(
        id: sessionId,
        patientId: patientId,
        deviceId: deviceId,
        startedAt: _startedAt ?? _now(),
        endedAt: _now(),
        durationS: elapsedS.round(),
        gameId: gameId,
        stageId: stageId,
        intensityLevel: machine.intensityLevel,
        endReason: machine.endReason ?? reason,
        repCount: machine.repCount,
        successRate: machine.successRate,
        maxFatigue: _maxFatigue,
        endFatigue: _endFatigue,
        onsetS: null,
        burstCount: _pendingRows.length,
        detectRate: gate.detectRate,
        eventsPerBurstMedian: gate.eventsPerBurst,
        levelChangeCount: pipeline.levelSegmentCount - 1,
        reliabilityGrade: gate.grade,
        stimPeriodMs: pipeline.periodMs?.round() ?? kStimPeriodMs,
        appVersion: appVersion,
        fwVersion: fwVersion,
      ),
    );
    await store.appendBursts(_pendingRows);

    // 업로드는 실패해도 좋다. 기록은 이미 로컬에 있다.
    unawaited(sync?.flush() ?? Future<void>.value());
    notifyListeners();
  }

  double get _maxFatigue => _pendingRows.isEmpty
      ? 0
      : _pendingRows.map((r) => r.fatigue).reduce((a, b) => a > b ? a : b);

  double get _endFatigue {
    if (_pendingRows.isEmpty) return 0;
    final q = (_pendingRows.length / 4).ceil();
    final tail = _pendingRows.sublist(_pendingRows.length - q);
    return tail.map((r) => r.fatigue).reduce((a, b) => a + b) / tail.length;
  }

  @override
  void dispose() {
    _sampleSub?.cancel();
    _cueTimer?.cancel();
    unawaited(machine.dispose());
    super.dispose();
  }
}
