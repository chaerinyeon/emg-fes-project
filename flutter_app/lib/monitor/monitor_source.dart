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

/// 이보다 오래 세션으로부터 신호가 없으면 "죽었다"고 본다.
///
/// [SessionController] 는 BLE(또는 시뮬레이터) 메시지를 받을 때마다
/// `notifyListeners()` 를 부른다 — 실측 메시지는 ~10Hz 라 100ms 간격이고,
/// 이 값은 그 간격의 15배다. 짧게 잡으면 정상적인 지터에도 오탐하고, 길게
/// 잡으면 전극이 빠진 뒤에도 한참 "정상"으로 그려진다.
const Duration kMonitorSignalStaleTimeout = Duration(milliseconds: 1500);

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

  /// [_onSession] 이 마지막으로 불린 시각 — "세션으로부터 진짜 신호가 마지막
  /// 으로 온 시각"의 대용이다. [SessionController] 는 BLE/시뮬레이터 메시지를
  /// 파싱할 때마다 `notifyListeners()` 를 부르므로, 이 값이 갱신을 멈췄다는
  /// 것은 곧 신호 자체가 멈췄다는 뜻이다(Critical 2).
  DateTime? _lastSignalAt;

  /// 신호가 멈춰 tick 발신을 정지한 상태인가. `link('stalled')` 를 중복
  /// 발신하지 않기 위한 래치.
  bool _stalled = false;

  /// 세션이 실제로 시작된 벽시계 시각(ms). [buildHello] 가 매번
  /// `DateTime.now()` 를 읽으면 "세션 시작"이 아니라 "이 클라이언트가 접속한
  /// 시각"이 되어버린다(Important 6b) — 그래서 [start] 시점에 한 번만 찍어
  /// 둔다.
  int? _sessionStartedAtMs;

  void start() {
    _lastLink = null;
    _lastZone = null;
    _lastFatigue = false;
    _lastPredicted = null;
    _lastSignalAt = DateTime.now();
    _stalled = false;
    _sessionStartedAtMs = DateTime.now().millisecondsSinceEpoch;
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
  ///
  /// ## 신호가 멈추면 tick 도 멈춘다 (Critical 2)
  ///
  /// 이 메서드는 100ms 마다 무조건 불렸었다 — 전극이 빠지거나 ESP32 가
  /// 죽어도 `session.envLast/rmsLast/mdfLast` 는 마지막 값을 들고 있고
  /// `feed.tracker.currentSigma` 도 그대로라, 그 얼어붙은 값을 "지금"인 척
  /// 계속 내보냈다. 웹의 stale 감지 셋(2초 무수신)은 전부 **tick 도착**에
  /// 걸려 있어서, tick 이 (내용은 죽었어도) 계속 오면 그 감지가 전혀
  /// 작동하지 않는다. 그래서 여기서 [_lastSignalAt] 이 오래됐으면 tick 을
  /// 아예 내보내지 않는다 — 그래야 웹의 2초 stale 게이트가 정상적으로
  /// 걸린다.
  void emitTick() {
    final lastSignal = _lastSignalAt;
    final stale = lastSignal != null &&
        DateTime.now().difference(lastSignal) > kMonitorSignalStaleTimeout;

    if (stale) {
      if (!_stalled) {
        _stalled = true;
        sink.link('stalled');
      }
      return; // 얼어붙은 값을 tick 으로 내보내지 않는다 — 링버퍼에도 안 쌓는다.
    }
    if (_stalled) {
      // 신호가 돌아왔다 — link 를 실제 연결 상태로 되돌려 웹의 "센서 끊김"
      // 배너를 해제한다. _onSession() 의 중복 억제(_lastLink)와 어긋나지
      // 않도록 그 필드도 함께 맞춰 둔다.
      _stalled = false;
      _lastLink = session.connState;
      sink.link(session.connState);
    }

    final f = MonitorTick(
      t: feed.nowSec,
      sigma: feed.tracker.currentSigma,
      sigmaPredicted: _lastPredicted,
      env: session.envLast,
      rms: session.rmsLast,
      mdf: session.mdfLast,
      contractions: feed.contractionCount,
      t1: feed.tracker.t1,
      t2: feed.tracker.t2,
      t3: feed.tracker.t3,
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
    _lastSignalAt = DateTime.now();
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

  /// 휴식 이닝 시작. 휴식 판정은 `GameScreen`(정확히는 `RestPolicy`)의
  /// 몫이라 이 클래스는 스스로 판단하지 않는다 — 호출자가 알려주면 그대로
  /// 옮길 뿐이다(Important 4).
  void restStart(double tSec) => sink.event(MonitorEvent('rest_start', tSec));

  /// 휴식 이닝 종료.
  void restEnd(double tSec) => sink.event(MonitorEvent('rest_end', tSec));

  /// 새 클라이언트에게 보낼 hello.
  ///
  /// [MonitorHello.link] 는 지금 이 순간의 BLE 링크 상태다(Finding 2) —
  /// [session.connState] 를 그대로 쓰지 않는 이유는, 신호가 멈춰
  /// [_stalled] 인 동안은 BLE 자체는 "connected" 인 채로 남아 있을 수
  /// 있기 때문이다(전극만 빠진 경우). 그 상태에서 hello 가
  /// `session.connState` 를 그대로 실으면 세션 도중 접속한 치료사에게
  /// "정상"으로 잘못 보인다 — emitTick() 이 sink 에 실제로 방송해 온
  /// 상태(stalled)와 어긋나면 안 된다.
  MonitorHello buildHello(String sessionLabel) => MonitorHello(
        session: sessionLabel,
        startedAtMs:
            _sessionStartedAtMs ?? DateTime.now().millisecondsSinceEpoch,
        mu0: feed.tracker.mu0,
        sd0: feed.tracker.sd0,
        t1: feed.tracker.t1,
        t2: feed.tracker.t2,
        t3: feed.tracker.t3,
        link: _stalled ? 'stalled' : session.connState,
        ticks: ring.frames,
      );
}
