// RE:FIT 실시간 인과 판정 코어 — Hybrid C (판정층 사양서).
//
// 책임: 에폭 스트림 → 버스트 지표 → 신선 기준 SPC → 명령 결정.
// BLE 는 모른다. 명령은 [onCommand] 로 넘기고 전송은 서비스가 한다
// (그래야 CSV 재생·단위테스트에서 이 코어를 그대로 돌릴 수 있다).
//
// === 왜 구버전을 버렸나 ===
// 구버전은 기준을 running-max(=wander 정점)에 두고 σ_eff=max(σ, cv_floor×ref) 로
// 판정했다. 2026-08-24 202251 실측(11.8분)에서 면적이 899~3406 으로 크게 wandering
// 하는데 기준이 단일 정점 3406 에 박혀, 버스트 중앙값(1914)이 상시 정점의 56% 로
// 읽혔다 → 판정 버스트의 73% 가 위험. 근본 원인은 확정 타이밍이 아니라 **기준의 위치**다.
//
// === Hybrid C 의 두 축 ===
//   1. 기준을 '정점'이 아니라 '신선 고정'으로: 전위 종료 후 90초(Phase I)에서
//      CL0·σ0 을 확립하고 **동결**한다. 같은 세션에서 CL0=2197, σ0=264(12%).
//   2. 2트랙 분리: 일상 DOWN 은 느린추세(60초 인과 median)에 2σ0 — wandering 에 강건.
//      응급 STOP 은 원버스트 3σ0 + 절대하한 40%×CL0 — 급성 붕괴에 빠름.
//
// 비협상 규칙:
//   · UP 없음 — 자동 경로는 HOLD/DECREASE/STOP 뿐. 이 파일에 INCREASE 는 없다.
//   · 인과성 — 과거·현재 표본만. 미래 버스트를 보는 특징은 전부 금지.
//   · STOP 은 정착·워밍업 어떤 유예에도 걸리지 않는다.
//   · 과추정이 안전 — 완전마비는 과자극 피드백이 없다.
import 'dart:math' as math;

import '../core/refit_protocol.dart';

/// JUDGMENT 의 stage 바이트로 나가는 단계. Hybrid C 는 타이머로 확정하지만
/// 프로토콜 계약은 0~3 단계를 요구하므로 트랙 상태를 여기에 매핑한다.
enum RefitStage { normal, caution, warning, danger }

enum RefitAction { hold, decrease, stop }

/// 판정층 사양서 10장 파라미터. 값의 출처를 함께 적는다 — 임의로 고르면 안 된다.
class RefitParams {
  /// 버스트 주기(초). 펌웨어 실측 1621.9ms(σ=0.58ms)에 격자를 맞춘 값.
  final double cycleS;

  /// 버스트가 성립하는 최소 유효 펄스 수.
  final int minPulsesPerBurst;

  /// 전위(활성후증강) 종료 검출: running-max 가 [potMinBursts] 이후
  /// [potPlateauBursts] 연속으로 갱신 안 되면 정점을 지난 것으로 본다.
  final int potMinBursts, potPlateauBursts;

  /// Phase I(신선 기준 확립) 구간 길이(초).
  final double phaseIWindowS;

  /// Phase I 에서 σ0 을 신뢰하려면 필요한 최소 버스트 수.
  ///
  /// 사양서에 값이 없어 추가했다. 90초면 보통 ~55버스트지만(202251 세션 56개),
  /// 포화·유실이 심하면 훨씬 적어진다 — 193547 세션은 포화 47% 라 절반이 버려졌다.
  /// 표본 서넛으로 std(ddof=1) 을 동결하면 그 세션 내내 엉뚱한 관리한계를 쓴다.
  /// 모자라면 Phase I 을 **연장**한다(판정을 여는 대신 기다린다 = 안전 방향).
  final int phaseIMinBursts;

  /// 느린추세 창(초). DOWN 트랙 입력 S(t) = 최근 이 구간의 버스트 median 의 인과 median.
  final double slowWindowS;

  /// DOWN 관리하한 계수(느린추세 SPC). LCL = CL_down − downK·σ0.
  final double downK;

  /// DOWN 경고 타이머 회복 리셋선. S 가 CL_down − recoverK·σ0 위로 오면 타이머 리셋.
  final double recoverK;

  /// STOP 상대 관리하한 계수(원버스트 SPC). CL_stop − stopK·σ0.
  final double stopK;

  /// STOP 절대 하한(신선 CL0 대비 비율). 재기준이 붕괴를 따라 내려가며 STOP 을
  /// 회피하지 못하게 막는 안전 바닥.
  final double absFloorPct;

  /// DOWN·STOP 확정에 필요한 연속 시간(초).
  final double tDownS, tDangerS;

  /// DOWN 후 DOWN 재발만 유예하는 버스트 수. **STOP 은 유예하지 않는다.**
  final int settleBursts;

  /// 버스트 간격이 이보다 크면 타이머를 얼린다(결손이 '지속'으로 위장하는 것 방지).
  final double gapFreezeS;

  /// 과거창 Hampel(스파이크 배제). 창은 과거로만 — 양방향은 미래 버스트가 필요하다.
  final int hampelWindow;
  final double hampelNSigma;
  final double burstSpikeFactor;

  /// **연속** 배제 상한. 이보다 많이 연달아 걸리면 튐이 아니라 진짜 레벨변화로 본다.
  ///
  /// 왜 필요한가(치명): 배제된 버스트는 참조창(_accepted)에 안 들어간다. 그래서
  /// 급성 붕괴처럼 값이 통째로 내려앉으면 창은 옛 높이에 머물고 **모든** 후속
  /// 버스트가 계속 '고립 튐'으로 배제된다 → 두 트랙 상류가 막혀 STOP 이 구조적으로
  /// 발동할 수 없다. 실측 재현: CL0 의 30% 로 떨어뜨린 버스트 20개가 전량 배제됐다.
  /// 고립 튐은 하나로 끝나고 진짜 붕괴는 이어진다 — 그 차이로 가른다.
  final int maxHampelRejects;

  /// 신뢰도 티어 문턱(유효 에폭 %).
  final double reliabHighPct, reliabMidPct;

  /// 포화율이 이 %를 넘으면 한 등급 강등(포화 에폭은 면적이 잘려 과소평가).
  final double reliabSatPct;

  const RefitParams({
    this.cycleS = 1.622,
    this.minPulsesPerBurst = 3,
    this.potMinBursts = 3,
    this.potPlateauBursts = 3,
    this.phaseIWindowS = 90.0,
    this.phaseIMinBursts = 20,
    this.slowWindowS = 60.0,
    this.downK = 2.0,
    this.recoverK = 1.0,
    this.stopK = 3.0,
    this.absFloorPct = 0.40,
    this.tDownS = 10.0,
    this.tDangerS = 16.0,
    this.settleBursts = 5,
    this.gapFreezeS = 3.5,
    this.hampelWindow = 21,
    this.hampelNSigma = 4.0,
    this.burstSpikeFactor = 2.5,
    this.maxHampelRejects = 1,
    this.reliabHighPct = 95.0,
    this.reliabMidPct = 80.0,
    this.reliabSatPct = 20.0,
  });
}

/// 버스트 하나의 판정 스냅샷. CSV (c)(d)(f) 와 UI 가 이걸 읽는다.
class RefitBurst {
  final double tS; // 세션 t0 기준 초
  final double med; // 원버스트 median (ADC·ms) — STOP 트랙 입력
  final double slowS; // 느린추세 — DOWN 트랙 입력
  final int phase; // 0 전위 · 1 기준확립 · 2 감시
  final double cl0, sigma0, clDown, clStop;

  /// (CL_down − S)/σ0. 클수록 느린추세가 관리하한 아래로 내려간 것.
  final double downMarginSigma;

  /// (CL_stop − med)/σ0. 원버스트 기준 붕괴 여유.
  final double stopMarginSigma;

  final bool warnActive, dangerActive;
  final RefitStage stage;
  final int reliability;
  final int pulses;

  const RefitBurst({
    required this.tS,
    required this.med,
    required this.slowS,
    required this.phase,
    required this.cl0,
    required this.sigma0,
    required this.clDown,
    required this.clStop,
    required this.downMarginSigma,
    required this.stopMarginSigma,
    required this.warnActive,
    required this.dangerActive,
    required this.stage,
    required this.reliability,
    required this.pulses,
  });
}

/// 코어가 내리는 명령. 바이트 조립·전송은 서비스가 한다.
class RefitCommand {
  final RefitAction action;
  final int targetLevel;
  final int stage;
  final int reliability;
  final int tRefMs;
  final int stimIndexRef;
  const RefitCommand({
    required this.action,
    required this.targetLevel,
    required this.stage,
    required this.reliability,
    required this.tRefMs,
    required this.stimIndexRef,
  });
}

class RefitSession {
  RefitSession({
    this.params = const RefitParams(),
    this.onCommand,
    this.onBurstClosed,
    this.onHeartbeatDue,
  });

  final RefitParams params;
  final void Function(RefitCommand cmd)? onCommand;
  final void Function(RefitBurst b)? onBurstClosed;
  final void Function()? onHeartbeatDue;

  // ---------- 기준(동결) ----------
  double cl0 = 0, sigma0 = 0;
  int phase = 0; // 0 전위 · 1 기준확립 · 2 감시
  bool _potOver = false;
  double _potEndTs = 0;
  final List<double> _baselineBuf = [];

  // ---------- 느린추세 ----------
  final List<(double t, double med)> _history = [];

  // ---------- 두 트랙 운용 기준(재기준 대상) ----------
  double clDown = 0, clStop = 0;

  // ---------- DOWN 트랙 ----------
  double? _warnT0;
  int _settleUntilBurst = 0;

  // ---------- STOP 트랙 (정착 무관) ----------
  double? _dangerT0;

  // ---------- 공통 ----------
  int? sessionId;
  int? t0Ms;
  int fs = 1000;
  int _burstCount = 0;
  double _lastBt = double.negativeInfinity;
  double _runningMax = 0;
  int _sinceRunMaxRise = 0;
  final List<double> _accepted = []; // Hampel 참조용 과거 버스트
  int _consecutiveRejects = 0;
  final List<(int, double)> _burstBuffer = [];
  int? _lastBurstCid;

  int currentLevel = 0;
  bool stimOn = false;
  int mcuState = 0;
  int maxLevel = 0;

  int _reliability = kRelHigh;
  int get reliability => _reliability;

  bool _calibDone = false;
  int _epochsSeen = 0, _epochsUsable = 0, _epochsSaturated = 0;
  int _lastEpochTMs = 0, _lastEpochStimIdx = 0;
  int _lastHbMs = 0;

  // 최근 스냅샷 — CSV 가 매 에폭 행에 붙인다.
  RefitBurst? lastBurst;
  RefitAction lastAction = RefitAction.hold;
  int lastTargetLevel = 0;
  int lastCmdSeq = 0;

  bool get analyzing => _calibDone;

  /// 명령을 실제로 하달할 수 있는 상태인가.
  /// 사양서 9장: stimOn==1 && mcuState==RUNNING(2). 로그 전용 무자극 모드에서는
  /// 계산·기록만 하고 전송하지 않는다.
  bool get commanding =>
      _calibDone && stimOn && currentLevel > 0 && mcuState == kStateRunning;

  bool get settling => _burstCount < _settleUntilBurst;

  // ---------- 리셋 ----------
  void reset({int? newSessionId}) {
    sessionId = newSessionId;
    t0Ms = null;
    cl0 = sigma0 = 0;
    phase = 0;
    _potOver = false;
    _potEndTs = 0;
    _baselineBuf.clear();
    _history.clear();
    clDown = clStop = 0;
    _warnT0 = null;
    _dangerT0 = null;
    _settleUntilBurst = 0;
    _burstCount = 0;
    _lastBt = double.negativeInfinity;
    _runningMax = 0;
    _sinceRunMaxRise = 0;
    _accepted.clear();
    _consecutiveRejects = 0;
    _burstBuffer.clear();
    _lastBurstCid = null;
    _calibDone = false;
    _epochsSeen = _epochsUsable = _epochsSaturated = 0;
    _reliability = kRelHigh;
    lastBurst = null;
    lastAction = RefitAction.hold;
    lastTargetLevel = 0;
  }

  // ---------- 업링크 입력 ----------

  void onStatus(StatusMsg s) {
    currentLevel = s.level;
    stimOn = s.stimOn;
    mcuState = s.state;
    maxLevel = s.maxLevel;
    if (s.sampleRate > 0) fs = s.sampleRate;
    if (sessionId != null && s.sessionId != sessionId) {
      reset(newSessionId: s.sessionId);
    }
  }

  void onEvent(EventMsg e) {
    switch (e.eventId) {
      case kEvSessionStart:
        reset(newSessionId: e.sessionId);
        t0Ms = e.tMs;
      case kEvCalibDone:
        _calibDone = true;
      case kEvRestEnd:
        // [펌웨어 v0.3.2] 자극 공백이 끝났다. 자극이 끊겼다 돌아오면 M-wave 도 함께
        // 튀므로 새 운용 레벨로 보고 DOWN 트랙만 재기준한다(레벨변화와 같은 처리).
        // STOP 트랙의 절대하한(0.40×CL0)은 그대로라 붕괴는 계속 감시된다.
        if (phase == 2) _rebaseline(lastBurst?.slowS ?? clDown);
      case kEvSessionStop:
      case kEvFault:
        _warnT0 = null;
        _dangerT0 = null;
        _burstBuffer.clear();
    }
  }

  void onEpoch(EpochMsg ep) {
    if (sessionId != null && ep.sessionId != sessionId) {
      reset(newSessionId: ep.sessionId);
    }
    sessionId ??= ep.sessionId;
    t0Ms ??= ep.tMs;
    _lastEpochTMs = ep.tMs;
    _lastEpochStimIdx = ep.stimIndex;

    _epochsSeen++;
    if (ep.saturated) _epochsSaturated++;

    // flags 게이팅 — 무효·포화 에폭은 추세에 넣지 않는다.
    if (!ep.usableForTrend) return;
    _epochsUsable++;
    if (!analyzing) return;

    final tRel = ep.tMs - (t0Ms ?? ep.tMs);
    final cid = (tRel / 1000.0 / params.cycleS).floor();
    if (_lastBurstCid != null && cid != _lastBurstCid) closeBurst();
    _lastBurstCid = cid;
    _burstBuffer.add((tRel, ep.areaMs(fs)));
  }

  // ---------- 버스트 집계 ----------

  void closeBurst() {
    final buf = List<(int, double)>.from(_burstBuffer);
    _burstBuffer.clear();
    if (buf.length < params.minPulsesPerBurst) return;
    final med = _median(buf.map((e) => e.$2).toList());
    final bt =
        buf.map((e) => e.$1).reduce((a, b) => a + b) / buf.length / 1000.0;
    // 고립 튐만 배제한다. 연속으로 걸리면 튐이 아니라 레벨변화 — 그대로 통과시켜야
    // STOP 트랙이 붕괴를 볼 수 있다(위 maxHampelRejects 주석).
    if (_isHampelOutlier(med) && _consecutiveRejects < params.maxHampelRejects) {
      _consecutiveRejects++;
      return;
    }
    _consecutiveRejects = 0;
    _onBurst(bt, med, buf.length);
  }

  // ---------- 판정 (사양서 7·9장) ----------

  void _onBurst(double bt, double med, int pulses) {
    _burstCount++;
    _accepted.add(med);
    _updateReliability();

    // 느린추세: 최근 slowWindowS 구간의 인과 median.
    _history.add((bt, med));
    final cutoff = bt - params.slowWindowS;
    _history.removeWhere((e) => e.$1 < cutoff);
    final slowS = _median(_history.map((e) => e.$2).toList());

    // 전위 plateau 검출
    if (med > _runningMax) {
      _runningMax = med;
      _sinceRunMaxRise = 0;
    } else {
      _sinceRunMaxRise++;
    }

    if (!_potOver) {
      if (_burstCount >= params.potMinBursts &&
          _sinceRunMaxRise >= params.potPlateauBursts) {
        _potOver = true;
        _potEndTs = bt;
        phase = 1;
      }
      _emit(bt, med, slowS, pulses);
      _lastBt = bt;
      return;
    }

    if (phase == 1) {
      // Phase I — 기준 확립. DOWN 은 비활성, STOP 만 임시 기준으로 무장한다.
      _baselineBuf.add(med);
      final tempCl = _mean(_baselineBuf);
      final tempSigma = math.max(_std(_baselineBuf), 0.10 * tempCl);
      _runStop(bt, med, tempCl, tempSigma, tempCl);

      // 90초가 지나도 표본이 모자라면 연장한다(엉뚱한 σ0 를 동결하느니 기다린다).
      if (bt - _potEndTs >= params.phaseIWindowS &&
          _baselineBuf.length >= params.phaseIMinBursts) {
        cl0 = _mean(_baselineBuf);
        sigma0 = _std(_baselineBuf);
        clDown = clStop = cl0;
        phase = 2;
      }
      _emit(bt, med, slowS, pulses);
      _lastBt = bt;
      return;
    }

    // --- Phase II ---
    _runStop(bt, med, clStop, sigma0, cl0); // ★ 항상 먼저. 정착·워밍업 무관.
    if (!settling) _runDown(bt, slowS);
    _emit(bt, med, slowS, pulses);
    _lastBt = bt;
  }

  /// STOP 트랙 — 원버스트 3σ0 OR 절대하한 40%×CL0. 어떤 유예에도 걸리지 않는다.
  void _runStop(double bt, double med, double cl, double sigma, double floorRef) {
    if (bt - _lastBt > params.gapFreezeS) {
      _dangerT0 = null; // 결손 프리즈 — 빈 구간을 '지속'으로 읽지 않는다
      return;
    }
    final danger = med <= cl - params.stopK * sigma ||
        med <= params.absFloorPct * floorRef;
    if (!danger) {
      _dangerT0 = null;
      return;
    }
    _dangerT0 ??= bt;
    if (bt - _dangerT0! >= params.tDangerS) {
      lastAction = RefitAction.stop;
      lastTargetLevel = 0;
      if (!_send(RefitAction.stop, 0, RefitStage.danger)) _dangerT0 = null;
    }
  }

  /// DOWN 트랙 — 느린추세 2σ0. 회복 시 타이머 리셋, 결손 시 프리즈.
  void _runDown(double bt, double slowS) {
    if (bt - _lastBt > params.gapFreezeS) {
      _warnT0 = null;
      return;
    }
    if (slowS <= clDown - params.downK * sigma0) {
      _warnT0 ??= bt;
    } else if (slowS > clDown - params.recoverK * sigma0) {
      _warnT0 = null; // 회복 → 리셋
    }
    if (_warnT0 == null || bt - _warnT0! < params.tDownS) return;
    if (currentLevel <= 0) {
      lastAction = RefitAction.hold;
      return;
    }
    final target = math.max(0, currentLevel - 1);
    lastAction = RefitAction.decrease;
    lastTargetLevel = target;
    // 재기준은 **명령이 실제로 나갔을 때만**. 로그 전용이나 전송 실패에서 CL 을
    // 내리면 기준이 신호를 따라 내려가 진짜 피로를 못 본다(2026-08-24 실측 교훈).
    if (_send(RefitAction.decrease, target, RefitStage.warning)) {
      _rebaseline(slowS);
    } else {
      _warnT0 = null; // 같은 확정을 매 버스트 반복하지 않도록만 초기화
    }
  }

  /// DOWN 직후: 두 트랙을 새 운용 레벨(S)로 동시 재기준 + DOWN 재발만 유예.
  /// STOP 타이머는 건드리지 않는다.
  void _rebaseline(double s) {
    clDown = clStop = s;
    _settleUntilBurst = _burstCount + params.settleBursts;
    _warnT0 = null;
  }

  bool _send(RefitAction a, int target, RefitStage stage) {
    if (!commanding) return false;
    lastCmdSeq++;
    onCommand?.call(RefitCommand(
      action: a,
      targetLevel: target,
      stage: stage.index,
      reliability: _reliability,
      tRefMs: _lastEpochTMs,
      stimIndexRef: _lastEpochStimIdx,
    ));
    return true;
  }

  /// ≤2s 마다 HEARTBEAT. 없으면 MCU 워치독(2s)→SAFE_HOLD, 데드맨(8s)→STIM_OFF.
  void tick(int nowMs) {
    if (nowMs - _lastHbMs >= 1000) {
      _lastHbMs = nowMs;
      onHeartbeatDue?.call();
    }
  }

  // ---------- 내부 ----------

  bool _isHampelOutlier(double x) {
    final w = _tail(_accepted, params.hampelWindow);
    if (w.length < 5) return false;
    final med = _median(w);
    final mad = _median(w.map((v) => (v - med).abs()).toList());
    final thr = params.hampelNSigma *
        math.max(1.4826 * mad, 0.10 * math.max(med, 1e-9));
    return (x - med).abs() > thr || x > med * params.burstSpikeFactor;
  }

  void _updateReliability() {
    if (_epochsSeen == 0) return;
    final validPct = 100.0 * _epochsUsable / _epochsSeen;
    final satPct = 100.0 * _epochsSaturated / _epochsSeen;
    var tier = validPct >= params.reliabHighPct
        ? kRelHigh
        : (validPct >= params.reliabMidPct ? kRelMed : kRelLow);
    if (satPct > params.reliabSatPct && tier < kRelLow) tier++;
    _reliability = tier;
  }

  RefitBurst _emit(double bt, double med, double slowS, int pulses) {
    final s0 = sigma0 > 0 ? sigma0 : double.nan;
    final downMargin = phase == 2 ? (clDown - slowS) / s0 : double.nan;
    final stopMargin = phase == 2 ? (clStop - med) / s0 : double.nan;
    final warn = _warnT0 != null;
    final danger = _dangerT0 != null;
    final stage = danger
        ? RefitStage.danger
        : warn
            ? RefitStage.warning
            : (phase == 2 && slowS <= clDown - params.recoverK * sigma0)
                ? RefitStage.caution
                : RefitStage.normal;
    final b = RefitBurst(
      tS: bt,
      med: med,
      slowS: slowS,
      phase: phase,
      cl0: cl0,
      sigma0: sigma0,
      clDown: clDown,
      clStop: clStop,
      downMarginSigma: downMargin,
      stopMarginSigma: stopMargin,
      warnActive: warn,
      dangerActive: danger,
      stage: stage,
      reliability: _reliability,
      pulses: pulses,
    );
    lastBurst = b;
    onBurstClosed?.call(b);
    return b;
  }

  static List<double> _tail(List<double> l, int n) =>
      l.length <= n ? l : l.sublist(l.length - n);

  static double _median(List<double> v) {
    if (v.isEmpty) return 0;
    final s = List<double>.from(v)..sort();
    final m = s.length ~/ 2;
    return s.length.isOdd ? s[m] : (s[m - 1] + s[m]) / 2.0;
  }

  static double _mean(List<double> v) =>
      v.isEmpty ? 0 : v.reduce((a, b) => a + b) / v.length;

  static double _std(List<double> v) {
    if (v.length < 2) return 0;
    final mean = _mean(v);
    final ss = v.fold<double>(0, (a, x) => a + (x - mean) * (x - mean));
    return math.sqrt(ss / (v.length - 1));
  }
}
