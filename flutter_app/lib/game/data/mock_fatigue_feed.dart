import 'dart:async';

import '../engine/sigma_predictor.dart';
import 'fatigue_feed.dart';

part 'demo_session.g.dart';

/// 데모 재생 기본 시작 시각(초).
///
/// 실측 세션의 σ 궤적: 0~360초는 음수(초기 증강), 381초 1σ, 433초 2σ, 478초 3σ.
/// 355초부터 틀면 2분 안에 정상→주의→경고→위험을 전부 보게 된다.
const double kDemoFatigueStartSec = 355.0;

/// 실측 세션을 그대로 재생하는 목 피드.
///
/// 데이터는 `~/emgfes-data` 의 `1784615199160/0721_154222` 세션을
/// `fes_fatigue_spc.py` 로 분석한 결과다(수축 379회, 612초, 3σ 도달 478초).
/// 손으로 만든 곡선이 아니라 **실제로 피로가 진행된 기록**이라, 게임이 실제
/// 임상 흐름에서 어떻게 보이는지 그대로 확인할 수 있다.
///
/// 하드웨어 없이 개발·시연할 때 쓴다. 실측 연동은 `LiveFatigueFeed`.
class MockFatigueFeed implements FatigueFeed {
  MockFatigueFeed({
    this.speed = 1.0,
    this.startAtSec = kDemoFatigueStartSec,
    SigmaPredictor? predictor,
  }) : _predictor = predictor ?? SigmaPredictor();

  /// 재생 배속.
  ///
  /// 기본은 **1.0(등속)** 이다. 배속을 걸면 자극 리듬까지 같이 빨라져 1.6초마다
  /// 오던 수축이 0.4초 간격이 되고, 포구 연출이 겹쳐 화면이 무너진다.
  /// 시연에서 앞부분을 건너뛰고 싶으면 배속이 아니라 [startAtSec] 을 쓴다.
  final double speed;

  /// 이 시각부터 재생(초).
  ///
  /// 이 세션은 **처음 6분간 σ 가 음수**다(초기 증강 구간 −0.5~−2.6). 0초부터
  /// 틀면 게이지 바늘이 왼쪽 끝에 붙은 채 6분을 보내게 되므로, 기본값을 피로가
  /// 오르기 시작하는 지점으로 둔다.
  final double startAtSec;

  final SigmaPredictor _predictor;

  final _contractions = StreamController<ContractionEvent>.broadcast();
  final _sigmaNow = StreamController<double>.broadcast();
  final _sigmaPredicted = StreamController<double>.broadcast();

  Timer? _timer;
  int _i = 0;
  double _elapsed = 0;
  bool _running = false;

  /// 세션 이름 — 화면에 "재생 중"으로 표시한다.
  String get sessionName => _kDemoSession;

  /// 세션 전체 길이(초).
  double get durationSec => _kDemoContractionSec.last;

  /// 오프라인 분석이 준 존 도달 시각 — 결과 화면 대조용.
  double? get referenceT1 => _kDemoT1;
  double? get referenceT2 => _kDemoT2;
  double? get referenceT3 => _kDemoT3;

  /// 재생 위치(초) — 게임의 유일한 시계다.
  @override
  double get nowSec => _elapsed;

  @override
  Stream<ContractionEvent> get contractions => _contractions.stream;

  @override
  Stream<double> get sigmaNow => _sigmaNow.stream;

  @override
  Stream<double> get sigmaPredicted => _sigmaPredicted.stream;

  @override
  double get predictionHorizonSec => _predictor.horizonSec;

  @override
  double? get nextContractionEta =>
      _i < _kDemoContractionSec.length ? _kDemoContractionSec[_i] : null;

  @override
  Future<void> start() async {
    if (_running) return;
    _running = true;
    _elapsed = startAtSec;
    _i = _kDemoContractionSec.indexWhere((t) => t >= startAtSec);
    if (_i < 0) _i = _kDemoContractionSec.length;

    const tick = Duration(milliseconds: 33);
    _timer = Timer.periodic(tick, (_) {
      _elapsed += tick.inMilliseconds / 1000.0 * speed;
      while (_i < _kDemoContractionSec.length &&
          _kDemoContractionSec[_i] <= _elapsed) {
        final t = _kDemoContractionSec[_i];
        final z = _kDemoSigma[_i];
        _i++;
        _contractions.add(ContractionEvent(t, holdSec: _kDemoHoldSec[_i - 1]));
        _sigmaNow.add(z);
        _sigmaPredicted.add(_predictor.push(t, z));
      }
      if (_i >= _kDemoContractionSec.length) stop();
    });
  }

  @override
  Future<void> stop() async {
    _running = false;
    _timer?.cancel();
    _timer = null;
  }

  @override
  void dispose() {
    stop();
    _contractions.close();
    _sigmaNow.close();
    _sigmaPredicted.close();
  }
}
