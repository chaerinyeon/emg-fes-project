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

/// 워치독 되감기 간격. 표본은 초당 1000개라 매번 되감으면 타이머만 만든다.
const int kWatchdogFeedIntervalMs = 250;

/// 피로 "발생 시점" 을 결과·기록 화면에 한 문장으로 적기 위한 **표시 전용**
/// 기준.
///
/// 종료 임계([kFatigueThresholdPct])와 다른 값이고 다른 목적이다. 그쪽은
/// 아직 null 이라 자동 종료를 걸지 않는다. 여기서 정하는 건 "언제부터 힘이
/// 줄기 시작했는지" 를 말하기 위한 지점일 뿐이며, **어떤 제어에도 쓰이지
/// 않는다.** 신뢰도가 깨진 버스트는 세지 않는다.
const double kFatigueOnsetDisplayPct = 50.0;
const int kFatigueOnsetSustainBursts = 5;

/// 치료사 보기의 실시간 파형 버퍼 — 1kHz 를 이 배수로 솎는다.
const int kWavePreviewDecim = 8;

/// 파형 버퍼 길이(점). 8배 솎음이므로 1920ms ≈ 자극 한 주기가 보인다.
const int kWavePreviewLen = 240;

/// [SignalPipeline] → [SessionMachine] → [CoreLoop] → 저장/업로드 조립부.
///
/// 화면은 이 클래스만 본다. 피로도 퍼센트는 **밖으로 내보내지 않는다** —
/// 피로는 잡히는 공이 줄어드는 것으로 저절로 드러난다.
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
    Duration? stimDataTimeout,
  }) : _now = now ?? DateTime.now,
       _clockMs = clockMs ?? (() => DateTime.now().millisecondsSinceEpoch) {
    stim = StimController(link, dataTimeout: stimDataTimeout);
    machine = SessionMachine(stim);
    machine.states.listen((s) {
      // 동기화부터 자극이 나가야 주기·A_ref 가 잡힌다. 없으면 영영 syncing.
      if (s == SessionState.syncing) unawaited(stim.start());
      notifyListeners();
    });
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

  final _cues = StreamController<CueEvent>.broadcast();

  /// 큐 이벤트 원본. 게임이 물린다 — 포구는 프레임이 아니라 사건이다.
  Stream<CueEvent> get cues => _cues.stream;

  /// 게임이 읽는 시계. 큐 이벤트의 `atMs` 와 같은 기준이어야 한다.
  int nowMs() => _clockMs();

  final List<BurstRow> _pendingRows = <BurstRow>[];
  DateTime? _startedAt;

  /// 이번 세션의 버스트 행. 결과 화면의 **치료사 보기**가 읽는다.
  List<BurstRow> get bursts => List.unmodifiable(_pendingRows);

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

  /// 마지막 버스트 결과. **치료사 보기 전용** — 환자 화면은 읽지 않는다.
  BurstResult? lastBurst;

  /// 마지막 표본이 도착한 벽시계 시각(ms). 관찰 화면의 정지 판정용.
  int? lastSampleWallMs;

  /// 피로가 시작된 시각(초). 없으면 null — "끝까지 힘이 남았다".
  double? get fatigueOnsetS => _onsetS;

  double? _onsetS;
  int _onsetRun = 0;

  // 치료사 보기의 실시간 파형. 링버퍼라 열려 있지 않아도 비용이 없고,
  // 열려 있어도 **큐 스케줄러와 무관하다**(하드 제약 7 — 그래프가 게임
  // 타이밍을 밀면 안 된다). 그래서 여기서는 notifyListeners 를 부르지
  // 않는다. 패널이 자기 주기로 읽어 간다.
  final List<double> _wave = List<double>.filled(kWavePreviewLen, 0);
  int _waveWrite = 0;
  int _waveDecim = 0;

  /// 오래된 점부터 순서대로 뽑은 파형 스냅샷.
  List<double> waveSnapshot() => <double>[
    ..._wave.sublist(_waveWrite),
    ..._wave.sublist(0, _waveWrite),
  ];

  // --- 수명주기 ---

  Future<void> begin() async {
    _startedAt = _now();
    await machine.begin();

    _sampleSub = rawSamples(link.rawPackets).listen(_onSample);

    // 큐는 렌더 루프가 아니라 별도 타이머로 돈다 — 프레임이 밀려도 타이밍은 아니다.
    _cueTimer = Timer.periodic(const Duration(milliseconds: 8), (_) {
      _pumpCues();
    });

    if (link.state == LinkState.connected) machine.onLinkConnected();
    notifyListeners();
  }

  /// 부착 체크 3항목. 화면의 "느낌"이 아니라 실제 신호에서 뽑는다.
  AttachmentCheck runAttachmentCheck() {
    final noise = pipeline.noiseSigma;
    return AttachmentCheck(
      // 캘리브가 끝났고, 그 구간이 조용했고, 잡음이 정상 범위인가.
      emgElectrodeOk: pipeline.dcOffset != null &&
          pipeline.dcWindowLooksQuiet &&
          noise > 0 &&
          noise < kAttachMaxNoiseSigma,
      // TODO(P0): 최저 강도 테스트 펄스를 쏘고 M-wave 검출을 보는 방식으로.
      stimPadOk: pipeline.reliability.burstCount > 0,
      deviceOk: link.state == LinkState.connected,
    );
  }

  /// 판정이 설 때까지 기다렸다가 돌려준다.
  ///
  /// "아직 안 왔다"와 "안 붙었다"는 다른 사건이다. 켠 직후엔 캘리브도
  /// 버스트도 없어서, 바로 판정하면 멀쩡히 붙인 사람에게 오경보가 뜬다.
  /// [timeout] 안에 안 서면 그때 판정을 돌려준다 — 영원히 기다리지 않는다.
  Future<AttachmentCheck> awaitAttachmentCheck({
    Duration timeout = const Duration(seconds: 12),
    Duration poll = const Duration(milliseconds: 200),
  }) async {
    final deadline = _now().add(timeout);
    var r = runAttachmentCheck();
    while (!r.passed && _now().isBefore(deadline)) {
      await Future<void>.delayed(poll);
      r = runAttachmentCheck();
    }
    return r;
  }

  void submitAttachmentCheck(AttachmentCheck r) {
    machine.submitAttachmentCheck(r);
    notifyListeners();
  }

  /// 강도 한 단계를 실제로 걸어 보고 events/burst 를 잰다.
  ///
  /// 강도는 기기 다이얼로 조절되므로(오므론 HV-F022-V), 여기서 하는 일은
  /// "이 단계에서 신호가 잡히는가"를 재는 것뿐이다.
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
    if (ok) {
      _lastIntensityChange = (atS: elapsedS, reason: '사용자가 줄임');
    }
    notifyListeners();
    return ok;
  }

  /// 마지막 강도 변경 — 시각과 이유. 치료사 보기에만 보인다.
  ({double atS, String reason})? get lastIntensityChange =>
      _lastIntensityChange;

  ({double atS, String reason})? _lastIntensityChange;

  /// 치료사 보기를 연 횟수와 처음 연 시각.
  ///
  /// 임상 지표를 환자 화면 뒤에 숨긴 이상, **누가 언제 열었는지**는 남아야
  /// 한다. 공유 `session_events` 스키마에는 이 사건의 자리가 없어 여기
  /// 로컬로만 센다 — 서버 계약을 앱 사정으로 늘리지 않는다.
  int therapistViewOpens = 0;
  double? firstTherapistViewAtS;

  void noteTherapistViewOpened() {
    therapistViewOpens++;
    firstTherapistViewAtS ??= elapsedS;
  }

  /// 중단 버튼. 자극이 **가장 먼저** 꺼진다.
  Future<void> stopByUser() => _finish(SessionEndReason.userStop);

  /// 통증 중단 — 다른 어떤 처리보다 우선.
  Future<void> emergencyStop() async {
    await stim.emergencyStop();
    await _finish(SessionEndReason.userStop);
  }

  int? _lastWatchdogFeedMs;

  void _onSample((int, int) s) {
    final (t, adc) = s;

    // 워치독은 **모든 상태에서** 되감아야 한다. playing 에서만 되감으면
    // 동기화 30초를 못 버티고 자극이 꺼지는데 아무도 다시 켜지 않는다.
    final last = _lastWatchdogFeedMs;
    if (last == null || t - last >= kWatchdogFeedIntervalMs || t < last) {
      _lastWatchdogFeedMs = t;
      stim.noteDataReceived();
      // 관찰 화면이 "신호가 멈췄는가"를 볼 때 쓴다. 버스트 알림(1.6초 간격)
      // 으로는 못 본다 — 표본이 끊긴 것과 버스트 사이인 것이 구분되지 않는다.
      lastSampleWallMs = _clockMs();
    }

    if (++_waveDecim >= kWavePreviewDecim) {
      _waveDecim = 0;
      _wave[_waveWrite] = adc - (pipeline.dcOffset ?? adc.toDouble());
      _waveWrite = (_waveWrite + 1) % kWavePreviewLen;
    }

    final r = pipeline.addSample(t, adc);
    if (r == null) return;
    _onBurst(r);
  }

  void _onBurst(BurstResult r) {
    elapsedS = r.tSeconds;
    lastBurst = r;

    // 피로 발생 시점 — **표시 전용**. 한 번 정해지면 바꾸지 않는다.
    if (_onsetS == null && r.reliable) {
      if (r.fatiguePct >= kFatigueOnsetDisplayPct) {
        _onsetRun++;
        if (_onsetRun >= kFatigueOnsetSustainBursts) {
          // 연속 구간이 시작된 지점이 "줄기 시작한" 시각이다.
          _onsetS = r.tSeconds -
              (kFatigueOnsetSustainBursts - 1) * (pipeline.periodMs ?? 1618) /
                  1000.0;
        }
      } else {
        _onsetRun = 0;
      }
    }

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

    _pendingRows.add(BurstRow(
      sessionId: sessionId,
      tS: r.tSeconds,
      p2p: r.p2p,
      fatigue: r.fatiguePct,
      contractionOk: r.contractionOk,
      valid: r.reliable,
      rms: r.rms,
      mdf: r.mdfHz,
    ));

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
      if (!_cues.isClosed) _cues.add(e);
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
        onsetS: _onsetS,
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

  /// 마지막 ¼ 구간의 평균 피로.
  double get _endFatigue {
    if (_pendingRows.isEmpty) return 0;
    final tail = _pendingRows
        .sublist(_pendingRows.length - (_pendingRows.length / 4).ceil());
    return tail.map((r) => r.fatigue).reduce((a, b) => a + b) / tail.length;
  }

  @override
  void dispose() {
    _sampleSub?.cancel();
    _cueTimer?.cancel();
    unawaited(_cues.close());
    unawaited(machine.dispose());
    super.dispose();
  }
}
