/// 기존 파이프라인을 관찰 프레임으로 옮기는 어댑터.
///
/// ## 계산하지 않는다
///
/// σ·존은 [LiveFatigueFeed] 의 [SigmaTracker] 가 이미 확정한 값을 읽어 옮길
/// 뿐이다. 여기서 다시 계산하면 게임과 웹이 갈라진다.
library;

import 'dart:async';

import '../core/raw_packet.dart';
import '../game/data/fatigue_feed.dart';
import '../game/data/live_fatigue_feed.dart';
import '../game/model/zone.dart';
import '../services/session_controller.dart';
import 'monitor_broadcaster.dart';
import 'monitor_frame.dart';

/// 프레임을 받아가는 쪽. 테스트에서 서버 없이 갈아끼우기 위한 경계다.
abstract class MonitorSink {
  void tick(MonitorTick f);
  void event(MonitorEvent e);
  void link(String state);

  /// RAW 1kHz 파형 100표본 묶음. [firstSampleMs] 는 세션 시작 기준 첫 샘플의
  /// ms 인덱스([RawPacket.firstSampleMs] 그대로).
  void raw(int firstSampleMs, List<int> samples);
}

/// [MonitorBroadcaster] 를 [MonitorSink] 로 감싼다.
///
/// [broadcaster] 가 `final` 이 아닌 것은 의도다. 앱이 백그라운드에 다녀오면 서버를
/// 새로 띄워야 하는데, 그때 [MonitorSource] 까지 다시 만들면 세션 시계와 링버퍼가
/// 초기화된다. 소스는 그대로 두고 방송기만 갈아끼운다.
class BroadcasterSink implements MonitorSink {
  BroadcasterSink(this.broadcaster);

  MonitorBroadcaster broadcaster;

  @override
  void tick(MonitorTick f) => broadcaster.pushTick(f);

  @override
  void event(MonitorEvent e) => broadcaster.pushEvent(e);

  @override
  void link(String state) => broadcaster.pushLink(state);

  @override
  void raw(int firstSampleMs, List<int> samples) =>
      broadcaster.pushRaw(firstSampleMs, samples);
}

/// tick 주기(ms). 설계 문서의 10 Hz.
const int kMonitorTickMs = 100;

/// 링버퍼 용량 — 10 Hz × 60초.
const int kMonitorRingCapacity = 600;

class MonitorSource {
  MonitorSource({
    required this.session,
    required this.feed,
    required this.sink,
  });

  final SessionController session;
  final LiveFatigueFeed feed;
  final MonitorSink sink;

  final FrameRing ring = FrameRing(kMonitorRingCapacity);

  Timer? _timer;
  StreamSubscription<ContractionEvent>? _contractionSub;
  StreamSubscription<double>? _predictedSub;
  StreamSubscription<RawPacket>? _rawSub;
  String? _lastLink;
  FatigueZone? _lastZone;
  bool _lastFatigue = false;

  /// 마지막으로 받은 예측 σ. 예측은 버스트마다 갱신되고 tick 은 10 Hz 라
  /// 최신값을 들고 있다가 실어보낸다.
  double? _lastPredicted;

  void start() {
    _lastLink = null;
    _lastZone = null;
    _lastFatigue = false;
    _lastPredicted = null;
    session.addListener(_onSession);
    _contractionSub = feed.contractions.listen((c) {
      sink.event(MonitorEvent('contraction', c.t));
    });
    _predictedSub = feed.sigmaPredicted.listen((z) => _lastPredicted = z);
    // RAW 는 세션이 파싱까지 끝낸 패킷을 그대로 옮길 뿐이다 — 여기서도
    // 다시 판정하지 않는다. sink.raw 자체가(BroadcasterSink 경유) 구독자가
    // 없으면 내부에서 no-op 이므로, 여기서 또 게이팅하면 이중 게이트가 된다.
    _rawSub = session.rawPackets
        .listen((p) => sink.raw(p.firstSampleMs, p.samples));
    _timer = Timer.periodic(
      const Duration(milliseconds: kMonitorTickMs),
      (_) => emitTick(),
    );
    sink.event(MonitorEvent('session_start', feed.nowSec));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _contractionSub?.cancel();
    _contractionSub = null;
    _predictedSub?.cancel();
    _predictedSub = null;
    _rawSub?.cancel();
    _rawSub = null;
    session.removeListener(_onSession);
    sink.event(MonitorEvent('session_stop', feed.nowSec));
  }

  /// 프레임 1개를 만들어 링버퍼에 넣고 내보낸다.
  ///
  /// 타이머가 부르지만 테스트에서 직접 부를 수 있게 공개해 둔다 — 그래야
  /// 100ms 를 기다리지 않고 검증한다.
  void emitTick() {
    final f = MonitorTick(
      t: feed.nowSec,
      sigma: feed.tracker.currentSigma,
      sigmaPredicted: _lastPredicted,
      env: session.envLast,
      rms: session.rmsLast,
      mdf: session.mdfLast,
      contractions: feed.contractionCount,
    );
    ring.add(f);
    sink.tick(f);

    final zone = f.zone;
    if (zone != null && zone != _lastZone) {
      _lastZone = zone;
      sink.event(MonitorEvent('zone', f.t, zone: zone.index));
    }
  }

  void _onSession() {
    final state = session.connState;
    if (state != _lastLink) {
      _lastLink = state;
      sink.link(state);
    }
    final fatigued = session.st.fatigueDetected;
    if (fatigued && !_lastFatigue) {
      sink.event(MonitorEvent('fatigue', feed.nowSec,
          zone: feed.tracker.currentZone?.index));
    }
    _lastFatigue = fatigued;
  }

  /// 새 클라이언트에게 보낼 hello.
  MonitorHello buildHello(String sessionLabel) => MonitorHello(
        session: sessionLabel,
        startedAtMs: DateTime.now().millisecondsSinceEpoch,
        mu0: feed.tracker.mu0,
        sd0: feed.tracker.sd0,
        t1: feed.tracker.t1,
        t2: feed.tracker.t2,
        t3: feed.tracker.t3,
        ticks: ring.frames,
      );
}
