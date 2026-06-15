import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:share_plus/share_plus.dart';

import '../core/constants.dart';
import '../core/models.dart';
import '../core/subject_category.dart';
import '../services/ai_analysis_service.dart';
import '../services/csv_exporter.dart';
import '../services/env_logger.dart';
import '../services/fatigue_engine.dart';
import '../services/profile_service.dart';
import '../services/raw_logger.dart';
import '../services/simulator_service.dart';
import '../widgets/ai/ai_analysis_panel.dart';
import '../widgets/ble/ble_bar.dart';
import '../widgets/ble/status_bar.dart';
import '../widgets/charts/chart_card.dart';
import '../widgets/charts/slopes_chart.dart';
import '../widgets/common/section_title.dart';
import '../widgets/controls/controls.dart';
import '../widgets/controls/massager_control.dart';
import '../widgets/fatigue/fatigue_banner.dart';
import '../widgets/fatigue/fatigue_dialog.dart';
import '../widgets/fatigue/fatigue_trigger_panel.dart';
import '../widgets/measurement/measurement_request_dialog.dart';
import '../widgets/setup/workout_setup_sheet.dart';
import '../widgets/pipeline/contraction_panel.dart';
import '../widgets/pipeline/pipeline_diagram.dart';
import '../widgets/mwave/algorithm_badge.dart';
import '../widgets/mwave/mwave_panel.dart';
import '../widgets/profile/profile_bar.dart';
import '../widgets/readout/live_readout.dart';
import 'monitor_screen.dart';
import 'splash_screen.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  // BLE
  BluetoothDevice? _device;
  BluetoothCharacteristic? _cmdChar;
  StreamSubscription<List<int>>? _dataSub;
  StreamSubscription<List<int>>? _rawSub; // RAW 1kHz 바이너리 스트림 구독
  StreamSubscription<BluetoothConnectionState>? _connSub;
  StreamSubscription<List<ScanResult>>? _scanSub;
  bool _scanning = false;
  String _connState =
      'disconnected'; // disconnected / scanning / connecting / connected / error
  String? _lastError;

  // 하단 네비게이션 탭 인덱스 (0:대시보드 1:차트 2:분석 3:AI분석)
  int _tabIndex = 0;

  // 운동 종료 시 AI분석 패널 자동 실행 트리거 (값이 바뀌면 1회 실행)
  int _aiAutoRun = 0;

  // 시계열 (60초 윈도우)
  final Queue<Sample> _env = Queue();
  final Queue<Sample> _rms = Queue();
  final Queue<Sample> _mdf = Queue();
  final Queue<Sample> _rmsSlope = Queue();
  final Queue<Sample> _mdfSlope = Queue();
  final Queue<Sample> _mwAmpSeries = Queue(); // M-wave 진폭 시계열
  final Queue<Sample> _mwAreaSeries = Queue(); // M-wave 면적 시계열
  final Queue<Sample> _mwLatSeries = Queue(); // M-wave 잠복기 시계열
  double _t0 = 0;
  bool _t0Init = false; // _t0가 첫 메시지에서 설정됐는지
  double _envLast = 0;
  double _rmsLast = 0;
  double _mdfLast = 0;
  double _lastEnvPushT = -1.0; // ENV push의 마지막 t (시간 기반 데시메이션)
  final AppStatus _st = AppStatus();

  // 자체 fatigue 엔진 (활성 환자 분류에 맞춰 매 _startSession 때 재생성)
  FatigueEngine _engine = FatigueEngine(category: SubjectCategory.healthy);

  // AI 분석 (OpenAI) — .env 의 OPENAI_API_KEY 사용
  final AiAnalysisService _ai = AiAnalysisService();

  // 시뮬레이터 (EMG 센서 없이 UI 검증) — null 이면 BLE 모드
  SimulatorService? _sim;
  bool get _simOn => _sim != null;

  // 마사지기 강도(0~10) — 시뮬레이터가 'ml' 로 보고 (BLE 모드에선 null)
  int? _massagerLevel;

  // 측정창 팝업이 현재 떠 있는지 — 같은 세션 동안 중복 표시 방지
  bool _measureDialogShown = false;
  // 근피로 다이얼로그 — 한 세션에 한 번만 띄우기
  bool _fatigueDialogShown = false;
  // 이번 세션에 근피로가 한 번이라도 감지됐는지 — 래치(latch).
  // engineFatigueDetected 는 매 틱 덮어써져 정지 후 false 로 돌아갈 수 있으므로,
  // '세션에 피로가 있었다'는 사실은 이 플래그로 고정해 AI 판정/교정에 쓴다.
  bool _sessionFatigued = false;

  // 운동 결과 분석용 — 세션 시작 시각 + 피로 검출까지 걸린 시간(초)
  DateTime? _sessionStart;
  int? _timeToFatigueSec;
  // 직전 운동 결과 요약 (오늘 vs 평소 비교) — stop 시 기록 추가 '전'에 스냅샷
  Map<String, dynamic>? _lastWorkoutSummary;

  // CSV 로깅 (web만) — 1Hz로 다운샘플 (10Hz BLE 중 초당 1번만 기록)
  final List<Map<String, dynamic>> _log = [];
  String? _pendingMarker;
  int? _lastLoggedSec;

  // ENV 고해상도 로깅 — BLE 수신 전량(10Hz) 기록 → Time(ms),ENV_Value CSV
  final EnvLogRecorder _envLog = EnvLogRecorder();
  String? _lastEnvCsvPath; // 마지막 저장 경로 — 재공유용

  // RAW 고해상도 로깅 — 1kHz 원신호 전량 기록 → Time(ms),Raw_ADC CSV (raw_*.csv)
  final RawLogRecorder _rawLog = RawLogRecorder();
  String? _pendingEnvMarker; // ENV 로그용 마커 (_pendingMarker는 1Hz 로그가 소비)

  @override
  void initState() {
    super.initState();
    _initBle();
  }

  @override
  void dispose() {
    _sim?.stop();
    _disconnect();
    _scanSub?.cancel();
    super.dispose();
  }

  Future<void> _initBle() async {
    if (kIsWeb) {
      setState(() {
        _lastError = '웹 브라우저에서는 BLE 미지원. iOS/Android에서 실행하세요.';
        _connState = 'error';
      });
      return;
    }
    final isSupported = await FlutterBluePlus.isSupported;
    if (!isSupported) {
      setState(() {
        _lastError = '이 기기는 BLE를 지원하지 않습니다.';
        _connState = 'error';
      });
      return;
    }
  }

  // ---------- BLE: scan + connect ----------
  Future<void> _scanAndConnect() async {
    if (_scanning || _connState == 'connected' || _connState == 'connecting') {
      return;
    }
    setState(() {
      _scanning = true;
      _connState = 'scanning';
      _lastError = null;
    });

    try {
      await FlutterBluePlus.stopScan();
      _scanSub?.cancel();

      ScanResult? found;
      _scanSub = FlutterBluePlus.scanResults.listen((results) {
        for (final r in results) {
          final name = r.device.platformName.isNotEmpty
              ? r.device.platformName
              : r.advertisementData.advName;
          final hasService = r.advertisementData.serviceUuids
              .map((g) => g.toString().toLowerCase())
              .contains(kServiceUuid);
          if (name == kDeviceName || hasService) {
            found = r;
            break;
          }
        }
        if (found != null) {
          FlutterBluePlus.stopScan();
        }
      });

      await FlutterBluePlus.startScan(
        withServices: [Guid(kServiceUuid)],
        timeout: const Duration(seconds: 10),
      );
      await FlutterBluePlus.isScanning.where((s) => s == false).first;
      _scanSub?.cancel();
      _scanSub = null;

      if (found == null) {
        setState(() {
          _scanning = false;
          _connState = 'error';
          _lastError = 'EMG-FES-01 디바이스를 찾지 못함. 보드 전원/BLE 광고 확인.';
        });
        return;
      }

      setState(() {
        _connState = 'connecting';
      });

      final device = found!.device;
      await _connSub?.cancel();   // 재연결 시 이전 연결-상태 리스너 누수 방지
      _connSub = device.connectionState.listen((s) {
        if (s == BluetoothConnectionState.disconnected) {
          setState(() {
            _connState = 'disconnected';
            _device = null;
            _cmdChar = null;
          });
        }
      });

      await device.connect(
        license: License.free,
        timeout: const Duration(seconds: 15),
        autoConnect: false,
      );

      // MTU 협상 (iOS는 자동, Android는 명시)
      try {
        await device.requestMtu(247);
      } catch (_) {}

      // Service/characteristic 탐색
      final services = await device.discoverServices();
      BluetoothCharacteristic? dataChar;
      BluetoothCharacteristic? cmdChar;
      BluetoothCharacteristic? rawChar; // RAW 1kHz (구버전 펌웨어엔 없을 수 있음 → optional)
      for (final s in services) {
        if (s.uuid.toString().toLowerCase() != kServiceUuid) continue;
        for (final c in s.characteristics) {
          final u = c.uuid.toString().toLowerCase();
          if (u == kDataCharUuid) dataChar = c;
          if (u == kCmdCharUuid) cmdChar = c;
          if (u == kRawCharUuid) rawChar = c;
        }
      }
      if (dataChar == null || cmdChar == null) {
        await device.disconnect();
        setState(() {
          _connState = 'error';
          _lastError = '필요한 characteristic을 찾지 못함.';
          _scanning = false;
        });
        return;
      }

      await dataChar.setNotifyValue(true);
      // 재연결 시 이전 리스너가 살아있으면 같은 패킷을 2번 수신해 CSV 행이
      // 그대로 2배로 쌓인다. 새 구독 전에 반드시 이전 구독을 취소한다.
      await _dataSub?.cancel();
      _dataSub = dataChar.lastValueStream.listen(_onCharData);

      // RAW 1kHz 바이너리 스트림 — 펌웨어가 지원할 때만 구독 (JSON 채널과 분리).
      await _rawSub?.cancel();
      _rawSub = null;
      if (rawChar != null) {
        await rawChar.setNotifyValue(true);
        _rawSub = rawChar.lastValueStream.listen(_onRawData);
      }

      setState(() {
        _device = device;
        _cmdChar = cmdChar;
        _connState = 'connected';
        _scanning = false;
      });
    } catch (e) {
      setState(() {
        _connState = 'error';
        _lastError = '$e';
        _scanning = false;
      });
    }
  }

  Future<void> _disconnect() async {
    try {
      await _dataSub?.cancel();
      _dataSub = null;
      await _rawSub?.cancel();
      _rawSub = null;
      await _connSub?.cancel();
      _connSub = null;
      await _device?.disconnect();
    } catch (_) {}
    _env.clear();
    _rms.clear();
    _mdf.clear();
    _rmsSlope.clear();
    _mdfSlope.clear();
    _mwAmpSeries.clear();
    _mwAreaSeries.clear();
    _mwLatSeries.clear();
    _t0 = 0;
    _t0Init = false;
    _lastEnvPushT = -1.0;
    _envLast = 0;
    _rmsLast = 0;
    _mdfLast = 0;
    if (mounted) {
      setState(() {
        _device = null;
        _cmdChar = null;
        _connState = 'disconnected';
      });
    }
  }

  // ---------- RAW 1kHz 바이너리 수신 ----------
  // JSON이 아닌 바이너리 패킷. 세션 기록 중일 때만 raw 로거에 누적된다.
  void _onRawData(List<int> bytes) {
    _rawLog.addPacket(bytes);
  }

  // ---------- 메시지 수신 ----------
  void _onCharData(List<int> bytes) {
    if (bytes.isEmpty) return;
    try {
      final s = utf8.decode(bytes);
      final msg = jsonDecode(s) as Map<String, dynamic>;

      final tsMs = (msg['ts'] as num).toDouble();
      final ts = tsMs / 1000.0;
      // 첫 메시지: _t0 초기화. ESP 재부팅(ts 뒤로): 모든 큐 클리어.
      // 큐가 비어있다는 이유만으로는 클리어하지 않음 — 데시메이션 중 빈 순간을 트리거하지 않기 위함.
      if (!_t0Init) {
        _t0 = ts;
        _t0Init = true;
      } else if (ts < _t0) {
        _t0 = ts;
        _env.clear();
        _rms.clear();
        _mdf.clear();
        _rmsSlope.clear();
        _mdfSlope.clear();
        _mwAmpSeries.clear();
        _mwAreaSeries.clear();
        _mwLatSeries.clear();
        _lastEnvPushT = -1.0;
      }
      final t = ts - _t0;

      _st.baselineRms = (msg['b'] as num?)?.toDouble() ?? _st.baselineRms;
      _st.rmsRatio = (msg['rr'] as num?)?.toDouble() ?? _st.rmsRatio;
      _st.muscleState = (msg['st'] as String?) ?? _st.muscleState;
      _st.consecutive = (msg['cc'] as num?)?.toInt() ?? _st.consecutive;
      _st.consecutiveTrigger =
          (msg['ct'] as num?)?.toInt() ?? _st.consecutiveTrigger;
      _st.rmsThreshold = (msg['rt'] as num?)?.toDouble() ?? _st.rmsThreshold;
      _st.mdfThreshold = (msg['mt'] as num?)?.toDouble() ?? _st.mdfThreshold;

      final running = msg['run'] as bool? ?? _st.isRunning;
      // 세션이 멈출 때 차트를 즉시 비우지 않음 — 피로 시점 데이터를
      // 화면에 남겨두고, 다음 세션 _startSession() 에서 명시적으로 클리어.
      if (running && !_st.isRunning) {
        _lastLoggedSec = null;
        _lastEnvPushT = -1.0;
      }

      if (running) {
        final envVal = msg['env'] ?? msg['raw'];
        double? envForLog;
        if (envVal != null) {
          final e = (envVal as num).toDouble();
          _envLast = e;
          envForLog = e;
          // 시간 기반 5Hz 데시메이션 — 토글보다 hot reload/누락에 강건
          if (_lastEnvPushT < 0 || (t - _lastEnvPushT) >= kEnvPushIntervalSec) {
            _lastEnvPushT = t;
            _push(_env, Sample(t, e), maxLen: kMaxEnvPoints);
          }
        }
        if (msg['rms'] != null) {
          final r = (msg['rms'] as num).toDouble();
          _rmsLast = r;
          _st.lastRms = r;
          _push(_rms, Sample(t, r));
        }
        if (msg['mdf'] != null) {
          final m = (msg['mdf'] as num).toDouble();
          _mdfLast = m;
          _st.lastMdf = m;
          _push(_mdf, Sample(t, m));
        }
        if (msg['rs'] != null) {
          _push(_rmsSlope, Sample(t, (msg['rs'] as num).toDouble()));
        }
        if (msg['ms'] != null) {
          _push(_mdfSlope, Sample(t, (msg['ms'] as num).toDouble()));
        }

        // M-wave 메트릭 (새 검출이 있을 때만 펌웨어가 송신)
        if (msg['mwa'] != null) {
          _st.mwAmp = (msg['mwa'] as num).toDouble();
          _push(_mwAmpSeries, Sample(t, _st.mwAmp)); // 진폭 시계열 → 차트
        }
        if (msg['mwc'] != null) {
          _st.mwArea = (msg['mwc'] as num).toDouble();
          _push(_mwAreaSeries, Sample(t, _st.mwArea)); // 면적 시계열 → 차트
        }
        if (msg['mwl'] != null) {
          _st.mwLatency = (msg['mwl'] as num).toDouble();
          _push(_mwLatSeries, Sample(t, _st.mwLatency)); // 잠복기 시계열 → 차트
        }
        if (msg['mwn'] != null) {
          _st.mwCount = (msg['mwn'] as num).toInt();
        }

        // ENV CSV 로거 — 데시메이션 없이 수신 전량(10Hz) 누적.
        // RMS/MDF도 이제 10Hz로 도착(최신값 동봉). M-wave는 이벤트성 → ZOH.
        if (envForLog != null) {
          _envLog.add(
            tsMs.toInt(),
            envForLog,
            marker: _pendingEnvMarker ?? '',
            raw: (msg['raw'] as num?)?.toDouble() ?? 0, // 100ms 평균 ADC 원값
            rms: _rmsLast, // 10Hz 갱신값
            mdf: _mdfLast, // 10Hz 갱신값
            mwAmp: _st.mwAmp, // M-wave는 이벤트성 → 최근 검출값 유지(ZOH)
            mwArea: _st.mwArea,
            mwLatency: _st.mwLatency,
          );
          _pendingEnvMarker = null;
        }

        // 1Hz 다운샘플: ts 초 단위가 바뀔 때만 로그 (펌웨어 BLE 10Hz → CSV 1Hz)
        // 단, 마커는 분실 방지 위해 들어오면 즉시 별도 행으로 기록
        final tsSec = (msg['ts'] as num).toInt() ~/ 1000;
        final hasMarker = _pendingMarker != null && _pendingMarker!.isNotEmpty;
        if (_lastLoggedSec != tsSec || hasMarker) {
          _lastLoggedSec = tsSec;
          _log.add({
            'wall_time': DateTime.now().toIso8601String(),
            'timestamp_ms': msg['ts'],
            'emg_raw': msg['raw'],
            'emg_env': msg['env'],
            'rms': msg['rms'],
            'mdf': msg['mdf'],
            'rms_slope': msg['rs'],
            'mdf_slope': msg['ms'],
            'fatigue_detected': msg['fd'],
            'consecutive': msg['cc'],
            'is_running': msg['run'],
            'is_stimulating': msg['stim'],
            'history_count': msg['hc'],
            'baseline_rms': msg['b'],
            'rms_ratio': msg['rr'],
            'muscle_state': msg['st'],
            'marker': _pendingMarker ?? '',
          });
          _pendingMarker = null;
        }
      }

      _massagerLevel = (msg['ml'] as num?)?.toInt() ?? _massagerLevel;

      final wasStimulating = _st.isStimulating;
      _st.isRunning = running;
      _st.isStimulating = msg['stim'] ?? _st.isStimulating;
      _st.fatigueDetected = msg['fd'] ?? _st.fatigueDetected;
      _st.rmsSlope = (msg['rs'] as num?)?.toDouble() ?? _st.rmsSlope;
      _st.mdfSlope = (msg['ms'] as num?)?.toDouble() ?? _st.mdfSlope;
      _st.historyCount = (msg['hc'] as num?)?.toInt() ?? _st.historyCount;

      // 엔진 임계값을 펌웨어 값과 동기화
      _st.rmsThreshold = (msg['rt'] as num?)?.toDouble() ?? _st.rmsThreshold;
      _st.mdfThreshold = (msg['mt'] as num?)?.toDouble() ?? _st.mdfThreshold;
      _st.consecutiveTrigger =
          (msg['ct'] as num?)?.toInt() ?? _st.consecutiveTrigger;
      _engine.rmsThreshold = _st.rmsThreshold;
      _engine.mdfThreshold = _st.mdfThreshold;
      _engine.consecutiveTrigger = _st.consecutiveTrigger;

      // 수축 상태머신 필드
      _st.contractState = (msg['cs'] as num?)?.toInt() ?? _st.contractState;
      _st.contractDurMs = (msg['cd'] as num?)?.toInt() ?? _st.contractDurMs;
      _st.lastContractType = (msg['lt'] as String?) ?? _st.lastContractType;
      _st.lastContractDurMs =
          (msg['ld'] as num?)?.toInt() ?? _st.lastContractDurMs;
      _st.lastContractPeak =
          (msg['lp'] as num?)?.toDouble() ?? _st.lastContractPeak;
      _st.burstCount = (msg['bc'] as num?)?.toInt() ?? _st.burstCount;
      _st.sustainedCount = (msg['sc'] as num?)?.toInt() ?? _st.sustainedCount;
      _st.transientCount = (msg['tc'] as num?)?.toInt() ?? _st.transientCount;

      // 세션 중 최대 RMS 추적 (MVC 추정용)
      if (running && _rmsLast > _st.sessionMaxRms) {
        _st.sessionMaxRms = _rmsLast;
      }

      // ===== 자체 fatigue 엔진 (카테고리별 알고리즘) =====
      final hasMw = msg['mwa'] != null;
      // rms/mdf 는 1Hz "full" 메시지에만 들어옴 — 관리도 표본 학습에 사용.
      final hasRms = msg['rms'] != null;
      final hasMdf = msg['mdf'] != null;
      final result = _engine.update(
        rmsSlope: _st.rmsSlope,
        mdfSlope: _st.mdfSlope,
        historyCount: _st.historyCount,
        rms: hasRms ? (msg['rms'] as num).toDouble() : null,
        mdf: hasMdf ? (msg['mdf'] as num).toDouble() : null,
        isStimulating: _st.isStimulating,
        mwAmp: hasMw ? (msg['mwa'] as num).toDouble() : null,
        mwArea: hasMw ? (msg['mwc'] as num).toDouble() : null,
        mwLatency: hasMw ? (msg['mwl'] as num).toDouble() : null,
      );
      _st.engineFatigueDetected = result.detected;
      _st.engineConsecutive = result.consecutive;
      _st.engineReasons = result.reasons;
      _st.mwAmpBaseline = _engine.mwAmpBase;
      _st.mwAreaBaseline = _engine.mwAreaBase;
      _st.mwLatBaseline = _engine.mwLatBase;
      _st.mwAmpDeclinePct = _engine.lastAmpDeclinePct;
      _st.mwAreaDeclinePct = _engine.lastAreaDeclinePct;
      _st.mwLatencyDeltaMs = _engine.lastLatencyDeltaMs;
      // 관리도 상태
      _st.rmsCcMean = _engine.rmsChart.mean;
      _st.rmsCcUcl = _engine.rmsChart.upperLimit;
      _st.mdfCcMean = _engine.mdfChart.mean;
      _st.mdfCcLcl = _engine.mdfChart.lowerLimit;
      _st.rmsCcSamples = _engine.rmsChart.sampleCount;
      _st.mdfCcSamples = _engine.mdfChart.sampleCount;
      _st.mwAmpCcMean = _engine.mwAmpChart.mean;
      _st.mwAmpCcLcl = _engine.mwAmpChart.lowerLimit;
      _st.mwAreaCcMean = _engine.mwAreaChart.mean;
      _st.mwAreaCcLcl = _engine.mwAreaChart.lowerLimit;
      _st.mwLatCcMean = _engine.mwLatChart.mean;
      _st.mwLatCcUcl = _engine.mwLatChart.upperLimit;

      // 근피로 다이얼로그 — 엔진 트리거 또는 펌웨어 fd 가 처음 true 가 됐을 때 한 번만.
      final shouldShowFatigue = !_fatigueDialogShown &&
          (result.justTriggered || _st.fatigueDetected);
      if (shouldShowFatigue) {
        _fatigueDialogShown = true;
        _sessionFatigued = true; // 세션 피로 래치 — 이후 틱에 덮어써지지 않음
        // 세션 시작~피로 검출까지 걸린 시간 기록 (운동 결과 분석용)
        if (_sessionStart != null) {
          _timeToFatigueSec =
              DateTime.now().difference(_sessionStart!).inSeconds;
        }
        if (_st.isStimulating) {
          _send({'cmd': 'stop'});
        }
        // 엔진 reasons 가 있으면 사용, 없으면 fallback (펌웨어 fd 단독 트리거)
        final dialogReasons = result.reasons.isNotEmpty
            ? result.reasons
            : const <String>['3사이클 측정 완료 — 누적 피로 추정'];
        showFatigueDialog(
          context,
          status: _st,
          fesWasOn: wasStimulating,
          reasons: dialogReasons,
          onConfirm: _stopSession,        // 확인 → Stop 버튼과 동일하게 세션 종료
        );
      }
      // ===== 측정창 동작 요청 팝업 (시뮬레이터 또는 펌웨어가 'req' 발화 시) =====
      final reqText = msg['req'] as String?;
      if (reqText != null && reqText.isNotEmpty && !_measureDialogShown) {
        final dur = (msg['req_dur'] as num?)?.toInt() ?? 5000;
        _measureDialogShown = true;
        showMeasurementRequestDialog(
          context,
          prompt: reqText,
          durationMs: dur,
        );
      }
      if (msg['req_end'] == true) {
        _measureDialogShown = false;
      }

      if (mounted) setState(() {});
    } catch (_) {
      // parse 실패는 무시
    }
  }

  void _push(Queue<Sample> q, Sample s, {int maxLen = kMaxPoints}) {
    q.add(s);
    while (q.length > maxLen) {
      q.removeFirst();
    }
  }

  // ---------- 명령 ----------
  Future<void> _send(Map<String, dynamic> cmd) async {
    // 시뮬레이터 모드: 명령을 시뮬레이터로 라우팅
    if (_simOn) {
      _sim!.handleCommand(cmd);
      _toast(
        '→ (sim) ${cmd['cmd']}${cmd['label'] != null ? ': ${cmd['label']}' : ''}',
        Colors.blueAccent,
      );
      return;
    }
    final c = _cmdChar;
    if (c == null) {
      _toast('연결 안 됨 — 먼저 Connect 하세요', Colors.orange);
      return;
    }
    try {
      final bytes = utf8.encode(jsonEncode(cmd));
      await c.write(bytes, withoutResponse: false);
      _toast(
        '→ ${cmd['cmd']}${cmd['label'] != null ? ': ${cmd['label']}' : ''}',
        Colors.green,
      );
    } catch (e) {
      _toast('전송 실패: $e', Colors.red);
    }
  }

  // ---------- 시뮬레이터 토글 ----------
  // 켜면 실제 BLE 연결과 동일하게 보이도록 _connState='connected' 로 위장.
  Future<void> _toggleSimulator() async {
    if (_simOn) {
      // 끄기: 진행 중 세션 정리 + BLE disconnect 와 동등한 상태로 복귀
      _sim!.handleCommand({'cmd': 'stop'});
      _sim!.stop();
      _sim = null;
      _env.clear();
      _rms.clear();
      _mdf.clear();
      _rmsSlope.clear();
      _mdfSlope.clear();
      _mwAmpSeries.clear();
      _mwAreaSeries.clear();
      _mwLatSeries.clear();
      _t0 = 0;
      _t0Init = false;
      _lastEnvPushT = -1.0;
      _envLast = 0;
      _rmsLast = 0;
      _mdfLast = 0;
      if (mounted) {
        setState(() {
          _connState = 'disconnected';
        });
      }
      return;
    }
    // 시나리오 선택 — 임상 3사이클 vs 연속 자연 피로 폐루프
    final scenario = await _pickSimScenario();
    if (scenario == null) return;                 // 취소

    // 켜기 전에 실제 BLE 가 연결돼 있으면 끊기
    if (_connState == 'connected') {
      await _disconnect();
    }
    // 자발 수축 EMG 크기 — 마비 정도가 클수록 작음 (자극 응답은 영향 없음).
    final cat = gProfileService.active?.category;
    final voluntaryScale = switch (cat) {
      SubjectCategory.incomplete => 0.45,
      SubjectCategory.complete => 0.12,
      _ => 1.0,
    };
    final sim = SimulatorService(
      onMessage: (msg) {
        _onCharData(utf8.encode(jsonEncode(msg)));
      },
      voluntaryScale: voluntaryScale,
      // 불완전마비: 시작 직후 자발 수축으로 baseline 측정
      voluntaryBaselineFirst: cat == SubjectCategory.incomplete,
      scenario: scenario,
    );
    sim.start();
    setState(() {
      _sim = sim;
      _connState = 'connected';                 // 스캔→연결 완료처럼 보이기
      _lastError = null;
    });
  }

  // 시뮬레이터 시나리오 선택 다이얼로그.
  Future<SimScenario?> _pickSimScenario() {
    return showDialog<SimScenario>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('시뮬레이터 시나리오'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, SimScenario.continuousFatigue),
            child: const ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.trending_down, color: Colors.redAccent),
              title: Text('연속 자연 피로 → FES 자동 정지'),
              subtitle: Text('자발 수축으로 FES 시작 → 자극 지속 중 근육이 점진적으로 '
                  '지쳐 RMS↑/MDF↓ → 피로 감지 시 FES 자동 종료'),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, SimScenario.clinical),
            child: const ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.repeat),
              title: Text('임상 프로토콜 (3사이클)'),
              subtitle: Text('baseline → 자극 → 측정 팝업을 3회 반복 후 피로 검출'),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _startSession() async {
    // 1) 운동 전 바텀시트 — 기록 요약 · 컨디션 · 초기 EMG · AI 권장 강도
    final result = await showWorkoutSetupSheet(
      context,
      profile: gProfileService.active,
      status: _st,
      initial: _st.todayCondition,
    );
    if (result == null) return;                            // 사용자가 취소/닫음
    _st.todayCondition = result.condition;

    // 새 세션 시작 — 차트/큐/마지막 값 모두 깨끗이 초기화
    _env.clear();
    _rms.clear();
    _mdf.clear();
    _rmsSlope.clear();
    _mdfSlope.clear();
    _mwAmpSeries.clear();
    _mwAreaSeries.clear();
    _mwLatSeries.clear();
    _envLast = 0;
    _rmsLast = 0;
    _mdfLast = 0;
    _lastEnvPushT = -1.0;
    _t0 = 0;
    _t0Init = false;

    _log.clear();
    _envLog.start(); // ENV 10Hz 전량 기록 시작
    _rawLog.start(); // RAW 1kHz 원신호 전량 기록 시작
    _pendingMarker = null;
    _pendingEnvMarker = null;
    _st.sessionMaxRms = 0;
    _sessionStart = DateTime.now();
    _timeToFatigueSec = null;
    _measureDialogShown = false;
    _fatigueDialogShown = false;
    _sessionFatigued = false;
    // 활성 환자 카테고리로 엔진 재생성 (미지정 시 healthy로 기본)
    final cat = gProfileService.active?.category ?? SubjectCategory.healthy;
    _engine = FatigueEngine(
      category: cat,
      rmsThreshold: _st.rmsThreshold,
      mdfThreshold: _st.mdfThreshold,
      consecutiveTrigger: _st.consecutiveTrigger,
      sigmaMultiplier: result.condition.sigma,              // 컨디션별 ±kσ
    );
    _st.engineFatigueDetected = false;
    _st.engineConsecutive = 0;
    _st.engineReasons = const [];
    _st.mwAmp = 0;
    _st.mwArea = 0;
    _st.mwLatency = 0;
    _st.mwCount = 0;
    _st.mwAmpBaseline = null;
    _st.mwAreaBaseline = null;
    _st.mwLatBaseline = null;
    _st.mwAmpDeclinePct = null;
    _st.mwAreaDeclinePct = null;
    _st.mwLatencyDeltaMs = null;
    _send({'cmd': 'start'});
  }

  Future<void> _stopSession() async {
    _send({'cmd': 'stop'});
    _envLog.stop();
    _rawLog.stop();

    // 오늘 vs 평소 비교 스냅샷 — recordSession 이 오늘 값을 이력에 넣기 '전'에 캡처.
    // 비교/환산(분·배수)은 여기서 Dart 로 미리 계산해 '완성된 문구'로 넘긴다.
    // (LLM 에게 직접 산수를 시키면 gpt-4o-mini 가 자주 틀려 엉뚱한 숫자를 낸다.)
    final fatigued =
        _sessionFatigued || _st.fatigueDetected || _st.engineFatigueDetected;
    if (fatigued) {
      final p = gProfileService.active;
      double? mean(List<double>? xs) =>
          (xs == null || xs.isEmpty) ? null : xs.reduce((a, b) => a + b) / xs.length;
      var usualTime = mean(p?.recentTimeToFatigueSec);
      var usualRms = mean(p?.recentFatigueRmsSlopes);
      var usualMdf = mean(p?.recentFatigueMdfSlopes);
      var priorCount = p?.sessionCount ?? 0;
      final todayTime = _timeToFatigueSec?.toDouble();

      // 시뮬레이터: 누적 기록이 없어도 '평소보다 N분 빨리' 데모가 나오도록
      // 합성 평소값을 주입한다. (실기기 세션엔 영향 없음)
      if (_simOn) {
        priorCount = priorCount < 2 ? 5 : priorCount;
        // 평소엔 오늘보다 ~1.5분 늦게 피로한 것처럼 → "평소보다 약 1.5분 빨리"
        usualTime = (todayTime ?? 150) + 90;
        // 평소 slope 의 1.5배로 오늘 피로 → "평소보다 큰 폭으로 진행"
        if (_st.rmsSlope.abs() > 0.01) usualRms = _st.rmsSlope / 1.5;
        if (_st.mdfSlope.abs() > 0.01) usualMdf = _st.mdfSlope / 1.5;
      }

      _lastWorkoutSummary = {
        'fatigueDetected': true,
        // 원본 값 (참고용)
        'timeToFatigueSec': _timeToFatigueSec,
        'usualTimeToFatigueSec': usualTime,
        'todayFatigueRmsSlopePct': _st.rmsSlope,
        'usualFatigueRmsSlopePct': usualRms,
        'todayFatigueMdfSlopePct': _st.mdfSlope,
        'usualFatigueMdfSlopePct': usualMdf,
        'priorSessionCount': priorCount,
        // 미리 계산한 비교 문구 — AI 는 이걸 그대로 활용
        'comparison': _buildComparison(
          priorCount: priorCount,
          todayTimeSec: todayTime,
          usualTimeSec: usualTime,
          todayRmsSlope: _st.rmsSlope,
          usualRmsSlope: usualRms,
          todayMdfSlope: _st.mdfSlope,
          usualMdfSlope: usualMdf,
        ),
      };
    } else {
      _lastWorkoutSummary = {'fatigueDetected': false};
    }

    // 활성 프로파일에 세션 결과 기록
    await gProfileService.recordSession(
      baselineRms: _st.baselineRms > 0 ? _st.baselineRms : null,
      baselineMdf: null, // 펌웨어가 MDF baseline 분리 송신 시 추가
      maxRms: _st.sessionMaxRms > 0 ? _st.sessionMaxRms : null,
      fatigueRmsSlope: _st.fatigueDetected ? _st.rmsSlope : null,
      fatigueMdfSlope: _st.fatigueDetected ? _st.mdfSlope : null,
      timeToFatigueSec: _timeToFatigueSec?.toDouble(),
    );
    if (mounted) setState(() {});

    if (_log.isEmpty) {
      _toast('저장할 데이터 없음', Colors.orange);
      return;
    }
    final saved = await downloadCsv(_log, subjectId: gProfileService.active?.id);
    if (saved != null) {
      _toast('CSV 저장: $saved (${_log.length} rows)', Colors.green);
    } else {
      _toast('CSV 저장 실패', Colors.orange);
    }

    // ENV 고해상도 CSV (Time(ms),ENV_Value) 저장 + 공유 시트
    final envSaved = await _envLog.save(subjectId: gProfileService.active?.id);
    if (envSaved != null) {
      _lastEnvCsvPath = envSaved;
      _toast('ENV CSV 저장: $envSaved (${_envLog.length} samples)', Colors.green);
      await _shareEnvCsv();
    }

    // RAW 1kHz 원신호 CSV (Time(ms),Raw_ADC) 저장 — 필터링·주파수 재분석·딥러닝용
    final rawSaved = await _rawLog.save(subjectId: gProfileService.active?.id);
    if (rawSaved != null) {
      final dropMsg = _rawLog.dropped > 0 ? ', ~${_rawLog.dropped} dropped' : '';
      _toast('RAW CSV 저장: $rawSaved (${_rawLog.length} samples$dropMsg)',
          _rawLog.dropped > 0 ? Colors.orange : Colors.green);
    }

    // 운동 종료 → AI분석 탭으로 이동해 오늘의 운동을 자동 분석.
    if (AiAnalysisService.hasKey && mounted) {
      setState(() {
        _tabIndex = 3;
        _aiAutoRun++;
      });
    }
  }

  void _sendMarker(String label) {
    _pendingMarker = label;
    _pendingEnvMarker = label;
    _send({'cmd': 'marker', 'label': label});
    // 기록 여부 즉시 피드백 — 세션 중이 아니면 CSV에 안 남는다는 경고
    if (_st.isRunning) {
      _toast('마커 기록됨: $label', Colors.green);
    } else {
      _toast('세션 중이 아님 — $label 마커는 CSV에 기록되지 않습니다', Colors.orange);
    }
  }

  // ENV CSV 공유 — iOS/Android 공유 시트(이메일·메신저 등)로 내보내기.
  // 웹은 saveCsvFile 이 이미 브라우저 다운로드를 수행하므로 생략.
  Future<void> _shareEnvCsv() async {
    final path = _lastEnvCsvPath;
    if (kIsWeb || path == null) return;
    try {
      final box = context.findRenderObject() as RenderBox?;
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(path, mimeType: 'text/csv')],
          subject: 'EMG ENV 데이터',
          // iPad 공유 팝오버 anchor (iPhone/Android에선 무시됨)
          sharePositionOrigin: box != null
              ? box.localToGlobal(Offset.zero) & box.size
              : null,
        ),
      );
    } catch (e) {
      _toast('공유 실패: $e', Colors.orange);
    }
  }

  // ---------- 오늘 vs 평소 비교 문구 (Dart 선계산) ----------
  // 분 환산·배수 비교를 여기서 끝내고 완성된 한국어 문구를 만든다.
  // LLM 은 산수 없이 이 문구를 그대로 쓰기만 하면 돼 엉뚱한 숫자가 안 나온다.
  List<String> _buildComparison({
    required int priorCount,
    required double? todayTimeSec,
    required double? usualTimeSec,
    required double todayRmsSlope,
    required double? usualRmsSlope,
    required double todayMdfSlope,
    required double? usualMdfSlope,
  }) {
    final out = <String>[];
    if (priorCount <= 1) {
      out.add('누적 기록이 부족해(이전 $priorCount회) 평소와 비교하기 어렵습니다.');
      return out;
    }

    // 1) 피로까지 걸린 시간 — 분 단위로 환산
    if (todayTimeSec != null && usualTimeSec != null && usualTimeSec > 0) {
      final diffSec = usualTimeSec - todayTimeSec; // +면 평소보다 빨리 피로
      final absMin = diffSec.abs() / 60.0;
      if (absMin < 0.5) {
        out.add('평소와 비슷한 시점에 피로해졌습니다.');
      } else {
        final m = absMin < 1 ? absMin.toStringAsFixed(1) : absMin.toStringAsFixed(0);
        out.add(diffSec > 0
            ? '평소보다 약 $m분 빨리 피로해졌습니다.'
            : '평소보다 약 $m분 더 오래 버텼습니다.');
      }
    }

    // 2) 피로 진행 속도(slope) — 평소 대비 폭
    String slopeText(String label, double today, double? usual) {
      if (usual == null) return '';
      final t = today.abs(), u = usual.abs();
      if (u < 0.01) return '';
      final ratio = t / u;
      if (ratio > 1.3) return '$label 피로가 평소보다 큰 폭으로 진행됐습니다.';
      if (ratio < 0.7) return '$label 피로가 평소보다 완만했습니다.';
      return '$label 피로 진행 폭은 평소와 비슷했습니다.';
    }

    final rms = slopeText('근활성도(RMS)', todayRmsSlope, usualRmsSlope);
    final mdf = slopeText('주파수(MDF)', todayMdfSlope, usualMdfSlope);
    if (rms.isNotEmpty) out.add(rms);
    if (mdf.isNotEmpty) out.add(mdf);
    return out;
  }

  // ---------- AI 누적 기록 스냅샷 ----------
  // 반복 측정으로 쌓인 개인 기록 — AI 개인화(피로 패턴 학습)의 입력.
  Map<String, dynamic> _historySnapshot() {
    final p = gProfileService.active;
    String? lastRel;
    if (p?.lastSessionAt != null) {
      try {
        final d = DateTime.now().difference(DateTime.parse(p!.lastSessionAt!));
        lastRel = d.inDays > 0
            ? '${d.inDays}일 전'
            : (d.inHours > 0 ? '${d.inHours}시간 전' : '${d.inMinutes}분 전');
      } catch (_) {}
    }
    return {
      'sessionCount': p?.sessionCount ?? 0,
      'lastSessionAt': p?.lastSessionAt,
      'lastSessionRelative': lastRel,
      'restingRms': p?.restingRms,
      'mvcRms': p?.mvcRms,
      'mdfBaseline': p?.mdfBaseline,
      // 직전 세션들의 피로 시점 slope 이력 — 개인 피로 패턴의 핵심 단서
      'recentFatigueRmsSlopes': p?.recentFatigueRmsSlopes ?? const [],
      'recentFatigueMdfSlopes': p?.recentFatigueMdfSlopes ?? const [],
      // 직전 세션들의 피로까지 걸린 시간(초) 이력 — '평소보다 빨리/늦게' 판단용
      'recentTimeToFatigueSec': p?.recentTimeToFatigueSec ?? const [],
    };
  }

  // ---------- AI 분석 요청 (AI분석 탭) ----------
  // 현재 세션 지표 + 누적 기록을 보내 구조화된 개인화 리포트를 받는다.
  Future<AiReport> _requestAiAnalysis() async {
    final p = gProfileService.active;
    final data = <String, dynamic>{
      'profile': {
        'name': p?.name,
        'category': p?.category?.label,
        'todayCondition': _st.todayCondition.label,
        'recommendedIntensity': _st.recommendedIntensity,
      },
      // 오늘 결과 vs 평소 (피로까지 시간 / 피로 강도) — 운동결과분석 비교용
      if (_lastWorkoutSummary != null) 'todayResult': _lastWorkoutSummary,
      'history': _historySnapshot(),
      'session': {
        'isRunning': _st.isRunning,
        'isStimulating': _st.isStimulating,
        'historySeconds': _st.historyCount,
        'baselineRms': _st.baselineRms,
        'lastRms': _st.lastRms,
        'lastMdf': _st.lastMdf,
        'sessionMaxRms': _st.sessionMaxRms,
        'rmsSlopePct': _st.rmsSlope,
        'mdfSlopePct': _st.mdfSlope,
      },
      'fatigue': {
        'detected':
            _sessionFatigued || _st.engineFatigueDetected || _st.fatigueDetected,
        'consecutive': '${_st.engineConsecutive}/${_st.consecutiveTrigger}',
        'reasons': _st.engineReasons,
      },
      'controlChart': {
        'rmsMean': _st.rmsCcMean,
        'rmsUcl': _st.rmsCcUcl,
        'rmsSamples': _st.rmsCcSamples,
        'mdfMean': _st.mdfCcMean,
        'mdfLcl': _st.mdfCcLcl,
        'mdfSamples': _st.mdfCcSamples,
      },
      'contraction': {
        'burst': _st.burstCount,
        'sustained': _st.sustainedCount,
        'transient': _st.transientCount,
        'lastType': _st.lastContractType,
        'lastPeak': _st.lastContractPeak,
      },
      // M-wave 는 자극 응답이 검출된 세션에서만 보낸다. 미검출(count==0)이면
      // 0/null 을 보내지 않고 '측정 안 됨'으로 명시해 AI 가 없는 걸 분석하지 않게 한다.
      'mwave': _st.mwCount > 0
          ? {
              'amp': _st.mwAmp,
              'area': _st.mwArea,
              'latencyMs': _st.mwLatency,
              'count': _st.mwCount,
              'ampDeclinePct': _st.mwAmpDeclinePct,
              'areaDeclinePct': _st.mwAreaDeclinePct,
              'latencyDeltaMs': _st.mwLatencyDeltaMs,
            }
          : '측정 안 됨 (자극 응답 미검출)',
    };

    final report = await _ai.analyze(data);

    // 안전장치: 앱이 이미 근피로로 세션을 중단했는데 AI 가 'ok'(양호)로 내면
    // 명백한 오판 — 코드가 강제로 fatigued 로 교정한다. (LLM 할루시네이션 방지)
    final fatiguedNow =
        _sessionFatigued || _st.engineFatigueDetected || _st.fatigueDetected;
    if (fatiguedNow && report.status != ReportStatus.fatigued) {
      final hl = report.headline.contains('피로')
          ? report.headline
          : '근피로가 감지돼 운동을 중단했습니다';
      return report.copyWith(status: ReportStatus.fatigued, headline: hl);
    }
    return report;
  }

  void _toast(String msg, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: color,
        duration: const Duration(milliseconds: 1500),
      ),
    );
  }

  // ---------- 처음 화면으로 이동 ----------
  Future<void> _goToSplash() async {
    if (_st.isRunning) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('처음 화면으로 이동'),
          content: const Text(
            '세션이 진행 중입니다. 이동하면 측정이 중단되고 기록이 손실될 수 있습니다. 계속하시겠습니까?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('취소'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('이동'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const SplashScreen()),
      (_) => false,
    );
  }

  // ============================================================
  // 빌드
  // ============================================================
  @override
  Widget build(BuildContext context) {
    final canSend = _connState == 'connected';
    final active = _connState == 'connected' && _st.isRunning;
    return Scaffold(
      appBar: AppBar(
        title: const Text('RE-FIT'),
        actions: [
          IconButton(
            tooltip: _simOn ? '시뮬레이터 끄기' : '시뮬레이터 켜기 (EMG 없이 UI 확인)',
            icon: Icon(
              Icons.science_outlined,
              color: _simOn ? Colors.amber.shade800 : null,
            ),
            onPressed: _toggleSimulator,
          ),
          IconButton(
            tooltip: '모니터 화면 (데스크탑/태블릿)',
            icon: const Icon(Icons.desktop_windows_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const MonitorScreen()),
            ),
          ),
          IconButton(
            tooltip: '처음 화면',
            icon: const Icon(Icons.home_outlined),
            onPressed: _goToSplash,
          ),
          IconButton(
            tooltip: _connState == 'connected'
                ? 'Disconnect'
                : 'Scan & Connect',
            icon: Icon(
              _connState == 'connected'
                  ? Icons.bluetooth_connected
                  : Icons.bluetooth_searching,
              color: _connState == 'connected' ? Colors.green.shade600 : null,
            ),
            // 시뮬레이터로 연결된 상태면 disconnect 가 시뮬레이터를 끔
            onPressed: _connState == 'connected'
                ? (_simOn ? _toggleSimulator : _disconnect)
                : _scanAndConnect,
          ),
        ],
      ),
      body: SafeArea(
        child: IndexedStack(
          index: _tabIndex,
          children: [
            _dashboardTab(active, canSend),
            _chartsTab(),
            _analysisTab(),
            _aiAnalysisTab(),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tabIndex,
        onDestinationSelected: (i) => setState(() => _tabIndex = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.dashboard_outlined),
            selectedIcon: Icon(Icons.dashboard),
            label: '대시보드',
          ),
          NavigationDestination(
            icon: Icon(Icons.show_chart),
            label: '차트',
          ),
          NavigationDestination(
            icon: Icon(Icons.account_tree_outlined),
            selectedIcon: Icon(Icons.account_tree),
            label: '분석',
          ),
          NavigationDestination(
            icon: Icon(Icons.auto_awesome_outlined),
            selectedIcon: Icon(Icons.auto_awesome),
            label: 'AI분석',
          ),
        ],
      ),
    );
  }

  // ============================================================
  // 탭 1: 대시보드 — 연결/상태 + 실시간 값
  // ============================================================
  Widget _dashboardTab(bool active, bool canSend) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ProfileBar(
            service: gProfileService,
            onChanged: () {
              if (mounted) setState(() {});
            },
          ),
          const SizedBox(height: 8),
          BleBar(
            connState: _connState,
            device: _device,
            scanning: _scanning,
            onScanAndConnect: _scanAndConnect,
            onDisconnect: _simOn ? _toggleSimulator : _disconnect,
          ),
          const SizedBox(height: 8),
          StatusBar(connState: _connState, status: _st),
          if (_lastError != null) ...[
            const SizedBox(height: 4),
            Text(
              _lastError!,
              style: const TextStyle(color: Colors.redAccent, fontSize: 11),
            ),
          ],
          const SizedBox(height: 8),
          AlgorithmBadge(
            category: gProfileService.active?.category,
          ),
          const SizedBox(height: 8),
          LiveReadout(
            active: active,
            envLast: _envLast,
            rmsLast: _rmsLast,
            mdfLast: _mdfLast,
          ),
          const SizedBox(height: 6),
          MwavePanel(status: _st),
          if (_st.engineFatigueDetected || _st.fatigueDetected) ...[
            const SizedBox(height: 8),
            FatigueBanner(
              rmsSlope: _st.rmsSlope,
              mdfSlope: _st.mdfSlope,
            ),
            if (_st.engineReasons.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                '판정 근거: ${_st.engineReasons.join(' · ')}',
                style: const TextStyle(
                  color: Colors.redAccent,
                  fontSize: 11,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
          ],
          const SizedBox(height: 14),
          const SectionTitle('세션 제어'),
          const SizedBox(height: 6),
          ControlsBar(
            canSend: canSend,
            onStart: _startSession,
            onStop: _stopSession,
            onCalibrate: () => _send({'cmd': 'calibrate'}),
            onMarker: _sendMarker,
            onEmergency: () => _send({'cmd': 'emergency'}),
          ),
          const SizedBox(height: 14),
          const SectionTitle('마사지기 조절 (릴레이 컨트롤러)'),
          const SizedBox(height: 6),
          MassagerControl(
            canSend: canSend,
            onUp: () => _send({'cmd': 'up'}),
            onDown: () => _send({'cmd': 'down'}),
            level: _massagerLevel,
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  // ============================================================
  // 탭 2: 차트 — 신호 시계열 (60초 윈도우)
  // ============================================================
  Widget _chartsTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionTitle('③ 신호 차트 (60초 윈도우)'),
          const SizedBox(height: 6),
          ChartCard(
            title: 'EMG envelope',
            queue: _env,
            color: cEnv,
            hint: 'RAW의 |x-DC| → IIR LPF (10Hz 갱신). 힘 주면 즉시 ↑, 풀면 ↓.',
            height: 140,
          ),
          const SizedBox(height: 6),
          ChartCard(
            title: 'RMS (근활성도 크기)',
            queue: _rms,
            color: cRms,
            hint:
                '√(Σ(raw-mean)²/N) — 1초 윈도우. 초기 8점으로 관리도 학습 → UCL 초과 시 이상.',
            baselineY: _st.baselineRms > 0 ? _st.baselineRms : null,
            centerY: _st.rmsCcMean,
            upperLimitY: _st.rmsCcUcl,
            height: 140,
          ),
          const SizedBox(height: 6),
          ChartCard(
            title: 'MDF (근피로 주파수)',
            queue: _mdf,
            color: cMdf,
            hint:
                'FFT 파워 중앙 주파수 (Hz). 초기 8점으로 관리도 학습 → LCL 미만 시 이상.',
            centerY: _st.mdfCcMean,
            lowerLimitY: _st.mdfCcLcl,
            height: 140,
          ),
          const SizedBox(height: 6),
          SlopesChart(
            rmsSlopeQueue: _rmsSlope,
            mdfSlopeQueue: _mdfSlope,
            // 관리도 UCL/LCL → 슬로프 등가 (= 3σ/mean × 100)
            rmsSlopeUcl:
                (_st.rmsCcUcl != null && _st.rmsCcMean != null &&
                        _st.rmsCcMean! > 0.01)
                    ? (_st.rmsCcUcl! - _st.rmsCcMean!) / _st.rmsCcMean! * 100
                    : null,
            mdfSlopeLcl:
                (_st.mdfCcLcl != null && _st.mdfCcMean != null &&
                        _st.mdfCcMean! > 0.01)
                    ? (_st.mdfCcLcl! - _st.mdfCcMean!) / _st.mdfCcMean! * 100
                    : null,
          ),
          const SizedBox(height: 6),
          ChartCard(
            title: 'M-wave 진폭 (자극 응답 EMG)',
            queue: _mwAmpSeries,
            color: Colors.amber.shade800,
            hint:
                'FES burst마다 peak-to-peak 진폭(ADC). 자극 중에만 갱신. '
                '초기 6점으로 관리도 학습 → LCL 미만 시 피로 신호.',
            baselineY: _st.mwAmpBaseline,
            centerY: _st.mwAmpCcMean,
            lowerLimitY: _st.mwAmpCcLcl,
            height: 140,
          ),
          const SizedBox(height: 6),
          ChartCard(
            title: 'M-wave 면적 (정류 AUC)',
            queue: _mwAreaSeries,
            color: Colors.deepOrange.shade400,
            hint: 'Σ|sample| — 자극 응답 면적. LCL 미만 시 피로 신호.',
            baselineY: _st.mwAreaBaseline,
            centerY: _st.mwAreaCcMean,
            lowerLimitY: _st.mwAreaCcLcl,
            height: 140,
          ),
          const SizedBox(height: 6),
          ChartCard(
            title: 'M-wave 잠복기 (latency)',
            queue: _mwLatSeries,
            color: Colors.brown.shade400,
            hint: '자극 후 peak까지 ms. 증가(UCL 초과)가 피로 신호 — 다른 둘과 방향 반대.',
            baselineY: _st.mwLatBaseline,
            centerY: _st.mwLatCcMean,
            upperLimitY: _st.mwLatCcUcl,
            height: 140,
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  // ============================================================
  // 탭 3: 분석 — 수축 검출 · 파이프라인 · 피로 트리거
  // ============================================================
  Widget _analysisTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionTitle('① 수축 검출 (Contraction state machine)'),
          const SizedBox(height: 6),
          ContractionPanel(status: _st),
          const SizedBox(height: 14),
          const SectionTitle('② 근피로 추출 파이프라인'),
          const SizedBox(height: 6),
          PipelineDiagram(
            status: _st,
            envLast: _envLast,
            rmsLast: _rmsLast,
            mdfLast: _mdfLast,
          ),
          const SizedBox(height: 14),
          const SectionTitle('④ 피로 트리거 (이중 조건 + 연속 카운터)'),
          const SizedBox(height: 6),
          FatigueTriggerPanel(status: _st),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  // ============================================================
  // 탭 4: AI분석 — OpenAI 기반 세션 해석
  // ============================================================
  Widget _aiAnalysisTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionTitle('AI 분석 (OpenAI)'),
          const SizedBox(height: 6),
          AiAnalysisPanel(
            onRequest: _requestAiAnalysis,
            autoRunTrigger: _aiAutoRun,
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
