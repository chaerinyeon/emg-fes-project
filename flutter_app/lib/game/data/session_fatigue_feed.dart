import 'dart:async';

import '../../signal/constants.dart';
import '../core_loop.dart';
import 'fatigue_feed.dart';

/// 살아 있는 세션을 게임에 물리는 어댑터.
///
/// 게임이 알아야 할 것은 딱 두 가지다 — **언제 수축이 일어났는가**, 그리고
/// **다음 수축이 언제 올 것인가**(공을 미리 던지려면 필요하다). 그 이상은
/// 넘기지 않는다.
///
/// [sigmaNow] · [sigmaPredicted] 는 **아무것도 내지 않는다** — 존 색 연출까지
/// 피로에 묶이면 그것도 결국 피로 표시다. 피로는 잡히는 공이 줄어드는 것으로
/// 드러나야 한다. 임상 지표는 치료사 웹에만 있다.
class SessionFatigueFeed implements FatigueFeed {
  SessionFatigueFeed({
    required Stream<CueEvent> cues,
    required CoreLoop loop,
    required int Function() clockMs,
  })  : _cues = cues,
        _loop = loop,
        _clockMs = clockMs,
        _epochMs = clockMs();

  final Stream<CueEvent> _cues;
  final CoreLoop _loop;
  final int Function() _clockMs;

  /// 게임 시계의 0점. 게임은 세션 벽시계가 아니라 이 기준으로 계산한다.
  final int _epochMs;

  final _contractions = StreamController<ContractionEvent>.broadcast();
  final _sigmaNow = StreamController<double>.broadcast();
  final _sigmaPredicted = StreamController<double>.broadcast();

  StreamSubscription<CueEvent>? _sub;

  @override
  Stream<ContractionEvent> get contractions => _contractions.stream;

  @override
  Stream<double> get sigmaNow => _sigmaNow.stream;

  @override
  Stream<double> get sigmaPredicted => _sigmaPredicted.stream;

  @override
  double get predictionHorizonSec => 0;

  @override
  double get nowSec => (_clockMs() - _epochMs) / 1000.0;

  @override
  double? get nextContractionEta {
    final next = _loop.nextOnsetAtOrAfter(_clockMs());
    return next == null ? null : (next - _epochMs) / 1000.0;
  }

  @override
  Future<void> start() async {
    _sub ??= _cues.listen(_onCue);
  }

  @override
  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
  }

  void _onCue(CueEvent e) {
    // 판정이 확인된 것만 포구가 된다. 확인되지 않았다고 벌을 주지는 않는다 —
    // 공이 그냥 지나갈 뿐이다.
    if (e.type != CueEventType.judge || e.contractionOk != true) return;
    if (_contractions.isClosed) return;

    _contractions.add(ContractionEvent(
      (e.atMs - _epochMs) / 1000.0,
      // 자극이 나가는 내내 쥐고 있어야 "잡았다"로 읽힌다. 순간적으로
      // 닫았다 펴면 "스쳤다"가 되고 되먹임의 내용이 달라진다.
      holdSec: kStimOnMs / 1000.0,
    ));
  }

  /// 게임이 사라져도 세션은 계속 돌아야 한다 — **원본 스트림은 건드리지 않는다.**
  @override
  void dispose() {
    _sub?.cancel();
    _sub = null;
    _contractions.close();
    _sigmaNow.close();
    _sigmaPredicted.close();
  }
}
