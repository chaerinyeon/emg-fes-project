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

  // Phase 머신
  SimPhase _phase = SimPhase.idle;
  int _phaseStartMs = 0;
  String _pendingReq = '';
  bool _pendingReqEnd = false;
  static const int _cooldownMs = 3000;
  static const int _measureMs = 5000;
  static const List<String> _prompts = [
    '발목을 들어 올려 주세요',
    '발을 아래로 눌러 주세요',
    '무릎을 펴 주세요',
    '지금 힘을 주세요',
  ];

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
    _pendingReq = '';
    _pendingReqEnd = false;
  }

  void _setPhase(SimPhase p) {
    _phase = p;
    _phaseStartMs = _tsMs;
  }

  /// _tick 안에서 매번 호출 — phase 사이 전환을 시간 또는 이벤트 기반으로 진행.
  ///   idle    → baseline : 'start' 명령에서 직접 전환
  ///   baseline → stim     : 10s 경과 (baseline 수집 완료)
  ///   stim    → cooldown : 자극이 OFF 된 직후 (피로 감지로 auto-off)
  ///   cooldown→ measure  : 3s 안정화 완료, 측정 창 + 동작 요청 팝업
  ///   measure → done     : 5s 측정 종료
  void _advancePhase(double tSinceRunS) {
    final phaseElapMs = _tsMs - _phaseStartMs;
    switch (_phase) {
      case SimPhase.baseline:
        if (tSinceRunS >= 10) _setPhase(SimPhase.stim);
        break;
      case SimPhase.stim:
        if (!_stimulating) {
          // 자극이 방금 꺼짐 (피로 감지 → auto-off, 또는 수동 OFF)
          _setPhase(SimPhase.cooldown);
        }
        break;
      case SimPhase.cooldown:
        if (phaseElapMs >= _cooldownMs) {
          _setPhase(SimPhase.measure);
          _pendingReq = _prompts[_rng.nextInt(_prompts.length)];
          _pendingMarker = 'measure_start';
        }
        break;
      case SimPhase.measure:
        if (phaseElapMs >= _measureMs) {
          _setPhase(SimPhase.done);
          _pendingReqEnd = true;
          _pendingMarker = 'measure_end';
        }
        break;
      case SimPhase.idle:
      case SimPhase.done:
        break;
    }
  }

  // ----------------------------------------------------------------
  // 100ms 틱: envelope/M-wave 는 매 tick 갱신, RMS/MDF/slope 는 1초마다
  // ----------------------------------------------------------------
  void _tick() {
    _tsMs += 100;
    _tickCount++;

    // 진행도 — FES 자극 중 환자는 passive 상태라 EMG envelope/RMS 는 거의 평탄.
    // 피로는 M-wave 진폭·면적이 감소하고 잠복기가 늘어나는 형태로 나타남.
    final tSinceRunMs = _running ? (_tsMs - _runStartMs) : 0;
    final tSinceRunS = tSinceRunMs / 1000.0;
    final fatigueP = ((tSinceRunS - 55) / 20.0).clamp(0.0, 1.0); // 가속 구간 비율

    // ---- Phase 머신 전환 ----
    _advancePhase(tSinceRunS);

    // ---- envelope (FES artifact + 미세한 자발성 EMG, 거의 평탄) ----
    if (!_running) {
      _env = 3 + _rng.nextDouble() * 3;
    } else if (_phase == SimPhase.measure) {
      // 측정 창: 사용자가 동작 → 자발적 EMG burst (bell curve)
      final mElapMs = _tsMs - _phaseStartMs;
      final mP = (mElapMs / _measureMs).clamp(0.0, 1.0);
      final bell = (1.0 - 4.0 * (mP - 0.5) * (mP - 0.5)).clamp(0.0, 1.0);
      _env = 30 + 220 * bell + _rng.nextDouble() * 25;
    } else if (_phase == SimPhase.cooldown) {
      // 안정화: 자극 끊김 → 빠르게 휴식 레벨로
      _env = 10 + _rng.nextDouble() * 6;
    } else if (_phase == SimPhase.done) {
      _env = 8 + _rng.nextDouble() * 4;
    } else {
      // FES 가 유발한 평균적 신호 레벨 + 작은 잡음. 피로 진행 시 살짝만 증가.
      final mildRise = 6 * fatigueP;
      _env = 48 + mildRise + _rng.nextDouble() * 5;
    }

    // ---- M-wave: 자극 중이면 ~50ms 마다 한 번 ----
    // 진폭/면적은 baseline 대비 0% → 45% 감소, 잠복기는 +0 → +3.5ms.
    // FatigueEngine 의 임계값(amp/area ≥30% 감소 OR 잠복기 +2ms) 을 t≈60s 부근에서 처음 넘김.
    if (_running && _stimulating &&
        (_tsMs - _lastMwAtMs) >= 50) {
      _lastMwAtMs = _tsMs;
      // declineP: 자극 시작 후 진행도 (피로 가속 전엔 천천히, 이후 가파르게)
      double declineP;
      if (tSinceRunS < 10) {
        declineP = 0;                                          // baseline 수집 중
      } else if (tSinceRunS < 55) {
        declineP = 0.15 * (tSinceRunS - 10) / 45.0;            // 0 → 15%
      } else {
        declineP = 0.15 + 0.35 * fatigueP;                     // 15% → 50%
      }
      final ampBase = 1000 + _rng.nextDouble() * 60;           // baseline ~1000
      _mwAmp = ampBase * (1.0 - declineP);
      _mwArea = (7000 + _rng.nextDouble() * 400) * (1.0 - declineP);
      _mwLat = 8.0 + 3.5 * declineP / 0.5 + _rng.nextDouble() * 0.4; // 8 → 11.5ms
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
    // FES passive 자극 중이라 RMS 는 거의 평탄. 피로는 주로 M-wave 로 잡힘.
    // 단, 카테고리 A(건강) 환자도 동일 시뮬에서 detect 되도록 t≈55s 이후에만
    // RMS/MDF slope 가 살짝 임계값을 넘도록 작은 트렌드를 둠.
    if (tSinceRunS < 10) {
      _rms = 48 + _rng.nextDouble() * 3;
      _mdf = 80 + _rng.nextDouble() * 3;
    } else if (tSinceRunS < 55) {
      _rms = 50 + _rng.nextDouble() * 2;                    // 평탄 (피로 전)
      _mdf = 79 + _rng.nextDouble() * 2;                    // 평탄
    } else {
      final p = ((tSinceRunS - 55) / 20.0).clamp(0.0, 1.0);
      // 보상성 자발 EMG 증가 (mild) + MDF 하강 — slope 가 t≈65s 부근에 임계 통과
      _rms = 50 + 22 * p + _rng.nextDouble() * 3;           // 50 → 72
      _mdf = 79 - 11 * p + _rng.nextDouble() * 2;           // 79 → 68
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

    // 근피로 판정 (펌웨어와 동일)
    if (_rmsHist.length >= 30) {
      final cond = (_rmsSlope > _rmsThreshold) && (_mdfSlope < _mdfThreshold);
      if (cond) {
        _consecutive++;
        if (_consecutive >= _consecutiveTrigger && !_fd) {
          _fd = true;
          _fdLatchUntilMs = _tsMs + _fdLatchMs;
          // 자극이 켜져 있었으면 자동 OFF
          if (_stimulating) {
            _stimulating = false;
          }
        }
      } else {
        _consecutive = 0;
      }
    }
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
