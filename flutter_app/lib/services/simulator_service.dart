import 'dart:async';
import 'dart:math';

/// 자극 → 안정화 → 측정창 순으로 진행되는 임상 프로토콜의 단계.
enum SimPhase {
  idle,         // 세션 전
  baseline,     // 0~10s, FES 자극 시작, baseline 수집
  stim,         // 10s~, FES 자극 지속 (피로 진행)
  cooldown,     // 피로 감지 후 stim OFF 직후의 안정화 (3s)
  measure,      // 측정 창 — 사용자에게 동작 요청 (5s)
  done,         // 측정 완료
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
  SimulatorService({required this.onMessage});

  /// 한 패킷이 만들어질 때마다 호출. home_page는 utf8 인코딩 후 _onCharData 로 흘림.
  final void Function(Map<String, dynamic>) onMessage;

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
  int _tickCount = 0;            // 100ms tick (= 10Hz)

  // Phase 머신 / 사이클
  SimPhase _phase = SimPhase.idle;
  int _phaseStartMs = 0;
  int _cycle = 1;                                  // 현재 사이클 (1..3)
  String _pendingReq = '';
  bool _pendingReqEnd = false;
  // 데모 친화 타이밍 (실측 프로토콜 1분/사이클 → 20초/사이클로 단축).
  // 총 세션 길이: 10s baseline + (20+3+5)*3 ≈ 94s
  static const int _stimMaxMs = 20000;             // 각 사이클 자극 20초
  static const int _cooldownMs = 3000;
  static const int _measureMs = 5000;
  static const int _maxCycles = 3;                 // 3번째 측정에서 fd 발화
  // FES duty cycle — 1.5초 ON + 1.5초 OFF 반복 (총 주기 3.0초)
  static const double _fesOnMs = 1500;
  static const double _fesOffMs = 1500;
  static const double _fesPeriodMs = _fesOnMs + _fesOffMs;
  static const String _prompt = '손을 꽉 쥐어주세요';

  bool get isRunning => _tickTimer != null;

  void start() {
    if (_tickTimer != null) return;
    _tickTimer = Timer.periodic(const Duration(milliseconds: 100), (_) => _tick());
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
        // 실사용: 마사지기(FES) 가 켜진 상태에서 측정 → M-wave 가 처음부터 잡혀야 함
        _stimulating = true;
        _muscleState = 'calibrating';
        _pendingMarker = 'session_start';
        _setPhase(SimPhase.baseline);
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
      case 'marker':
        _pendingMarker = (cmd['label'] as String?) ?? '';
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
  }

  void _setPhase(SimPhase p) {
    _phase = p;
    _phaseStartMs = _tsMs;
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
      case SimPhase.baseline:
        if (tSinceRunS >= 10) _setPhase(SimPhase.stim);
        break;
      case SimPhase.stim:
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
    } else if (_phase == SimPhase.measure) {
      // 측정 창: 사용자가 동작 → 자발적 EMG burst (bell curve)
      final mP = (phaseElapMs / _measureMs).clamp(0.0, 1.0);
      final bell = (1.0 - 4.0 * (mP - 0.5) * (mP - 0.5)).clamp(0.0, 1.0);
      _env = 30 + 220 * bell + _rng.nextDouble() * 25;
    } else if (_phase == SimPhase.cooldown) {
      _env = 10 + _rng.nextDouble() * 6;                 // 휴식
    } else if (_phase == SimPhase.done) {
      _env = 8 + _rng.nextDouble() * 4;
    } else {
      // baseline / stim — FES duty cycle: 1.5s ON + 1.5s OFF 반복.
      // ON 구간 동안 envelope 가 sustained high, OFF 구간엔 빠르게 baseline 으로.
      final phaseMs = (tSinceRunS * 1000.0) % _fesPeriodMs;
      final cycleIdx = (tSinceRunS * 1000.0 / _fesPeriodMs).floor();
      final peakHigh = 156 + 12 * sin(cycleIdx * 1.27);   // 144~168, 사이클별 고정
      const baselineLevel = 32.0;
      double pulse;
      if (phaseMs < _fesOnMs) {
        // ----- ON 구간 (0 ~ 1500ms) -----
        if (phaseMs < 80) {
          // 빠른 상승 — baseline → peak
          pulse = baselineLevel +
              (peakHigh - baselineLevel) * (phaseMs / 80.0);
        } else {
          // sustained plateau — peak 부근에서 small ripple
          pulse = peakHigh +
              7 * sin(2 * pi * 6.0 * (phaseMs - 80) / 1000.0);
        }
      } else {
        // ----- OFF 구간 (1500 ~ 3000ms) -----
        final offMs = phaseMs - _fesOnMs;
        if (offMs < 150) {
          // 자극 종료 직후 빠른 하강
          pulse = baselineLevel +
              (peakHigh - baselineLevel) * exp(-offMs / 60.0);
        } else {
          // baseline 휴식
          pulse = baselineLevel + 4 * sin(2 * pi * 0.4 * tSinceRunS);
        }
      }
      _env = (pulse + (_rng.nextDouble() - 0.5) * 12).clamp(18.0, 185.0);
    }

    // ---- M-wave: FES burst (3초 duty cycle) 마다 한 번 ----
    // 사이클별 진폭/면적 감소 (baseline 대비):
    //   사이클 1: 0 → 8%
    //   사이클 2: 8 → 22%
    //   사이클 3: 22 → 42%  ← 30% 임계 통과 → Cat C/B 환자에서 M-wave 경로로 fd 자연 발화
    // (Cat A 는 RMS/MDF UCL/LCL 위반만 사용 → M-wave 변화는 표시만 됨)
    if (_running && _stimulating &&
        (_tsMs - _lastMwAtMs) >= _fesPeriodMs.toInt()) {
      _lastMwAtMs = _tsMs;
      double declineP = 0;
      if (_phase == SimPhase.stim) {
        final stimP = (phaseElapMs / _stimMaxMs).clamp(0.0, 1.0);
        const startsByCycle = [0.0, 0.08, 0.22];
        const endsByCycle   = [0.08, 0.22, 0.42];
        final i = (_cycle - 1).clamp(0, _maxCycles - 1);
        declineP = startsByCycle[i] +
                   (endsByCycle[i] - startsByCycle[i]) * stimP;
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
    if (_phase == SimPhase.cooldown) {
      _rms = 12 + _rng.nextDouble() * 4;                    // 휴식 수준
      _mdf = 80 + _rng.nextDouble() * 3;
    } else if (_phase == SimPhase.measure) {
      // 자발적 수축 (사용자 동작) — RMS 강하게 ↑, MDF 살짝 ↓
      final mElapMs = _tsMs - _phaseStartMs;
      final mP = (mElapMs / _measureMs).clamp(0.0, 1.0);
      final bell = (1.0 - 4.0 * (mP - 0.5) * (mP - 0.5)).clamp(0.0, 1.0);
      _rms = 30 + 200 * bell + _rng.nextDouble() * 10;
      _mdf = 75 + _rng.nextDouble() * 3;
    } else if (_phase == SimPhase.done) {
      _rms = 10 + _rng.nextDouble() * 3;
      _mdf = 80 + _rng.nextDouble() * 3;
    } else if (_phase == SimPhase.baseline) {
      // baseline 10초 동안에도 자극이 켜져 있어 EMG 가 이미 활성 — 실측에 맞춤
      final t = tSinceRunS;
      final rmsOsc = 18 * sin(2 * pi * 0.13 * t) +
                     10 * sin(2 * pi * 0.35 * t);
      _rms = (128 + rmsOsc + (_rng.nextDouble() - 0.5) * 35)
          .clamp(85.0, 175.0);
      final mdfOsc = 35 * sin(2 * pi * 0.09 * t) +
                     22 * sin(2 * pi * 0.5 * t);
      _mdf = (185 + mdfOsc + (_rng.nextDouble() - 0.5) * 80)
          .clamp(110.0, 285.0);
    } else {
      // stim phase (3사이클 모두 동일한 노이즈 패턴 — 실측 RMS/MDF 범위)
      final t = tSinceRunS;
      final rmsOsc = 22 * sin(2 * pi * 0.13 * t) +
                     12 * sin(2 * pi * 0.4 * t);
      _rms = (128 + rmsOsc + (_rng.nextDouble() - 0.5) * 40)
          .clamp(85.0, 175.0);
      final mdfOsc = 40 * sin(2 * pi * 0.09 * t) +
                     25 * sin(2 * pi * 0.55 * t);
      _mdf = (180 + mdfOsc + (_rng.nextDouble() - 0.5) * 90)
          .clamp(110.0, 285.0);
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
      _cs = 1;                                      // onset
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
        _cs = 2;                                    // sustained
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
