import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../ble/device_connection.dart';
import '../../ble/stim_controller.dart';
import '../../data/local/session_store.dart';
import '../../data/remote/sync_service.dart';
import '../../game/core_loop.dart';
import '../../session/end_conditions.dart';
import '../../services/raw_logger.dart';
import '../../session/session_controller.dart';
import '../../signal/constants.dart';
import '../../signal/fatigue_engine.dart';
import '../../signal/reliability.dart';
import '../../signal/signal_pipeline.dart';

/// 화면이 읽는 신호 품질. **숫자가 아니라 상태다.**
enum SignalStatus { good, checkSensor, lost }

/// 워치독 되감기 간격(ms). 표본은 초당 수천 개라 매번 되감으면 타이머만 만든다.
///
/// 표본 인덱스로 비교하므로 fs 로 환산해서 쓴다 — 예전처럼 인덱스를 곧 ms 로
/// 보면 4kHz 에서 4배 자주 되감긴다.
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

/// 치료사 보기의 실시간 파형 버퍼 — 1kHz 기준 이 배수로 솎는다.
///
/// 실제 솎음 배수는 fs 에 비례해 키운다([SessionOrchestrator._waveDecimStep]).
/// 고정으로 두면 4kHz 에서 표시 구간이 4분의 1로 줄어, 한 주기가 보이던 창에
/// 4분의 1주기만 남는다.
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
    this.categoryCode,
    this.gameId = 'fishing',
    this.stageId = 'stage_1',
    this.appVersion = '1.0.0',
    this.fwVersion = 'unknown',
    DateTime Function()? now,
    int Function()? clockMs,
    Duration? stimDataTimeout,
    this.manualStim = false,
  }) : _now = now ?? DateTime.now,
       _clockMs = clockMs ?? (() => DateTime.now().millisecondsSinceEpoch) {
    stim = StimController(
      link,
      dataTimeout: stimDataTimeout,
      manual: manualStim,
    );
    machine = SessionMachine(stim);
    machine.states.listen((s) {
      // 동기화부터 자극이 나가야 주기·A_ref 가 잡힌다. 없으면 영영 syncing.
      //
      // 다만 **곧바로** 켜지는 않는다. 켜기 전에 무자극 구간에서 DC offset 과
      // 잡음 크기를 먼저 잡아야 한다 — 그 창에 자극이 섞이면 영점이 자극에
      // 끌려가고, 자극 검출 임계까지 함께 틀어진다.
      if (s == SessionState.syncing) {
        unawaited(_stimAfterDcCalibration());
        _armSyncStall();
      } else {
        _syncStall?.cancel();
        _syncStall = null;
      }
      notifyListeners();
    });
  }

  final DeviceLink link;
  final SessionStore store;
  final SyncService? sync;
  final String sessionId;
  final String patientId;
  final String deviceId;

  /// 마비 유형 코드 (`A`/`B`/`C`). 펌웨어가 `C` 를 완전마비 프로토콜로 읽는다.
  ///
  /// 모르면 null 로 두고 **보내지 않는다.** 빈 문자열을 보내면 펌웨어의
  /// `doc["category"] == "C"` 비교가 조용히 false 가 되어, 유형을 몰랐다는
  /// 사실이 "완전마비가 아니다"라는 판단으로 둔갑한다.
  final String? categoryCode;

  /// 자극기를 사람이 손으로 켜고 세기를 맞추는가.
  ///
  /// 마사지기가 아직 펌웨어에 배선되지 않아, 지금은 이게 기본이다. 앱은
  /// 자극 명령을 보내지 않고 **신호에서 자극을 찾기만 한다** — 검출은
  /// 원래부터 raw 파형에서 하므로 게임 진행에는 영향이 없다.
  final bool manualStim;

  final String gameId;
  final String stageId;
  final String appVersion;
  final String fwVersion;

  final DateTime Function() _now;
  final int Function() _clockMs;

  late final StimController stim;
  late final SessionMachine machine;

  /// 신호 엔진. **측정 시작에서 새 인스턴스로 갈린다**([startMeasurement]) —
  /// 준비 구간의 기준값을 세션으로 물려주지 않기 위해서다.
  ///
  /// 소비자들은 `o.pipeline.<값>` 으로 매번 꺼내 읽으므로 인스턴스를 붙들고
  /// 있지 않다. 붙들어 두면 교체 후에도 옛 값을 계속 보게 된다.
  SignalPipeline pipeline = SignalPipeline(fs: kDeviceSampleRateHz);

  /// ms 상수 ↔ 표본 수 환산. 파이프라인과 **같은** fs 를 봐야 한다.
  SampleClock get _clock => pipeline.clock;

  /// 워치독 되감기 간격을 표본 수로.
  late final int _watchdogFeedSamples =
      _clock.samples(kWatchdogFeedIntervalMs);

  /// 파형 미리보기 솎음 배수. 1kHz 기준값을 fs 에 비례해 키운다.
  late final int _waveDecimStep =
      (kWavePreviewDecim * _clock.fs / kSampleRateHz).round().clamp(1, 1 << 20);
  final CoreLoop loop = CoreLoop();

  StreamSubscription<(int, int)>? _sampleSub;
  StreamSubscription<List<int>>? _rawLogSub;
  Timer? _cueTimer;
  Timer? _syncStall;

  /// 동기화가 막히면 게임으로 내보낸다.
  ///
  /// 동기화를 미는 것은 시계가 아니라 버스트다. 버스트가 0개면 30분을
  /// 기다려도 안 끝나고, 화면은 「곧 함께 시작합니다」에 갇힌다. 버스트가
  /// 하나 올 때마다 시한을 되감으므로([_onBurst]) **정상 세션은 이 길로
  /// 오지 않는다** — 1.6초 간격이라 시한에 닿지 않는다.
  void _armSyncStall() {
    _syncStall?.cancel();
    _syncStall = Timer(const Duration(seconds: kSyncStallSeconds), () {
      if (machine.state != SessionState.syncing) return;
      machine.skipSync();
      notifyListeners();
    });
  }

  /// 이번 세션의 raw 파형 기록.
  ///
  /// **왜 여기 있는가:** 이게 없으면 실기기에서 난 실패를 노트북에서 재현할
  /// 방법이 없다. 자극이 안 잡히는 세션을 만나면 매번 기기 앞에서 추측해야
  /// 하고, 고쳤는지 확인할 방법도 없다. 저장해 두면 같은 파일을 오프라인
  /// 파이프라인(`test/signal/csv_regression_test.dart`)에 그대로 먹여
  /// 임계·펄스·버스트를 한 줄씩 볼 수 있다.
  ///
  /// 예전에는 옛 화면(`screens/home_page.dart`)만 이걸 썼다.
  final RawLogRecorder _rawLog = RawLogRecorder(sampleRateHz: kDeviceSampleRateHz);

  /// 저장된 raw CSV 경로. 저장 전이거나 실패했으면 null.
  String? rawLogPath;

  /// 기록된 표본 수 / 유실 추정치. 치료사 보기가 읽는다.
  int get rawLogSamples => _rawLog.length;
  int get rawLogDropped => _rawLog.dropped;

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

  /// 세션 수명 명령을 보낸다. 링크가 죽어 있으면 **조용히 넘긴다.**
  ///
  /// 자극을 끄는 명령과 달리 이건 알림용이라, 실패했다고 종료 처리를 무너뜨려
  /// 세션 기록을 통째로 잃으면 안 된다. 자극 차단의 책임은 [StimController] 에
  /// 있고 그쪽은 실패를 삼키지 않는다.
  Future<void> _sendQuietly(Map<String, dynamic> cmd) async {
    try {
      await link.send(cmd);
    } catch (_) {
      // 링크가 이미 끊긴 경우. 펌웨어는 연결이 끊기면 스스로 멈춘다.
    }
  }

  Future<void> begin() async {
    _startedAt = _now();
    await machine.begin();

    _sampleSub = rawSamples(link.rawPackets).listen(_onSample);

    // 파싱 전 바이너리를 그대로 받아 적는다. 세션 시작부터 받는 이유는
    // 펌웨어가 `start` 에서 표본 인덱스를 0 으로 리셋하기 때문이다 —
    // 파일의 시간축이 곧 세션의 시간축이 된다.
    _rawLog.start();
    _rawLogSub = link.rawPackets.listen(_rawLog.addPacket);

    // 펌웨어의 RAW 스트림을 연다. **이게 없으면 표본이 한 개도 오지 않는다.**
    //
    // 펌웨어는 `if (systemRunning && ...)` 뒤에서만 RAW 블록을 큐에 넣고,
    // `systemRunning` 은 오직 `start` 에서만 true 가 된다. `trigger_stim` 은
    // 마사지기 전원만 누르지 이 값을 건드리지 않는다.
    //
    // 빠뜨렸을 때가 고약하다 — 링크는 멀쩡히 연결돼 있어서 화면은 「연결 좋음」
    // 이고, 부착 확인도 통과하고(연결만으로 판정), 강도 측정만 0 을 낸다.
    // 그래서 원인이 syncing 영구 대기로 **한참 뒤에** 드러난다.
    await _sendQuietly({
      'cmd': 'start',
      if (categoryCode != null) 'category': categoryCode,
    });

    // 큐는 렌더 루프가 아니라 별도 타이머로 돈다 — 프레임이 밀려도 타이밍은 아니다.
    _cueTimer = Timer.periodic(const Duration(milliseconds: 8), (_) {
      _pumpCues();
    });

    if (link.state == LinkState.connected) machine.onLinkConnected();
    notifyListeners();
  }

  /// 부착 체크 3항목. 화면의 "느낌"이 아니라 실제 신호에서 뽑는다.
  /// **임시**: 부착 확인을 BLE 연결만으로 통과시킨다.
  ///
  /// 사용자 지시(2026-08-11) — "블루투스로 연결을 했으면 EMG·자극패드는
  /// 부착된 것으로 해줘". 신호 기반 판정이 실기기에서 반복적으로 전 구간을
  /// 막고 있어, 그 앞을 먼저 통과시키기 위한 조치다.
  ///
  /// **이걸 켜 두면 확인하지 않는 것들:** 전극이 실제로 피부에 붙었는지
  /// (잡음 존재), 캘리브 구간에 자극이 섞이지 않았는지, 자극 패드에서
  /// 반응이 돌아오는지. 붙지 않은 패드로도 훈련이 시작되고, 그 세션의
  /// 데이터는 학습에 쓸 수 없다.
  ///
  /// 되돌리려면 이 상수만 false 로 바꾸면 된다. 진짜 판정은 지우지 않고
  /// [runSignalAttachmentCheck] 에 그대로 남겨 두었다.
  static const bool kTrustLinkForAttachment = true;

  /// 부착 3항목. 지금은 [kTrustLinkForAttachment] 때문에 링크만 본다.
  AttachmentCheck runAttachmentCheck() {
    if (kTrustLinkForAttachment) {
      final connected = link.state == LinkState.connected;
      return AttachmentCheck(
        emgElectrodeOk: connected,
        stimPadOk: connected,
        deviceOk: connected,
      );
    }
    return runSignalAttachmentCheck();
  }

  /// 신호에서 직접 뽑는 진짜 부착 판정.
  ///
  /// [kTrustLinkForAttachment] 가 false 면 [runAttachmentCheck] 가 이걸 쓴다.
  AttachmentCheck runSignalAttachmentCheck() {
    final noise = pipeline.noiseSigma;
    return AttachmentCheck(
      // 캘리브가 끝났고, 그 구간이 조용했고, 잡음이 정상 범위인가.
      emgElectrodeOk: pipeline.dcOffset != null &&
          pipeline.dcWindowLooksQuiet &&
          noise > 0 &&
          noise < kAttachMaxNoiseSigma,
      // 자극이 나갔을 때 반응(버스트)이 잡혔는가.
      // 자극을 거는 것은 [runAttachmentCheckWithTestPulse] 의 몫이다.
      stimPadOk: pipeline.reliability.burstCount > 0,
      deviceOk: link.state == LinkState.connected,
    );
  }

  /// 테스트 자극을 걸어 보고 부착 3항목을 판정한다.
  ///
  /// ## 왜 자극을 여기서 켜는가
  ///
  /// `stimPadOk` 는 자극 반응이 잡혀야 서는데, 자극을 켜는 모든 경로가
  /// 이 확인의 **뒤에** 있었다. 실기기에서는 자극기를 손으로 켜 두지 않는
  /// 한 이 확인을 영영 통과할 수 없었다 — 확인 → 강도 → 게임 전 구간이
  /// 막힌다. 합성 링크가 자극 명령과 무관하게 아티팩트를 내보내는 탓에
  /// 테스트로도 잡히지 않았다.
  ///
  /// 이 자극은 **게이트 우회가 아니라 확인의 내용**이다. 그래서
  /// `attachmentCheck` 상태에서만, 짧게, 자동으로만 나간다. 임의 시점에
  /// 사람이 쏘는 TEST 화면의 `자극기 확인` 은 여전히 이 확인을 통과한
  /// 뒤에만 열린다.
  ///
  /// ## 순서가 중요하다
  ///
  /// **영점 보정이 끝나기 전에는 자극을 쏘지 않는다.** 도입부
  /// [kDcCalibWindowMs] 구간에 자극이 섞이면 `dcWindowLooksQuiet` 이
  /// false 가 되고, 멀쩡히 붙인 전극이 "안 붙었다"로 판정된다. 자극을
  /// 켜서 확인하려다 다른 항목을 깨뜨리는 셈이다.
  Future<AttachmentCheck> runAttachmentCheckWithTestPulse({
    Duration calibrationTimeout = const Duration(seconds: 8),
    Duration pulseWindow = const Duration(seconds: 5),
    Duration settle = const Duration(seconds: 2),
    Duration poll = const Duration(milliseconds: 100),
  }) async {
    // 링크만으로 통과시키는 동안에는 확인용 자극을 쏘지 않는다.
    //
    // 이 자극의 존재 이유는 `stimPadOk` 하나뿐이었다. 그 판정이 링크로
    // 대체된 지금 자극을 쏘면, 아무것도 판정하지 않으면서 전류만 나간다.
    if (kTrustLinkForAttachment) return runAttachmentCheck();

    // 1) 조용한 도입부가 끝나기를 기다린다.
    final deadline = _now().add(calibrationTimeout);
    while (pipeline.dcOffset == null && _now().isBefore(deadline)) {
      await Future<void>.delayed(poll);
    }

    // 2) 확인용 자극. 상태와 링크를 둘 다 본다 — 둘 중 하나라도 아니면
    //    자극은 나가지 않고, 판정은 그대로 실패로 돌아간다.
    if (machine.state == SessionState.attachmentCheck &&
        link.state == LinkState.connected &&
        !stim.isEmergencyLocked) {
      try {
        await stim.start();
        await Future<void>.delayed(pulseWindow);
      } finally {
        // 어떤 경로로 빠져나가도 자극은 꺼진다.
        await stim.stop(reason: StimStopReason.sessionEnd);
      }
      // 마지막 버스트는 다음 버스트가 시작될 때 닫힌다. 자극을 끄자마자
      // 판정하면 방금 들어온 반응을 못 본 채 "패드 불량"이 된다.
      await Future<void>.delayed(settle);
    }

    return runAttachmentCheck();
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

  void submitAttachmentCheck(AttachmentCheck r, {bool force = false}) {
    machine.submitAttachmentCheck(r, force: force);
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

  void submitIntensity({
    required int level,
    required double eventsPerBurst,
    bool force = false,
  }) {
    machine.submitIntensity(
      level: level,
      eventsPerBurst: eventsPerBurst,
      force: force,
    );
    notifyListeners();
  }

  // ── 측정 시작 ────────────────────────────────────────────
  //
  // 파이프라인은 [begin] 부터 계속 돈다 — 부착 확인과 강도 마법사가 신호를
  // 봐야 하기 때문이다. 대신 "측정 시작" 에서 **파이프라인을 새로 만든다.**
  // 그때까지 쌓인 DC offset·A_ref·신뢰도에는 환자가 자세를 잡는 동안의
  // 움직임이 섞여 있어 기준값으로 쓸 수 없다.

  bool _measuring = false;

  /// 측정이 시작됐는가. 화면이 "측정 시작" 카드를 덮을지 판단한다.
  bool get isMeasuring => _measuring;

  /// 지금 시간축의 원점이 되는 표본 인덱스.
  int? _sampleOrigin;

  /// "측정 시작". 여기서부터가 세션의 t=0 이다.
  ///
  /// 기준값을 전부 새로 잡는다 — DC 보정도, A_ref 도, 신뢰도 게이트도.
  /// 자극은 여기서 켜지 않는다. 무자극 영점 보정이 끝난 뒤 자동으로 켜진다
  /// ([_stimAfterDcCalibration]).
  void startMeasurement() {
    if (machine.state != SessionState.readyToMeasure) return;

    // 준비 구간의 값을 물려받지 않는다. 새 인스턴스가 가장 확실한 초기화다 —
    // 단계별로 reset 을 부르면 하나 빠뜨렸을 때 조용히 옛 기준이 남는다.
    pipeline = SignalPipeline(fs: pipeline.fs);
    _sampleOrigin = null; // 다음 표본이 t=0
    _measuring = true;
    elapsedS = 0;
    lastBurst = null;
    _onsetS = null;

    machine.startMeasurement();
    notifyListeners();
  }

  /// 영점 보정이 끝나면 자극을 켠다.
  ///
  /// 무자극 창에서 DC offset·잡음 크기를 먼저 확정해야 한다. 그 창에 자극이
  /// 섞이면 영점이 자극 쪽으로 끌려가고, 그 영점으로 세운 검출 임계도 함께
  /// 틀어져 버스트를 통째로 놓친다.
  ///
  /// 표본이 아예 안 오는 상황에서 영영 기다리지 않도록 시한을 둔다 — 시한을
  /// 넘기면 그냥 켠다. 자극이 안 나가면 세션은 어차피 syncing 에서 멈춘다.
  Future<void> _stimAfterDcCalibration({
    Duration timeout = const Duration(seconds: 6),
    Duration poll = const Duration(milliseconds: 50),
  }) async {
    final deadline = _now().add(timeout);
    while (pipeline.dcOffset == null && _now().isBefore(deadline)) {
      await Future<void>.delayed(poll);
      if (machine.state != SessionState.syncing) return; // 중간에 끝났다
    }
    if (machine.state != SessionState.syncing) return;
    await stim.start();
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

  int? _lastWatchdogFeedSample;

  /// [s] 는 `(표본 인덱스, ADC)`. 인덱스는 밀리초가 아니다 — fs 로 나눠야
  /// 시간이 된다.
  void _onSample((int, int) s) {
    final (idx, adc) = s;

    // 워치독은 **모든 상태에서** 되감아야 한다. playing 에서만 되감으면
    // 동기화 30초를 못 버티고 자극이 꺼지는데 아무도 다시 켜지 않는다.
    final last = _lastWatchdogFeedSample;
    if (last == null || idx - last >= _watchdogFeedSamples || idx < last) {
      _lastWatchdogFeedSample = idx;
      stim.noteDataReceived();
      // 관찰 화면이 "신호가 멈췄는가"를 볼 때 쓴다. 버스트 알림(1.6초 간격)
      // 으로는 못 본다 — 표본이 끊긴 것과 버스트 사이인 것이 구분되지 않는다.
      lastSampleWallMs = _clockMs();
    }

    if (++_waveDecim >= _waveDecimStep) {
      _waveDecim = 0;
      _wave[_waveWrite] = adc - (pipeline.dcOffset ?? adc.toDouble());
      _waveWrite = (_waveWrite + 1) % kWavePreviewLen;
    }

    // 시간축의 원점을 옮긴다.
    //
    // 파이프라인은 준비 구간에도 돌아야 한다 — 강도 마법사가 events/burst 를
    // 재려면 버스트가 잡혀야 하기 때문이다. 대신 측정 시작에서 파이프라인을
    // **새로 만들고** 원점을 여기로 옮긴다([startMeasurement]).
    //
    // 원점을 안 옮기면 첫 버스트가 t=40초 같은 값으로 들어온다. 그러면
    // 워밍업 30초가 이미 지난 것으로 읽혀 A_ref 없이 곧바로 playing 이 되고,
    // 경과 시간·피로 시점도 전부 그만큼 밀린다.
    _sampleOrigin ??= idx;
    final r = pipeline.addSample(idx - _sampleOrigin!, adc);
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
      // 버스트가 왔다 — 막힌 게 아니다. 시한을 되감는다.
      _armSyncStall();
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

    // 자극이 꺼진 **뒤에** 스트림을 닫는다. 순서가 뒤집히면 자극을 끄는 명령이
    // systemRunning=false 뒤로 밀린다.
    await _sendQuietly({'cmd': 'stop'});

    await _sampleSub?.cancel();
    _sampleSub = null;

    // raw 기록을 닫고 파일로 남긴다. 저장 실패는 세션을 무너뜨리지 않는다 —
    // `saveCsvFile` 이 스스로 삼키고 null 을 준다.
    _rawLog.stop();
    await _rawLogSub?.cancel();
    _rawLogSub = null;
    rawLogPath = await _rawLog.save(subjectId: patientId);
    _cueTimer?.cancel();
    _cueTimer = null;
    _syncStall?.cancel();
    _syncStall = null;

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
    _rawLogSub?.cancel();
    _cueTimer?.cancel();
    _syncStall?.cancel();
    unawaited(_cues.close());
    unawaited(machine.dispose());
    super.dispose();
  }
}
