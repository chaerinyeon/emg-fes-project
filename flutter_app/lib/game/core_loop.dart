import '../signal/constants.dart';

/// 게임 큐 이벤트 종류.
enum CueEventType {
  /// 화면의 손이 쥐어지기 시작. 자극보다 [kCueLeadMs] 앞선다.
  /// 환자가 "쥔다"고 의도할 시간을 주는 구간이다.
  cue,

  /// FES 발화 시점.
  stimOnset,

  /// M-wave 창이 닫히고 수축 성공 여부가 정해지는 시점.
  judge,

  /// 자극 OFF — 화면의 손이 펴진다.
  release,
}

/// 큐 이벤트 1건.
class CueEvent {
  final CueEventType type;
  final int burstIndex;

  /// **계획된** 시각. 스케줄러가 늦게 깨어나도 이 값은 안 흔들린다.
  final int atMs;

  /// 실제로 이 이벤트를 낸 시각. [atMs] 와의 차이가 스케줄러 지각이다.
  final int emittedAtMs;

  /// [CueEventType.judge] 에만 실린다. 아직 판정이 없으면 null —
  /// **실패로 단정하지 않는다.**
  final bool? contractionOk;

  const CueEvent({
    required this.type,
    required this.burstIndex,
    required this.atMs,
    required this.emittedAtMs,
    this.contractionOk,
  });

  int get latencyMs => emittedAtMs - atMs;

  @override
  String toString() =>
      '${type.name}(burst=$burstIndex at=$atMs late=${latencyMs}ms)';
}

/// 큐가 실제로 자극보다 얼마나 앞섰는지.
///
/// 이 값이 목표에서 벗어나면 훈련 효과가 사라진다. 화면은 멀쩡해 보이므로
/// 숫자로 남기지 않으면 아무도 감지하지 못한다.
class CueTiming {
  final int burstIndex;
  final int cueAtMs;
  final int actualOnsetMs;

  const CueTiming({
    required this.burstIndex,
    required this.cueAtMs,
    required this.actualOnsetMs,
  });

  /// 실제 선행 시간. 목표는 [kCueLeadMs].
  int get realizedLeadMs => actualOnsetMs - cueAtMs;

  bool get isLate => realizedLeadMs <= 0;

  bool get withinTolerance =>
      (realizedLeadMs - kCueLeadMs).abs() <= kPhaseDriftToleranceMs;

  @override
  String toString() => 'burst=$burstIndex lead=${realizedLeadMs}ms'
      '${withinTolerance ? '' : ' OUT_OF_TOLERANCE'}${isLate ? ' LATE' : ''}';
}

/// 위상 드리프트 기록 (게임 큐 기준).
class CueDriftLog {
  final int burstIndex;
  final int predictedOnsetMs;
  final int actualOnsetMs;
  final bool exceeded;

  const CueDriftLog({
    required this.burstIndex,
    required this.predictedOnsetMs,
    required this.actualOnsetMs,
    required this.exceeded,
  });

  double get driftMs => (actualOnsetMs - predictedOnsetMs).toDouble();

  @override
  String toString() => 'burst=$burstIndex drift=${driftMs.toStringAsFixed(0)}ms'
      '${exceeded ? ' EXCEEDED' : ''}';
}

/// 자극 주기에 **위상 잠긴** 게임 코어 루프.
///
/// ```
/// t = stimOnset − 300ms   큐 (화면의 손이 쥐어지기 시작)
/// t = stimOnset           FES 발화
/// t = stimOnset + 15ms    M-wave 창이 닫힘 → 수축 판정
/// t = stimOnset + 591ms   자극 OFF → 손 펴짐
/// ```
///
/// **렌더 루프에 의존하지 않는다.** [advanceTo] 에 벽시계 시각을 주면
/// 그때까지 발생했어야 할 이벤트를 순서대로 낸다. 프레임이 드랍돼도
/// 이벤트가 사라지지 않고, `atMs` 는 계획된 시각 그대로 유지된다.
/// 프레임에 큐를 묶으면 렌더 부하가 곧 타이밍 오차가 된다.
///
/// 템포는 바꿀 수 없다 — 자극 주기에 묶여 있다. 재미는 시각 변주·목표
/// 변주·서사·즉각 피드백으로 만든다.
class CoreLoop {
  CoreLoop({
    this.cueLeadMs = kCueLeadMs,
    this.stimOnMs = kStimOnMs,
    this.judgeOffsetMs = kMwaveWindowEndMs,
    this.driftToleranceMs = kPhaseDriftToleranceMs,
  });

  final int cueLeadMs;
  final int stimOnMs;
  final int judgeOffsetMs;
  final int driftToleranceMs;

  double? _reportedPeriodMs;
  int? _planOnsetMs;
  int _planBurstIndex = 0;
  bool _started = false;

  /// 관측된 자극 시점들. 여기서 주기를 **직접 배운다**.
  ///
  /// 신호 엔진이 준 주기 추정은 중앙값이라 실제 변화보다 늦게 따라온다.
  /// 그 값을 그대로 믿으면 재동기를 해도 매 버스트 같은 크기의 오차가
  /// 남는다(추정 1618 / 실제 1768 이면 선행이 300 대신 450으로 고정).
  /// 위상은 화면에서 안 보이므로 이 오차는 조용히 훈련 효과만 갉아먹는다.
  final List<int> _observedOnsets = <int>[];

  /// 주기 학습에 쓰는 최근 관측 수.
  static const int _periodWindow = 5;

  final Set<CueEventType> _emitted = <CueEventType>{};
  final Map<int, int> _cueEmittedAt = <int, int>{};
  final Map<int, bool> _results = <int, bool>{};

  final List<CueTiming> _timing = <CueTiming>[];
  final List<CueDriftLog> _drift = <CueDriftLog>[];
  int _lateCueCount = 0;
  int _driftExceededCount = 0;

  /// 지금 쓰는 주기. 관측이 쌓이면 관측값이 이긴다.
  double? get periodMs {
    if (_observedOnsets.length >= 3) {
      final gaps = <int>[];
      for (var i = 1; i < _observedOnsets.length; i++) {
        gaps.add(_observedOnsets[i] - _observedOnsets[i - 1]);
      }
      gaps.sort();
      final n = gaps.length;
      return n.isOdd
          ? gaps[n ~/ 2].toDouble()
          : (gaps[n ~/ 2 - 1] + gaps[n ~/ 2]) / 2.0;
    }
    return _reportedPeriodMs;
  }

  /// 다음 자극 예측 시각. 주기를 모르면 null.
  int? get predictedNextOnsetMs => periodMs == null ? null : _planOnsetMs;

  /// 다음 큐 예정 시각.
  int? get nextCueAtMs {
    final onset = predictedNextOnsetMs;
    return onset == null ? null : onset - cueLeadMs;
  }

  List<CueTiming> get timingLog => List.unmodifiable(_timing);
  List<CueDriftLog> get driftLog => List.unmodifiable(_drift);

  /// 큐가 자극보다 **늦게** 나간 횟수. 0이 아니면 훈련 효과가 깨진 것이다.
  int get lateCueCount => _lateCueCount;

  int get driftExceededCount => _driftExceededCount;

  /// 허용치를 벗어난 큐 선행 횟수.
  int get outOfToleranceCount =>
      _timing.where((t) => !t.withinTolerance).length;

  /// 실제 관측된 자극 시점으로 위상을 고정·재정렬한다.
  ///
  /// 신호 엔진이 버스트를 확정할 때마다 부른다.
  void syncTo({
    required int burstIndex,
    required int stimOnsetMs,
    required double? periodMs,
  }) {
    if (periodMs != null) _reportedPeriodMs = periodMs;

    _observedOnsets.add(stimOnsetMs);
    while (_observedOnsets.length > _periodWindow + 1) {
      _observedOnsets.removeAt(0);
    }

    // 이 버스트의 큐가 실제로 얼마나 앞섰는지 기록.
    final cueAt = _cueEmittedAt.remove(burstIndex);
    if (cueAt != null) {
      _timing.add(CueTiming(
        burstIndex: burstIndex,
        cueAtMs: cueAt,
        actualOnsetMs: stimOnsetMs,
      ));
    }

    // 예측과 실제의 차이 = 드리프트.
    if (_planOnsetMs != null && burstIndex == _planBurstIndex) {
      final exceeded = (stimOnsetMs - _planOnsetMs!).abs() > driftToleranceMs;
      _drift.add(CueDriftLog(
        burstIndex: burstIndex,
        predictedOnsetMs: _planOnsetMs!,
        actualOnsetMs: stimOnsetMs,
        exceeded: exceeded,
      ));
      if (exceeded) _driftExceededCount++;
    }

    final p = periodMs ?? this.periodMs;
    if (p == null) return;

    if (!_started) {
      // 첫 동기화. 이 버스트의 큐는 이미 지나갔으므로 다음 것부터 잡는다.
      _started = true;
      _planBurstIndex = burstIndex + 1;
      _planOnsetMs = stimOnsetMs + this.periodMs!.round();
      _emitted.clear();
      return;
    }

    if (burstIndex == _planBurstIndex) {
      // 진행 중인 버스트를 실제 시점으로 다시 못박는다(재동기).
      // 계획을 다음으로 넘기지 않는다 — judge·release 가 아직 남아 있다.
      _planOnsetMs = stimOnsetMs;
    } else if (burstIndex > _planBurstIndex) {
      // 계획보다 앞서갔다(버스트를 놓쳤다). 실제 위치로 건너뛴다.
      _planBurstIndex = burstIndex;
      _planOnsetMs = stimOnsetMs;
      _emitted.clear();
    }
    // burstIndex < _planBurstIndex 이면 이미 지나간 버스트 — 되돌리지 않는다.
  }

  /// [nowMs] 까지 발생했어야 할 이벤트를 순서대로 낸다.
  ///
  /// 같은 시각으로 여러 번 불러도 중복되지 않는다.
  List<CueEvent> advanceTo(int nowMs) {
    final out = <CueEvent>[];
    final p = periodMs;
    if (p == null || _planOnsetMs == null) return out;
    final step = p.round();

    // 한 번 호출에 여러 버스트가 지나갔을 수 있다 (프레임 드랍·백그라운드).
    var guard = 0;
    while (guard++ < 1000) {
      final onset = _planOnsetMs!;
      final plan = <(CueEventType, int)>[
        (CueEventType.cue, onset - cueLeadMs),
        (CueEventType.stimOnset, onset),
        (CueEventType.judge, onset + judgeOffsetMs),
        (CueEventType.release, onset + stimOnMs),
      ];

      for (final (type, at) in plan) {
        if (at > nowMs || _emitted.contains(type)) continue;
        _emitted.add(type);
        if (type == CueEventType.cue) {
          _cueEmittedAt[_planBurstIndex] = at;
          // 큐를 **자극 시점 뒤에 내보냈다면** 훈련 효과가 깨진 것이다.
          // 계획 시각이 아니라 실제로 깨어난 시각으로 판정한다.
          if (nowMs >= onset) _lateCueCount++;
        }
        out.add(CueEvent(
          type: type,
          burstIndex: _planBurstIndex,
          atMs: at,
          emittedAtMs: nowMs,
          contractionOk:
              type == CueEventType.judge ? _results[_planBurstIndex] : null,
        ));
      }

      // 이 버스트를 다 냈고 다음 큐 시각도 지났으면 계획을 굴린다.
      // syncTo 가 오면 어차피 실제 시점으로 다시 못박힌다.
      if (_emitted.length == plan.length &&
          onset + step - cueLeadMs <= nowMs) {
        _planBurstIndex++;
        _planOnsetMs = onset + step;
        _emitted.clear();
        continue;
      }
      break;
    }
    return out;
  }

  /// 신호 엔진의 수축 판정을 붙인다. judge 이벤트에 실린다.
  void setContractionResult({required int burstIndex, required bool ok}) {
    _results[burstIndex] = ok;
  }

  void reset() {
    _reportedPeriodMs = null;
    _observedOnsets.clear();
    _started = false;
    _planOnsetMs = null;
    _planBurstIndex = 0;
    _emitted.clear();
    _cueEmittedAt.clear();
    _results.clear();
    _timing.clear();
    _drift.clear();
    _lateCueCount = 0;
    _driftExceededCount = 0;
  }
}
