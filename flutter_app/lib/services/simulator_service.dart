import 'dart:async';
import 'dart:math';

/// 자극 → 안정화 → 측정창 순으로 진행되는 임상 프로토콜의 단계.
enum SimPhase {
  idle, // 세션 전
  prep, // (불완전마비) 시작 직후 자발 수축으로 baseline 측정
  baseline, // 0~10s, FES 자극 시작, baseline 수집
  stim, // 10s~, FES 자극 지속 (피로 진행)
  cooldown, // 피로 감지 후 stim OFF 직후의 안정화 (3s)
  measure, // 측정 창 — 사용자에게 동작 요청 (5s)
  done, // 측정 완료
}

/// 시뮬레이터가 재생할 시나리오.
enum SimScenario {
  /// 기존 임상 프로토콜 — baseline→자극→측정 팝업을 3사이클 반복 후 피로 검출.
  clinical,

  /// 연속 자연 피로 폐루프 — 자발 수축으로 FES 트리거 → FES 지속 →
  /// 근육이 점진적으로 지쳐 RMS↑(UCL 초과)·MDF↓(LCL 미만) → 엔진이 감지하면
  /// home_page 가 'stop' 을 보내 FES(세션)가 자동 정지된다.
  continuousFatigue,
}

/// EMG-FES 펌웨어 BLE 패킷을 흉내내는 인앱 시뮬레이터.
///
/// 시나리오:
///   - 'start' 명령 수신 → calibrating
///   - 첫 10초: 베이스라인 (rms ~ 8, mdf ~ 80Hz)
///   - 이후: 진폭↑, 평균주파수↓ (rms ramps to ~250, mdf drops to ~55Hz)
///   - 'trigger_stim' on → 50ms마다 M-wave 메트릭 갱신
///   - 약 60~70초 후: RMS slope > +20% AND MDF slope < -3% 5회 연속 → fd=true
///
/// 펌웨어와 동일한 짧은 키(ts, env, rms, mdf, rs, ms, fd, run, stim, hc, cc,
/// rt, mt, ct, b, rr, st, mk, mwa, mwc, mwl, mwn, cs, cd, lt, ld, lp, bc, sc, tc)
/// 로 메시지를 만들어 [onMessage] 로 전달한다.
class SimulatorService {
  SimulatorService({
    required this.onMessage,
    this.voluntaryScale = 1.0,
    this.voluntaryBaselineFirst = false,
    this.scenario = SimScenario.clinical,
  });

  /// 한 패킷이 만들어질 때마다 호출. home_page는 utf8 인코딩 후 _onCharData 로 흘림.
  final void Function(Map<String, dynamic>) onMessage;

  /// 자발적 수축(직접 힘 주기) EMG 크기 배수 — 마비 정도에 따라 작아짐.
  ///   healthy 1.0 · 불완전마비 ~0.45 · 완전마비 ~0.12
  /// 자극(FES) 응답은 외부 구동이라 이 배수의 영향을 받지 않는다.
  final double voluntaryScale;

  /// 시작 직후 자발 수축으로 baseline 을 먼저 측정할지 (불완전마비용).
  final bool voluntaryBaselineFirst;

  /// 재생할 시나리오 — 기본은 기존 임상 3사이클 프로토콜.
  final SimScenario scenario;

  // ---- 펌웨어와 동일한 임계값/파라미터 ----
  static const double _rmsThreshold = 20.0;
  static const double _mdfThreshold = -3.0;
  static const int _consecutiveTrigger = 5;
  static const int _historySize = 60;
  static const int _baselineSamples = 10;

  // ---- 시뮬레이션 상태 ----
  Timer? _tickTimer;
  final Random _rng = Random(42);

  // 시뮬레이션 시계 (ESP32 millis() 와 등가)
  int _tsMs = 5000;
  int _runStartMs = 0;
  bool _running = false;
  bool _stimulating = false;

  bool _fd = false;
  int _fdLatchUntilMs = 0;
  static const int _fdLatchMs = 10000;

  // 1초 단위로 갱신되는 값
  double _rms = 0;
  double _mdf = 0;
  double _rmsSlope = 0;
  double _mdfSlope = 0;
  int _consecutive = 0;

  final List<double> _rmsHist = [];
  final List<double> _mdfHist = [];

  double _baseline = 0;
  bool _baselineReady = false;
  double _voluntaryBaselinePeak = 0; // prep 단계에서 관측된 자발 수축 최대 RMS
  String _muscleState = 'idle';

  // 수축 상태머신
  int _cs = 0;
  int _contractStartMs = 0;
  double _contractPeak = 0;
  String _lastContractType = '-';
  int _lastContractDurMs = 0;
  double _lastContractPeak = 0;
  int _burstCount = 0;
  int _transientCount = 0;
  int _sustainedCount = 0;

  // M-wave
  int _mwCount = 0;
  double _mwAmp = 0;
  double _mwArea = 0;
  double _mwLat = 0;
  int _lastMwAtMs = -10000;
  bool _mwDirty = false;

  // envelope LPF (10Hz 업데이트로 단순화)
  double _env = 0;

  // 송신 제어
  String _pendingMarker = '';
  int _tickCount = 0; // 100ms tick (= 10Hz)

  // Phase 머신 / 사이클
  SimPhase _phase = SimPhase.idle;
  int _phaseStartMs = 0;
  int _cycle = 1; // 현재 사이클 (1..3)
  String _pendingReq = '';
  bool _pendingReqEnd = false;

  // 연속 피로: 자극 중 주기적 클렌치 측정창 상태
  int _lastClenchAtMs = 0;
  bool _clenchActive = false;

  // FES 두드림 탭 위상 기준점 — Easy 마커로 리셋해 탭 타이밍을 맞춘다.
  int _tapAnchorMs = 0;

  // 마사지기 강도(0~10, 기본 5) — up/down 명령으로 조절, 탭 높이에 반영.
  int _massagerLevel = 5;
  // 데모 친화 타이밍 (실측 프로토콜 1분/사이클 → 20초/사이클로 단축).
  // 총 세션 길이: 10s baseline + (20+3+5)*3 ≈ 94s
  static const int _stimMaxMs = 20000; // 각 사이클 자극 20초
  static const int _cooldownMs = 3000;
  static const int _measureMs = 5000;
  static const int _maxCycles = 3; // 3번째 측정에서 fd 발화
  // FES 두드림(tapping) 모드 — 1.5초마다 1탭(날카로운 타격성 펄스).
  // M-wave 도 탭마다(=주기마다) 1회 생성된다.
  static const double _fesPeriodMs = 1600; // 탭 간격
  static const int _tapRiseMs = 30; // 탭 상승(급)
  static const int _tapHoldMs = 350; // 탭 정점 유지(plateau) — 최고 강도 머무름
  static const int _tapDecayMs = 500; // 탭 하강 시정수 — 천천히 감쇠

  // 연속 피로 시나리오 — 자극 시작 후 완만히 진행하다 후반에 가속(피로 붕괴).
  // RMS↑/MDF↓ 가 후반 가속 구간에서 관리도(UCL/LCL)를 돌파 → ~3분경 검출.
  //   진행도 q = stim경과 / _contSpanMs, 가속항은 q>_contAccelStart 부터 부드럽게.
  static const int _contSpanMs = 205000; // 진행 정규화 기준
  static const double _contAccelStart = 0.75; // 가속 시작(span의 75% ≈ 154s)

  // 클렌치(자발 수축) 측정창 — 자극 중 40초마다 5초간 "손을 꽉 쥐어주세요".
  static const int _clenchIntervalMs = 40000;
  static const int _clenchDurMs = 5000;
  static const String _prompt = '손을 꽉 쥐어주세요';
  static const String _voluntaryPrompt = '손에 힘을 주세요'; // 시작 baseline 측정

  bool get isRunning => _tickTimer != null;

  void start() {
    if (_tickTimer != null) return;
    _tickTimer = Timer.periodic(
      const Duration(milliseconds: 100),
      (_) => _tick(),
    );
  }

  void stop() {
    _tickTimer?.cancel();
    _tickTimer = null;
  }

  /// home_page._send 가 시뮬레이터 활성 상태에서 호출.
  void handleCommand(Map<String, dynamic> cmd) {
    final c = cmd['cmd'] as String? ?? '';
    switch (c) {
      case 'start':
        _resetSession();
        _running = true;
        _runStartMs = _tsMs;
        _muscleState = 'calibrating';
        _pendingMarker = 'session_start';
        if (scenario == SimScenario.continuousFatigue) {
          // 연속 피로 폐루프: 카테고리와 무관하게 자발 수축으로 FES 트리거 후
          // FES 지속 → 점진 피로. (자극 OFF 로 시작, prep 에서 자발 baseline)
          _stimulating = false;
          _setPhase(SimPhase.prep);
          _pendingReq = _voluntaryPrompt;
        } else if (voluntaryBaselineFirst) {
          // 불완전마비: 시작 즉시 자발 수축으로 baseline 측정 (자극 OFF)
          _stimulating = false;
          _setPhase(SimPhase.prep);
          _pendingReq = _voluntaryPrompt; // 첫 팝업 "손에 힘을 주세요"
        } else {
          // 그 외: 마사지기(FES) 켜진 상태로 baseline 수집
          _stimulating = true;
          _setPhase(SimPhase.baseline);
        }
        break;
      case 'stop':
        _running = false;
        _stimulating = false;
        _muscleState = 'idle';
        _pendingMarker = 'session_stop';
        _setPhase(SimPhase.idle);
        break;
      case 'emergency':
        _running = false;
        _stimulating = false;
        _muscleState = 'idle';
        _pendingMarker = 'emergency';
        _setPhase(SimPhase.idle);
        break;
      case 'calibrate':
        _rmsHist.clear();
        _mdfHist.clear();
        _baseline = 0;
        _baselineReady = false;
        _consecutive = 0;
        _muscleState = _running ? 'calibrating' : 'idle';
        break;
      case 'trigger_stim':
        final on = cmd['on'] as bool? ?? false;
        _stimulating = on;
        break;
      case 'up':
        // 마사지기 강도 ↑ (릴레이 컨트롤러 — EMG 무관). 탭 높이로 반영.
        _massagerLevel = (_massagerLevel + 1).clamp(0, 10);
        break;
      case 'down':
        _massagerLevel = (_massagerLevel - 1).clamp(0, 10);
        break;
      case 'marker':
        final label = (cmd['label'] as String?) ?? '';
        _pendingMarker = label;
        // 'easy' 마커: FES 두드림 탭(EMG 스파이크) 위상을 지금 시점으로 리셋해
        // 누른 즉시 탭이 한 번 튀고 1.5초 주기가 그 시점부터 다시 시작된다(타이밍용).
        if (label == 'easy' && _running) {
          _tapAnchorMs = _tsMs; // 탭 위상 리셋 → 즉시 탭
          _lastMwAtMs = _tsMs - _fesPeriodMs.toInt(); // M-wave 도 탭에 맞춰 발화
        }
        break;
      case 'set_thresholds':
        // 시뮬에선 임계값을 펌웨어처럼 따라가도록 무시 (UI는 자체 표시)
        break;
    }
  }

  void _resetSession() {
    _rmsHist.clear();
    _mdfHist.clear();
    _rms = 0;
    _mdf = 0;
    _rmsSlope = 0;
    _mdfSlope = 0;
    _consecutive = 0;
    _fd = false;
    _fdLatchUntilMs = 0;
    _baseline = 0;
    _baselineReady = false;
    _voluntaryBaselinePeak = 0;
    _mwCount = 0;
    _mwAmp = _mwArea = _mwLat = 0;
    _mwDirty = false;
    _lastMwAtMs = -10000;
    _stimulating = false;
    _cs = 0;
    _contractStartMs = 0;
    _contractPeak = 0;
    _lastContractType = '-';
    _lastContractDurMs = 0;
    _lastContractPeak = 0;
    _burstCount = 0;
    _transientCount = 0;
    _sustainedCount = 0;
    _env = 0;
    _phase = SimPhase.idle;
    _phaseStartMs = 0;
    _cycle = 1;
    _pendingReq = '';
    _pendingReqEnd = false;
    _lastClenchAtMs = 0;
    _clenchActive = false;
    _tapAnchorMs = _tsMs;
  }

  void _setPhase(SimPhase p) {
    _phase = p;
    _phaseStartMs = _tsMs;
  }

  // 연속 피로 진행 인자 — 자극 경과(ms) 기준.
  //   drift: 0→1 선형(완만한 상시 피로 진행), late: 후반 부드러운 가속(0→1).
  double _contDrift(int stimElapMs) =>
      (stimElapMs / _contSpanMs).clamp(0.0, 1.0);
  double _contLate(int stimElapMs) {
    final q = _contDrift(stimElapMs);
    final r = ((q - _contAccelStart) / (1.0 - _contAccelStart)).clamp(0.0, 1.0);
    return r * r; // 시작 기울기 0 → 코너 없이 부드럽게 가속
  }

  /// _tick 안에서 매번 호출 — phase 사이 전환을 시간/이벤트 기반으로 진행.
  ///   idle    → baseline : 'start' 명령에서 직접 전환
  ///   baseline → stim     : 10s 경과 (baseline 수집 완료, 사이클 1 시작)
  ///   stim    → cooldown : 60s 경과 (강제 OFF) 또는 _stimulating false
  ///   cooldown→ measure  : 3s 안정화 완료, 동작 요청 팝업
  ///   measure → stim     : 5s 측정 종료, 다음 사이클 시작 (_cycle++ , _stimulating ON)
  ///   measure → done     : 5s 측정 종료 + _cycle == _maxCycles → 근피로 검출 (fd True)
  void _advancePhase(double tSinceRunS) {
    final phaseElapMs = _tsMs - _phaseStartMs;
    switch (_phase) {
      case SimPhase.prep:
        // 자발 수축 측정 5초 → baseline 확정 후 본 자극 운동 시작
        if (phaseElapMs >= _measureMs) {
          _pendingReqEnd = true;
          _pendingMarker = 'baseline_voluntary';
          if (_voluntaryBaselinePeak > 0) {
            _baseline = _voluntaryBaselinePeak; // 자발 수축이 baseline
            _baselineReady = true;
          }
          _runStartMs = _tsMs; // 자극 baseline 10초 재계산 기준
          _stimulating = true;
          _setPhase(SimPhase.baseline);
        }
        break;
      case SimPhase.baseline:
        if (tSinceRunS >= 10) {
          _setPhase(SimPhase.stim);
          _lastClenchAtMs = _tsMs; // 첫 클렌치는 stim 시작 +40s
        }
        break;
      case SimPhase.stim:
        if (scenario == SimScenario.continuousFatigue) {
          // 자극을 계속 유지 — 피로는 _updatePerSecond 의 RMS↑/MDF↓ 진행으로
          // 자연 발생하고, home_page 의 fatigue 엔진이 감지하면 외부에서 'stop'
          // 이 들어와 종료된다. 엔진이 끝내 못 잡는 경우의 안전장치 — 의도한
          // 검출(~stim 165s)보다 한참 뒤(220s)에만 fd 강제.
          if (!_fd && phaseElapMs >= 220000) {
            _fd = true;
            _fdLatchUntilMs = _tsMs + _fdLatchMs;
          }
          // 40초마다 자발 수축 측정창 팝업("손을 꽉 쥐어주세요"), 5초간 유지.
          if (!_clenchActive &&
              (_tsMs - _lastClenchAtMs) >= _clenchIntervalMs) {
            _clenchActive = true;
            _lastClenchAtMs = _tsMs;
            _pendingReq = _prompt;
            _pendingMarker = 'clench_check';
          } else if (_clenchActive &&
              (_tsMs - _lastClenchAtMs) >= _clenchDurMs) {
            _clenchActive = false;
            _pendingReqEnd = true;
          }
          break;
        }
        // 60s 경과 시 강제 자극 OFF → cooldown
        if (_stimulating && phaseElapMs >= _stimMaxMs) {
          _stimulating = false;
        }
        if (!_stimulating) {
          _setPhase(SimPhase.cooldown);
        }
        break;
      case SimPhase.cooldown:
        if (phaseElapMs >= _cooldownMs) {
          _setPhase(SimPhase.measure);
          _pendingReq = _prompt;
          _pendingMarker = 'measure_start_$_cycle';
        }
        break;
      case SimPhase.measure:
        if (phaseElapMs >= _measureMs) {
          _pendingReqEnd = true;
          _pendingMarker = 'measure_end_$_cycle';
          if (_cycle >= _maxCycles) {
            // 3번째 측정 종료 → done 진입. fd 는 done 들어간 뒤
            // 500ms 후에 set 해서 측정 팝업이 먼저 닫히고 피로 팝업이 뜨도록.
            _setPhase(SimPhase.done);
          } else {
            // 다음 사이클: 자극 재개
            _cycle++;
            _stimulating = true;
            _setPhase(SimPhase.stim);
          }
        }
        break;
      case SimPhase.done:
        // done 진입 500ms 후 fd 발화 — 측정 다이얼로그 dismiss 와 충돌 방지
        if (!_fd && phaseElapMs >= 500) {
          _fd = true;
          _fdLatchUntilMs = _tsMs + _fdLatchMs;
        }
        break;
      case SimPhase.idle:
        break;
    }
  }

  // ----------------------------------------------------------------
  // 100ms 틱: envelope/M-wave 는 매 tick 갱신, RMS/MDF/slope 는 1초마다
  // ----------------------------------------------------------------
  void _tick() {
    _tsMs += 100;
    _tickCount++;

    // FES passive 자극이므로 EMG envelope/RMS 는 거의 평탄.
    // 피로 검출은 사이클 카운터로 제어 — 3번째 측정 종료 시점에 _fd=true.
    final tSinceRunMs = _running ? (_tsMs - _runStartMs) : 0;
    final tSinceRunS = tSinceRunMs / 1000.0;
    final phaseElapMs = _tsMs - _phaseStartMs;

    // ---- Phase 머신 전환 ----
    _advancePhase(tSinceRunS);

    // ---- envelope (phase 기반) ----
    if (!_running) {
      _env = 3 + _rng.nextDouble() * 3;
    } else if (_phase == SimPhase.measure || _phase == SimPhase.prep) {
      // 측정/초기 baseline 창: 사용자가 직접 힘 → 자발적 EMG burst (bell curve).
      // 자극(stim) 보다 작고, 마비 정도(voluntaryScale)에 따라 더 작아진다.
      final mP = (phaseElapMs / _measureMs).clamp(0.0, 1.0);
      final bell = (1.0 - 4.0 * (mP - 0.5) * (mP - 0.5)).clamp(0.0, 1.0);
      _env = (25 + 130 * bell + _rng.nextDouble() * 15) * voluntaryScale;
    } else if (_phase == SimPhase.cooldown) {
      _env = 10 + _rng.nextDouble() * 6; // 휴식
    } else if (_phase == SimPhase.done) {
      _env = 8 + _rng.nextDouble() * 4;
    } else {
      // baseline / stim — FES 두드림(tapping): 1.5초마다 1탭.
      // 급상승(_tapRiseMs) → 정점 유지(_tapHoldMs) → 지수 감쇠(_tapDecayMs) → 휴지.
      // 탭 위상은 _tapAnchorMs 기준 — Easy 마커로 리셋하면 그 시점부터 다시 시작.
      final tapMs = (_tsMs - _tapAnchorMs).toDouble();
      final phaseMs = tapMs % _fesPeriodMs;
      final tapIdx = (tapMs / _fesPeriodMs).floor();
      // 강도(_massagerLevel 0~10) 배수: 레벨5=1.0, 10=1.5, 0=0.5.
      final intensity = 0.5 + 0.1 * _massagerLevel;
      final peak = (200 + 16 * sin(tapIdx * 1.27)) * intensity; // 탭별 변동 × 강도
      const rest = 26.0; // 탭 사이 휴지 레벨
      double pulse;
      if (phaseMs < _tapRiseMs) {
        pulse = rest + (peak - rest) * (phaseMs / _tapRiseMs); // 급상승
      } else if (phaseMs < _tapRiseMs + _tapHoldMs) {
        // 정점 유지(plateau) — 최고 강도에서 머무름 (작은 ripple)
        pulse = peak + 4 * sin(2 * pi * 8.0 * (phaseMs - _tapRiseMs) / 1000.0);
      } else {
        pulse =
            rest +
            (peak - rest) *
                exp(-(phaseMs - _tapRiseMs - _tapHoldMs) / _tapDecayMs);
      }
      _env = (pulse + (_rng.nextDouble() - 0.5) * 8).clamp(12.0, 235.0);
    }

    // ---- M-wave: FES burst (3초 duty cycle) 마다 한 번 ----
    // 사이클별 진폭/면적 감소 (baseline 대비):
    //   사이클 1: 0 → 8%
    //   사이클 2: 8 → 22%
    //   사이클 3: 22 → 42%  ← 30% 임계 통과 → Cat C/B 환자에서 M-wave 경로로 fd 자연 발화
    // (Cat A 는 RMS/MDF UCL/LCL 위반만 사용 → M-wave 변화는 표시만 됨)
    if (_running &&
        _stimulating &&
        (_tsMs - _lastMwAtMs) >= _fesPeriodMs.toInt()) {
      _lastMwAtMs = _tsMs;
      double declineP = 0;
      if (scenario == SimScenario.continuousFatigue &&
          _phase == SimPhase.stim) {
        // 연속 피로: 후반 가속 구간에서 M-wave 진폭·면적 0 → 50% 감소(잠복기↑).
        declineP = _contLate(phaseElapMs) * 0.5;
      } else if (_phase == SimPhase.stim) {
        final stimP = (phaseElapMs / _stimMaxMs).clamp(0.0, 1.0);
        const startsByCycle = [0.0, 0.08, 0.22];
        const endsByCycle = [0.08, 0.22, 0.42];
        final i = (_cycle - 1).clamp(0, _maxCycles - 1);
        declineP =
            startsByCycle[i] + (endsByCycle[i] - startsByCycle[i]) * stimP;
      }
      final ampBase = 1000 + _rng.nextDouble() * 60;
      _mwAmp = ampBase * (1.0 - declineP);
      _mwArea = (7000 + _rng.nextDouble() * 400) * (1.0 - declineP);
      // 잠복기는 declineP 0.42 까지 +3.5ms 증가 (2ms 임계도 사이클 3 에서 통과)
      _mwLat = 8.0 + 3.5 * (declineP / 0.42) + _rng.nextDouble() * 0.4;
      _mwCount++;
      _mwDirty = true;
    }

    // ---- 1초 boundary: RMS/MDF/slope 갱신 ----
    final isFullBoundary = (_tickCount % 10) == 0;
    if (isFullBoundary && _running) {
      _updatePerSecond(tSinceRunS);
    }

    // ---- 송신 ----
    final msg = <String, dynamic>{
      'ts': _tsMs,
      'env': double.parse(_env.toStringAsFixed(2)),
      'run': _running,
      'stim': _stimulating,
      'fd': _fd,
      'ml': _massagerLevel,
    };
    if (_pendingMarker.isNotEmpty) {
      msg['mk'] = _pendingMarker;
      _pendingMarker = '';
    }
    if (_pendingReq.isNotEmpty) {
      msg['req'] = _pendingReq;
      msg['req_dur'] = _measureMs;
      _pendingReq = '';
    }
    if (_pendingReqEnd) {
      msg['req_end'] = true;
      _pendingReqEnd = false;
    }
    if (_mwDirty) {
      msg['mwa'] = double.parse(_mwAmp.toStringAsFixed(2));
      msg['mwc'] = double.parse(_mwArea.toStringAsFixed(2));
      msg['mwl'] = double.parse(_mwLat.toStringAsFixed(2));
      msg['mwn'] = _mwCount;
      _mwDirty = false;
    }
    if (isFullBoundary) {
      msg['rms'] = double.parse(_rms.toStringAsFixed(2));
      msg['mdf'] = double.parse(_mdf.toStringAsFixed(2));
      msg['rs'] = double.parse(_rmsSlope.toStringAsFixed(2));
      msg['ms'] = double.parse(_mdfSlope.toStringAsFixed(2));
      msg['hc'] = _rmsHist.length;
      msg['cc'] = _consecutive;
      msg['ct'] = _consecutiveTrigger;
      msg['b'] = double.parse(_baseline.toStringAsFixed(2));
      msg['rr'] = double.parse(
        (_baseline > 0.01 ? _rms / _baseline : 1.0).toStringAsFixed(3),
      );
      msg['st'] = _muscleState;
      msg['cs'] = _cs;
      msg['cd'] = _cs != 0 ? (_tsMs - _contractStartMs) : 0;
      msg['lt'] = _lastContractType;
      msg['ld'] = _lastContractDurMs;
      msg['lp'] = double.parse(_lastContractPeak.toStringAsFixed(2));
      msg['bc'] = _burstCount;
      msg['sc'] = _sustainedCount;
      msg['tc'] = _transientCount;
      // 임계값은 10초마다 한 번
      if ((_tsMs ~/ 1000) % 10 == 0) {
        msg['rt'] = _rmsThreshold;
        msg['mt'] = _mdfThreshold;
      }
    }
    onMessage(msg);
  }

  // RMS/MDF/slope/근피로 판정 — 펌웨어 loop() 의 1Hz 경로와 동일 논리
  void _updatePerSecond(double tSinceRunS) {
    // ---- 목표 trajectory ----
    // 전체 사이클 동안 RMS/MDF 평탄 유지 → slope 자동 검출 안 됨.
    // fd 는 _advancePhase 의 3번째 measure 종료 분기에서 수동으로 True.
    if (_phase == SimPhase.prep) {
      // 초기 자발 수축 — RMS 관측, 최대값을 baseline 으로 사용.
      final mElapMs = _tsMs - _phaseStartMs;
      final mP = (mElapMs / _measureMs).clamp(0.0, 1.0);
      final bell = (1.0 - 4.0 * (mP - 0.5) * (mP - 0.5)).clamp(0.0, 1.0);
      _rms = (25 + 130 * bell + _rng.nextDouble() * 10) * voluntaryScale;
      _mdf = 75 + _rng.nextDouble() * 3;
      if (_rms > _voluntaryBaselinePeak) _voluntaryBaselinePeak = _rms;
    } else if (_phase == SimPhase.cooldown) {
      _rms = 12 + _rng.nextDouble() * 4; // 휴식 수준
      _mdf = 80 + _rng.nextDouble() * 3;
    } else if (_phase == SimPhase.measure) {
      // 자발적 수축 (사용자 동작) — 자극보다 작고 마비 정도로 축소.
      final mElapMs = _tsMs - _phaseStartMs;
      final mP = (mElapMs / _measureMs).clamp(0.0, 1.0);
      final bell = (1.0 - 4.0 * (mP - 0.5) * (mP - 0.5)).clamp(0.0, 1.0);
      _rms = (25 + 130 * bell + _rng.nextDouble() * 10) * voluntaryScale;
      _mdf = 75 + _rng.nextDouble() * 3;
    } else if (_phase == SimPhase.done) {
      _rms = 10 + _rng.nextDouble() * 3;
      _mdf = 80 + _rng.nextDouble() * 3;
    } else if (_phase == SimPhase.baseline) {
      // 학습 구간 — 아직 안 지친 상태의 안정적 baseline.
      // 관리도(mean/σ)가 여기서 확정되므로 변동을 작게 유지(σ↓ → UCL/LCL 타이트).
      _rms = 120 + (_rng.nextDouble() - 0.5) * 12; // ~114~126
      _mdf = 185 + (_rng.nextDouble() - 0.5) * 12; // ~179~191
    } else if (scenario == SimScenario.continuousFatigue) {
      // 연속 피로: 완만한 상시 진행(drift) + 후반 부드러운 가속(late).
      // RMS 가 UCL 을, MDF 가 LCL 을 후반 가속 구간에서 돌파 → 엔진 5연속 검출 →
      // home_page 가 'stop' 자동 발화 (검출 ≈ 세션 시작 후 3분). 코너 없이 자연스러움.
      final stimMs = _tsMs - _phaseStartMs;
      final drift = _contDrift(stimMs);
      final late = _contLate(stimMs);
      _rms = 120 + 8 * drift + 110 * late + (_rng.nextDouble() - 0.5) * 8;
      _mdf = 185 - 8 * drift - 105 * late + (_rng.nextDouble() - 0.5) * 8;
    } else {
      // stim phase — 사이클 1·2 는 baseline 수준 유지(피로 전),
      // 마지막 사이클에서 실제 근피로 진행:
      //   RMS 가 UCL 위로 상승 + MDF 가 LCL 아래로 하강 → 관리도 위반 → 엔진 검출.
      if (_cycle >= _maxCycles) {
        final stimP = ((_tsMs - _phaseStartMs) / _stimMaxMs).clamp(0.0, 1.0);
        // 자극 시작 2초 후부터 ~10초까지 선형 진행, 이후 plateau.
        final ramp = ((stimP - 0.1) / 0.4).clamp(0.0, 1.0);
        _rms = 120 + 100 * ramp + (_rng.nextDouble() - 0.5) * 8; // 120 → ~220
        _mdf = 185 - 85 * ramp + (_rng.nextDouble() - 0.5) * 8; // 185 → ~100
      } else {
        _rms = 120 + (_rng.nextDouble() - 0.5) * 12;
        _mdf = 185 + (_rng.nextDouble() - 0.5) * 12;
      }
    }

    _rmsHist.add(_rms);
    _mdfHist.add(_mdf);
    if (_rmsHist.length > _historySize) _rmsHist.removeAt(0);
    if (_mdfHist.length > _historySize) _mdfHist.removeAt(0);

    if (_rmsHist.length >= 30) {
      _rmsSlope = _slopePercent(_rmsHist);
      _mdfSlope = _slopePercent(_mdfHist);
    } else {
      _rmsSlope = 0;
      _mdfSlope = 0;
    }

    if (!_baselineReady && _rmsHist.length >= _baselineSamples) {
      double s = 0;
      for (var i = 0; i < _baselineSamples; i++) {
        s += _rmsHist[i];
      }
      _baseline = s / _baselineSamples;
      _baselineReady = true;
    }

    // 자동 slope 기반 _fd 트리거는 비활성화 — 사이클 구조와 충돌하기 때문.
    // fd 는 _advancePhase 의 3번째 measure 종료 분기에서만 set.
    if (_fd && _tsMs > _fdLatchUntilMs) {
      _fd = false;
    }

    // muscleState
    final ratio = _baselineReady && _baseline > 0.01 ? _rms / _baseline : 1.0;
    if (!_running) {
      _muscleState = 'idle';
    } else if (!_baselineReady) {
      _muscleState = 'calibrating';
    } else if (_fd) {
      _muscleState = 'fatigue';
    } else if (ratio > 1.5) {
      _muscleState = 'high';
    } else if (ratio < 0.7) {
      _muscleState = 'low';
    } else {
      _muscleState = 'normal';
    }

    // 수축 상태머신 (베이스라인 종료 + 활성 시 진입)
    final active = _baselineReady && _rms > _baseline * 1.2;
    if (_cs == 0 && active) {
      _cs = 1; // onset
      _contractStartMs = _tsMs;
      _contractPeak = _rms;
    } else if (_cs != 0) {
      if (_rms > _contractPeak) _contractPeak = _rms;
      if (!active) {
        // 종료 → 라벨링
        final dur = _tsMs - _contractStartMs;
        _lastContractDurMs = dur;
        _lastContractPeak = _contractPeak;
        if (dur < 2000) {
          _lastContractType = 'b';
          _burstCount++;
        } else if (dur >= 5000) {
          _lastContractType = 's';
          _sustainedCount++;
        } else {
          _lastContractType = 't';
          _transientCount++;
        }
        _cs = 0;
        _contractPeak = 0;
      } else if (_cs == 1 && (_tsMs - _contractStartMs > 2000)) {
        _cs = 2; // sustained
      }
    }
  }

  // 펌웨어 calculateSlopePercent — 선형회귀 기울기 * n / mean * 100
  double _slopePercent(List<double> hist) {
    final n = hist.length;
    if (n < 2) return 0;
    double sumX = 0, sumY = 0, sumXY = 0, sumX2 = 0;
    for (var i = 0; i < n; i++) {
      final x = i.toDouble();
      final y = hist[i];
      sumX += x;
      sumY += y;
      sumXY += x * y;
      sumX2 += x * x;
    }
    final meanY = sumY / n;
    if (meanY < 0.01) return 0;
    final denom = n * sumX2 - sumX * sumX;
    if (denom == 0) return 0;
    final slope = (n * sumXY - sumX * sumY) / denom;
    return slope * n / meanY * 100.0;
  }
}
