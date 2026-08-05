import 'dart:collection';

import 'constants.dart';

/// 화면의 손 상태.
enum HandState {
  /// 자극 ON + 수축 확인 → 쥠.
  closed,

  /// 자극 OFF → 폄.
  open,

  /// 자극은 나갔는데 수축이 확인되지 않음.
  /// 전극 접촉 불량 또는 강도 부족. **실패 연출을 하지 않는다** — 담담하게.
  failedContraction,
}

/// 피로 해석에 붙는 안내.
enum FatigueAdvice {
  normal,

  /// 워밍업(동기화) 구간 — 아직 판정하지 않는다.
  warmup,

  /// 급등 감지. 피로가 아니라 전극·자세 문제일 가능성이 높다.
  checkSensor,
}

/// 버스트 1회분의 피로·수축 판정 결과.
class FatigueSample {
  /// 적응형 기준 피로도(%). 0~100.
  final double fatiguePct;

  /// 이번 버스트에서 수축이 확인됐는가.
  final bool contractionOk;

  /// 워밍업(동기화) 구간인가.
  final bool inWarmup;

  /// 판정이 유효한가. A_ref 가 아직 없으면 false.
  final bool valid;

  /// 급등이 의심되는가.
  final bool spikeSuspected;

  final FatigueAdvice advice;

  /// 평활된 진폭 (진단용).
  final double smoothedP2p;

  const FatigueSample({
    required this.fatiguePct,
    required this.contractionOk,
    required this.inWarmup,
    required this.valid,
    required this.spikeSuspected,
    required this.advice,
    required this.smoothedP2p,
  });
}

/// [I] 피로도% + [J] 수축 성공 판정.
///
/// ```
/// fatigue% = clamp(100 × (1 − EMA(p2p) / A_ref_현재구간), 0, 100)
/// contraction_ok = p2p_burst >= A_ref_현재구간 × K
/// ```
///
/// 지키는 것:
/// - 진폭만 본다. **MDF·주파수 지표를 쓰지 않는다**(하드 제약 2). 무부하 FES
///   에서 MDF 는 자극 하모닉(32/64/96Hz)과 혼동되어 무의미하다.
/// - **RMS 상승을 피로로 보지 않는다**(하드 제약 3). FES 유발 반응의 피로는
///   진폭 **감소**다. 방향이 반대다.
/// - 고정 baseline SPC 를 쓰지 않는다(하드 제약 4). A_ref 는 [LevelTracker] 의
///   구간별 running-peak 로 바깥에서 주입된다.
/// - 급등은 피로로 처리하지 않고 센서 점검으로 분기한다(하드 제약 5).
///
/// 피로도는 EMA(평활)로, 수축 판정은 **이번 버스트 원값**으로 낸다.
/// 게임 피드백이 stimOnset+15ms 에 나가야 하므로 평활값을 기다릴 수 없다.
class FatigueEngine {
  FatigueEngine({
    this.alpha = kFatigueEmaAlpha,
    this.warmupSeconds = kSyncWindowS * 1.0,
    this.contractionK = kContractionK,
  });

  final double alpha;
  final double warmupSeconds;
  final double contractionK;

  double? _ema;
  final Queue<_Point> _history = Queue<_Point>();

  double get smoothedP2p => _ema ?? 0.0;

  FatigueSample add({
    required double p2p,
    required double aRef,
    required double tSeconds,
  }) {
    final inWarmup = tSeconds < warmupSeconds;
    final hasRef = aRef > 0;

    // 수축 판정은 언제나 이번 버스트 원값으로. 워밍업 중에도 나온다.
    final contractionOk = hasRef && p2p >= aRef * contractionK;

    _ema = _ema == null ? p2p : alpha * p2p + (1 - alpha) * _ema!;

    // post-peak only — 피크 이후만 피로로 카운트한다.
    //
    // A_ref 는 running-peak 이므로 `p2p >= aRef` 는 "이번 버스트가 곧 피크"라는
    // 뜻이다. 아직 새 피크를 만들고 있는 근육은 피로한 게 아니다(전위증강).
    // 이때 EMA 를 피크까지 끌어올리지 않으면, 평활 지연만큼 없는 피로가
    // 잡힌다. 결과적으로 상승엔 빠르게, 하강엔 느리게 반응한다.
    final atPeak = hasRef && p2p >= aRef;
    if (atPeak && p2p > _ema!) _ema = p2p;

    if (!hasRef) {
      return FatigueSample(
        fatiguePct: 0.0,
        contractionOk: contractionOk,
        inWarmup: inWarmup,
        valid: false,
        spikeSuspected: false,
        advice: inWarmup ? FatigueAdvice.warmup : FatigueAdvice.normal,
        smoothedP2p: _ema!,
      );
    }

    var fatigue = 100.0 * (1.0 - _ema! / aRef);
    if (fatigue.isNaN) fatigue = 0.0;
    fatigue = fatigue.clamp(0.0, 100.0);

    if (inWarmup) {
      return FatigueSample(
        fatiguePct: 0.0,
        contractionOk: contractionOk,
        inWarmup: true,
        valid: true,
        spikeSuspected: false,
        advice: FatigueAdvice.warmup,
        smoothedP2p: _ema!,
      );
    }

    final spike = _detectSpike(tSeconds, fatigue);

    return FatigueSample(
      fatiguePct: fatigue,
      contractionOk: contractionOk,
      inWarmup: false,
      valid: true,
      spikeSuspected: spike,
      advice: spike ? FatigueAdvice.checkSensor : FatigueAdvice.normal,
      smoothedP2p: _ema!,
    );
  }

  /// [kFatigueSpikeWindowS] 안에서 [kFatigueSpikePct] 이상 올랐는가.
  ///
  /// 실측 13/58 세션에서 나타났고 대부분 전극·자세 변화였다. 피로 급증으로
  /// 처리하면 멀쩡한 세션을 끊게 된다.
  bool _detectSpike(double tSeconds, double fatigue) {
    _history.addLast(_Point(tSeconds, fatigue));
    while (_history.isNotEmpty &&
        tSeconds - _history.first.t > kFatigueSpikeWindowS) {
      _history.removeFirst();
    }
    if (_history.length < 2) return false;

    var lowest = double.infinity;
    for (final p in _history) {
      if (p.f < lowest) lowest = p.f;
    }
    return fatigue - lowest >= kFatigueSpikePct;
  }

  void reset() {
    _ema = null;
    _history.clear();
  }
}

/// [J] 손 상태 매핑.
HandState handStateFor({required bool stimOn, required bool contractionOk}) {
  if (!stimOn) return HandState.open;
  return contractionOk ? HandState.closed : HandState.failedContraction;
}

class _Point {
  final double t;
  final double f;
  const _Point(this.t, this.f);
}
