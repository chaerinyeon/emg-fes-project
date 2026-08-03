import 'dart:async';

import '../../services/session_controller.dart';
import '../engine/burst_aggregator.dart';
import '../engine/contraction_predictor.dart';
import '../engine/sigma_predictor.dart';
import '../engine/sigma_tracker.dart';
import 'fatigue_feed.dart';

/// 실측 신호 피드 — 펌웨어 M-wave → 수축 이벤트 · SPC σ.
///
/// ## 왜 M-wave 도착이 수축 이벤트인가
///
/// `st.isStimulating` 은 "FES 가 켜져 있다"는 **지속 상태**라 세션당 상승 엣지가
/// 사실상 한 번뿐이다. 실제 자극은 그 안에서 ≈1.62초마다 버스트로 나가고, 그
/// 사실이 신호에 드러나는 곳은 M-wave 도착뿐이다. 그래서 버스트 = 수축 1회다.
///
/// ## σ 는 오프라인 방법 그대로
///
/// [SigmaTracker] 는 `~/emgfes-data/fes_fatigue_spc.py` 의 이식본이고, 실측
/// 세션 3개로 파이썬 출력과 1e-6 이내 일치가 검증돼 있다. 여기서 그 정의를
/// 바꾸지 않는다 — 게임 때문에 임상 지표를 흔들면 안 된다.
class LiveFatigueFeed implements FatigueFeed {
  LiveFatigueFeed({
    required this.session,
    SigmaTracker? tracker,
    SigmaPredictor? predictor,
    ContractionPredictor? timing,
  })  : tracker = tracker ?? SigmaTracker(),
        _predictor = predictor ?? SigmaPredictor(),
        _timing = timing ?? ContractionPredictor();

  final SessionController session;
  final SigmaTracker tracker;
  final SigmaPredictor _predictor;

  final BurstAggregator _bursts = BurstAggregator();
  final ContractionPredictor _timing;
  final _contractions = StreamController<ContractionEvent>.broadcast();
  final _sigmaNow = StreamController<double>.broadcast();
  final _sigmaPredicted = StreamController<double>.broadcast();

  final Stopwatch _clock = Stopwatch();
  int _lastMwCount = 0;
  double? _lastContractionSec;

  @override
  Stream<ContractionEvent> get contractions => _contractions.stream;

  @override
  Stream<double> get sigmaNow => _sigmaNow.stream;

  @override
  Stream<double> get sigmaPredicted => _sigmaPredicted.stream;

  @override
  double get predictionHorizonSec => _predictor.horizonSec;

  /// 직전 수축 + 관측 주기. 실측 주기는 min 1.615 / max 1.622초로 잠겨 있어
  /// 이 예측이 충분히 정확하다. 규칙과 근거는 [ContractionPredictor] 참고.
  @override
  double? get nextContractionEta => _timing.predict(
        nowSec: nowSec,
        lastContractionSec: _lastContractionSec,
        periodSec: _bursts.periodSec,
      );

  /// 자극이 지금 살아 있는가 — 화면이 "자극 대기 중"을 띄울지 정한다.
  bool get isStimulationLive => nextContractionEta != null;

  /// 관측된 자극 주기(초) — 공의 비행 시간이 된다.
  double get periodSec => _bursts.periodSec;

  /// 지금까지 관측된 수축 수. 0이면 자극이 아직 안 들어온 것이다.
  int get contractionCount => _bursts.burstCount;

  @override
  double get nowSec => _clock.elapsedMicroseconds / 1e6;

  @override
  Future<void> start() async {
    _clock.start();
    session.addListener(_onSignal);
  }

  @override
  Future<void> stop() async {
    _clock.stop();
    session.removeListener(_onSignal);
  }

  void _onSignal() {
    final st = session.st;
    // 펌웨어는 자극 펄스마다 M-wave 를 올리고 mwCount 를 증가시킨다.
    // TODO(실측): 지금은 BLE 10Hz 로 요약된 mwa/mwn 을 쓴다. 더 정확한 수축
    //   시각이 필요하면 RAW 1kHz 스트림에서 artifact 온셋을 직접 잡는다.
    if (st.mwCount == _lastMwCount) return;
    _lastMwCount = st.mwCount;

    // BLE 가 10Hz 라 한 메시지에 여러 펄스가 묶여 온다. 여기 들어오는 진폭은
    // '버스트의 첫 펄스'가 아니라 '버스트 시작 후 100ms 이내의 어떤 펄스'다.
    // 같은 버스트 안의 M-wave 는 서로 비슷하므로 감수한다.
    final t = nowSec;
    final burst = _bursts.addPulse(t * 1000.0, st.mwAmp);
    if (burst == null) return;

    _lastContractionSec = burst.tSec;
    _contractions.add(ContractionEvent(burst.tSec));

    tracker.addBurst(burst.tSec, burst.amp);
    final z = tracker.currentSigma;
    if (z != null) {
      _sigmaNow.add(z);
      _sigmaPredicted.add(_predictor.push(burst.tSec, z));
    }
  }

  @override
  void dispose() {
    stop();
    _contractions.close();
    _sigmaNow.close();
    _sigmaPredicted.close();
  }
}
