/// RE-FIT Play 세션을 관찰 프레임으로 옮기는 어댑터.
///
/// 레거시 [MonitorSource] 와 같은 일을 하지만 읽는 곳이 다르다. 그쪽은
/// `services/SessionController` + `LiveFatigueFeed` 를, 이쪽은
/// [SessionOrchestrator] + [SignalPipeline] 을 본다. 두 스택이 한동안
/// 공존하므로 어댑터를 나눴다 — 레거시 경로에는 회귀 테스트가 두껍게
/// 걸려 있어 건드리지 않는 편이 싸다.
///
/// ## σ 를 지어내지 않는다
///
/// `monitor.html` 은 SPC σ 로 그려진다. 새 파이프라인의 피로 지표는 σ 가
/// 아니라 적응형 퍼센트라, 그 값을 σ 자리에 넣으면 웹이 다른 뜻의 숫자를
/// 같은 눈금에 그린다. 대신 레거시와 **같은 [SigmaTracker] 에 같은 재료**
/// (M-wave 진폭)를 먹여 진짜 σ 를 만든다. baseline 이 설 때까지는 σ 가
/// null 이고, 그때 웹은 "정상"이라고 단정하지 않는다.
library;

import 'dart:async';

import '../core/raw_packet.dart';
import '../features/session/session_orchestrator.dart';
import '../game/engine/sigma_tracker.dart';
import '../game/model/zone.dart';
import '../signal/signal_pipeline.dart';
import 'monitor_frame.dart';
import 'monitor_source.dart' show MonitorSink;

/// tick 주기(ms). 레거시와 같은 10 Hz.
const int kRefitMonitorTickMs = 100;

/// 링버퍼 용량 — 10 Hz × 60초.
const int kRefitMonitorRingCapacity = 600;

/// 표본이 이보다 오래 끊기면 "죽었다"고 본다.
///
/// 조립부는 250ms 마다 [SessionOrchestrator.lastSampleWallMs] 를 찍는다.
/// 그 6배다 — 짧으면 정상 지터에 오탐하고, 길면 전극이 빠진 뒤에도 한참
/// "정상"으로 그려진다.
const Duration kRefitMonitorStaleTimeout = Duration(milliseconds: 1500);

class RefitMonitorSource {
  RefitMonitorSource({
    required this.orchestrator,
    required this.sink,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final SessionOrchestrator orchestrator;
  final MonitorSink sink;
  final DateTime Function() _now;

  final SigmaTracker tracker = SigmaTracker();
  final FrameRing ring = FrameRing(kRefitMonitorRingCapacity);

  Timer? _timer;
  StreamSubscription<List<int>>? _rawSub;

  int _lastBurstIndex = -1;
  String? _lastLink;
  FatigueZone? _lastZone;
  bool _stalled = false;
  int? _startedAtMs;

  void start() {
    _startedAtMs = _now().millisecondsSinceEpoch;
    _lastLink = null;
    _lastZone = null;
    _stalled = false;

    orchestrator.addListener(_onOrchestrator);

    // RAW 는 링크에서 곧바로 받는다. 조립부는 파싱된 표본만 내보내는데
    // 웹은 패킷 단위(첫 표본 ms + 100표본)를 기대한다.
    _rawSub = orchestrator.link.rawPackets.listen((bytes) {
      final p = RawPacket.parse(bytes);
      if (p != null) sink.raw(p.firstSampleIndex, p.samples);
    });

    _timer = Timer.periodic(
      const Duration(milliseconds: kRefitMonitorTickMs),
      (_) => emitTick(),
    );
    sink.event(MonitorEvent('session_start', orchestrator.elapsedS));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    unawaited(_rawSub?.cancel());
    _rawSub = null;
    orchestrator.removeListener(_onOrchestrator);
    sink.event(MonitorEvent('session_stop', orchestrator.elapsedS));
  }

  /// 조립부가 바뀔 때마다 — 새 버스트를 σ 추적기에 넣고 링크 상태를 옮긴다.
  void _onOrchestrator() {
    final b = orchestrator.lastBurst;
    if (b != null && b.index != _lastBurstIndex) {
      _lastBurstIndex = b.index;
      // 레거시와 **같은 재료**다. 여기서 다시 판정하지 않는다.
      tracker.addBurst(b.tSeconds, b.p2p);
      sink.event(MonitorEvent('contraction', b.tSeconds));
    }

    final link = orchestrator.link.state.name;
    if (link != _lastLink && !_stalled) {
      _lastLink = link;
      sink.link(link);
    }
  }

  /// 프레임 1개. 타이머가 부르지만 테스트가 직접 부를 수 있게 공개해 둔다.
  ///
  /// **표본이 멈추면 tick 도 멈춘다.** 얼어붙은 값을 "지금"인 척 계속 보내면
  /// 웹의 무수신 감지가 아예 작동하지 않는다 — 화면은 정상인데 환자는
  /// 자극을 못 받고 있는 상태가 눈에 안 띈다.
  void emitTick() {
    final lastSample = orchestrator.lastSampleWallMs;
    final stale = lastSample != null &&
        _now().millisecondsSinceEpoch - lastSample >
            kRefitMonitorStaleTimeout.inMilliseconds;

    if (stale) {
      if (!_stalled) {
        _stalled = true;
        sink.link('stalled');
      }
      return;
    }
    if (_stalled) {
      _stalled = false;
      _lastLink = orchestrator.link.state.name;
      sink.link(_lastLink!);
    }

    final b = orchestrator.lastBurst;
    final f = MonitorTick(
      t: orchestrator.elapsedS,
      sigma: tracker.currentSigma,
      // 예측 σ 는 새 스택에 없다. 없는 것을 0 으로 채우지 않는다.
      sigmaPredicted: null,
      // env 자리에는 M-wave 진폭을 넣는다 — 피로 판정의 실제 근거이고,
      // 레거시 env(펌웨어 포락선)와 같은 "지금 신호 크기" 자리다.
      env: b?.p2p ?? 0,
      rms: b?.rms ?? 0,
      mdf: b?.mdfHz ?? 0,
      contractions: orchestrator.repCount,
      t1: tracker.t1,
      t2: tracker.t2,
      t3: tracker.t3,
    );
    ring.add(f);
    sink.tick(f);

    final zone = f.zone;
    if (zone != null && zone != _lastZone) {
      _lastZone = zone;
      sink.event(MonitorEvent('zone', f.t, zone: zone.index));
    }
  }

  /// 새 클라이언트에게 보낼 hello. 세션 도중 붙어도 빈 화면을 안 보게 한다.
  MonitorHello buildHello(String sessionLabel) => MonitorHello(
        session: sessionLabel,
        startedAtMs: _startedAtMs ?? _now().millisecondsSinceEpoch,
        mu0: tracker.mu0,
        sd0: tracker.sd0,
        t1: tracker.t1,
        t2: tracker.t2,
        t3: tracker.t3,
        // 신호가 멈춰 있는 동안 BLE 는 connected 로 남아 있을 수 있다.
        // 도중에 접속한 치료사에게 "정상"으로 잘못 보이면 안 된다.
        link: _stalled ? 'stalled' : orchestrator.link.state.name,
        ticks: ring.frames,
      );
}
