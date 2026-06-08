import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../core/constants.dart';
import '../core/models.dart';
import '../core/subject_category.dart';
import 'fatigue_engine.dart';
import 'profile_service.dart';
import 'simulator_service.dart';

/// EMG-FES 세션 데이터 파이프라인 — BLE/시뮬레이터 수신 → 파싱 → 큐/상태/피로엔진.
///
/// UI(위젯)에서 분리한 ChangeNotifier. 데스크탑/태블릿 모니터 화면이 이 컨트롤러를
/// 구독해 렌더링한다. (기존 home_page 는 자체 로직 유지 — 추후 통합 가능)
class SessionController extends ChangeNotifier {
  // ---- 시계열 큐 (60초 윈도우) ----
  final Queue<Sample> env = Queue();
  final Queue<Sample> rms = Queue();
  final Queue<Sample> mdf = Queue();
  final Queue<Sample> rmsSlope = Queue();
  final Queue<Sample> mdfSlope = Queue();

  final AppStatus st = AppStatus();
  FatigueEngine engine = FatigueEngine(category: SubjectCategory.healthy);

  double envLast = 0;
  double rmsLast = 0;
  double mdfLast = 0;
  int? massagerLevel;

  // 연결 상태: disconnected / scanning / connecting / connected / error
  String connState = 'disconnected';
  String? lastError;
  String deviceLabel = '';

  // 측정창/피로 — UI 콜백 (화면에서 다이얼로그/배너 트리거)
  void Function(String prompt, int durationMs)? onMeasureRequest;
  void Function()? onFatigue;
  bool _measureDialogShown = false;
  bool _fatigueShown = false;

  // ---- 내부 상태 ----
  double _t0 = 0;
  bool _t0Init = false;
  double _lastEnvPushT = -1.0;

  SimulatorService? _sim;
  bool get simOn => _sim != null;
  bool get isRunning => st.isRunning;

  // BLE
  BluetoothDevice? _device;
  BluetoothCharacteristic? _cmdChar;
  StreamSubscription<List<int>>? _dataSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  StreamSubscription<List<ScanResult>>? _scanSub;

  // ============================================================
  // 시뮬레이터
  // ============================================================
  Future<void> startSimulator(SimScenario scenario) async {
    if (simOn) return;
    if (connState == 'connected') await disconnect();
    final cat = gProfileService.active?.category;
    final voluntaryScale = switch (cat) {
      SubjectCategory.incomplete => 0.45,
      SubjectCategory.complete => 0.12,
      _ => 1.0,
    };
    final sim = SimulatorService(
      onMessage: (msg) => _onMessage(msg),
      voluntaryScale: voluntaryScale,
      voluntaryBaselineFirst: cat == SubjectCategory.incomplete,
      scenario: scenario,
    );
    sim.start();
    _sim = sim;
    connState = 'connected';
    deviceLabel = '시뮬레이터';
    lastError = null;
    notifyListeners();
  }

  void stopSimulator() {
    _sim?.handleCommand({'cmd': 'stop'});
    _sim?.stop();
    _sim = null;
    _clearSeries();
    connState = 'disconnected';
    deviceLabel = '';
    notifyListeners();
  }

  // ============================================================
  // BLE (태블릿 등 지원 기기)
  // ============================================================
  Future<void> scanAndConnect() async {
    if (kIsWeb) {
      connState = 'error';
      lastError = '웹에서는 BLE 미지원 — 시뮬레이터를 사용하세요.';
      notifyListeners();
      return;
    }
    if (connState == 'connected' || connState == 'connecting') return;
    connState = 'scanning';
    lastError = null;
    notifyListeners();
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
        if (found != null) FlutterBluePlus.stopScan();
      });
      await FlutterBluePlus.startScan(
        withServices: [Guid(kServiceUuid)],
        timeout: const Duration(seconds: 10),
      );
      await FlutterBluePlus.isScanning.where((s) => s == false).first;
      _scanSub?.cancel();
      _scanSub = null;
      if (found == null) {
        connState = 'error';
        lastError = '기기를 찾지 못함. 보드 전원/BLE 광고 확인.';
        notifyListeners();
        return;
      }
      connState = 'connecting';
      notifyListeners();
      final device = found!.device;
      _connSub = device.connectionState.listen((s) {
        if (s == BluetoothConnectionState.disconnected) {
          connState = 'disconnected';
          _device = null;
          _cmdChar = null;
          notifyListeners();
        }
      });
      await device.connect(
        license: License.free,
        timeout: const Duration(seconds: 15),
        autoConnect: false,
      );
      try {
        await device.requestMtu(247);
      } catch (_) {}
      final services = await device.discoverServices();
      BluetoothCharacteristic? dataChar;
      BluetoothCharacteristic? cmdChar;
      for (final s in services) {
        if (s.uuid.toString().toLowerCase() != kServiceUuid) continue;
        for (final c in s.characteristics) {
          final u = c.uuid.toString().toLowerCase();
          if (u == kDataCharUuid) dataChar = c;
          if (u == kCmdCharUuid) cmdChar = c;
        }
      }
      if (dataChar == null || cmdChar == null) {
        await device.disconnect();
        connState = 'error';
        lastError = '필요한 characteristic을 찾지 못함.';
        notifyListeners();
        return;
      }
      await dataChar.setNotifyValue(true);
      _dataSub = dataChar.lastValueStream.listen(_onCharData);
      _device = device;
      _cmdChar = cmdChar;
      deviceLabel = device.platformName.isNotEmpty
          ? device.platformName
          : kDeviceName;
      connState = 'connected';
      notifyListeners();
    } catch (e) {
      connState = 'error';
      lastError = '$e';
      notifyListeners();
    }
  }

  Future<void> disconnect() async {
    if (simOn) {
      stopSimulator();
      return;
    }
    try {
      await _dataSub?.cancel();
      _dataSub = null;
      await _connSub?.cancel();
      _connSub = null;
      await _device?.disconnect();
    } catch (_) {}
    _device = null;
    _cmdChar = null;
    _clearSeries();
    connState = 'disconnected';
    deviceLabel = '';
    notifyListeners();
  }

  // ============================================================
  // 명령 전송
  // ============================================================
  void send(Map<String, dynamic> cmd) {
    if (simOn) {
      _sim!.handleCommand(cmd);
      return;
    }
    final c = _cmdChar;
    if (c == null) return;
    c.write(utf8.encode(jsonEncode(cmd)), withoutResponse: false);
  }

  void startSession() {
    _clearSeries();
    _measureDialogShown = false;
    _fatigueShown = false;
    final cat = gProfileService.active?.category ?? SubjectCategory.healthy;
    engine = FatigueEngine(
      category: cat,
      rmsThreshold: st.rmsThreshold,
      mdfThreshold: st.mdfThreshold,
      consecutiveTrigger: st.consecutiveTrigger,
    );
    st.engineFatigueDetected = false;
    st.engineConsecutive = 0;
    st.engineReasons = const [];
    send({'cmd': 'start'});
  }

  void stopSession() => send({'cmd': 'stop'});
  void calibrate() => send({'cmd': 'calibrate'});
  void emergency() => send({'cmd': 'emergency'});
  void marker(String label) => send({'cmd': 'marker', 'label': label});
  void massagerUp() => send({'cmd': 'up'});
  void massagerDown() => send({'cmd': 'down'});

  // ============================================================
  // 메시지 수신
  // ============================================================
  void _onCharData(List<int> bytes) {
    if (bytes.isEmpty) return;
    try {
      _onMessage(jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>);
    } catch (_) {}
  }

  void _onMessage(Map<String, dynamic> msg) {
    try {
      final tsMs = (msg['ts'] as num).toDouble();
      final ts = tsMs / 1000.0;
      if (!_t0Init) {
        _t0 = ts;
        _t0Init = true;
      } else if (ts < _t0) {
        _t0 = ts;
        _clearSeries();
      }
      final t = ts - _t0;

      st.baselineRms = (msg['b'] as num?)?.toDouble() ?? st.baselineRms;
      st.rmsRatio = (msg['rr'] as num?)?.toDouble() ?? st.rmsRatio;
      st.muscleState = (msg['st'] as String?) ?? st.muscleState;
      st.consecutive = (msg['cc'] as num?)?.toInt() ?? st.consecutive;
      st.consecutiveTrigger =
          (msg['ct'] as num?)?.toInt() ?? st.consecutiveTrigger;
      st.rmsThreshold = (msg['rt'] as num?)?.toDouble() ?? st.rmsThreshold;
      st.mdfThreshold = (msg['mt'] as num?)?.toDouble() ?? st.mdfThreshold;

      final running = msg['run'] as bool? ?? st.isRunning;
      if (running) {
        final envVal = msg['env'] ?? msg['raw'];
        if (envVal != null) {
          final e = (envVal as num).toDouble();
          envLast = e;
          if (_lastEnvPushT < 0 || (t - _lastEnvPushT) >= kEnvPushIntervalSec) {
            _lastEnvPushT = t;
            _push(env, Sample(t, e), maxLen: kMaxEnvPoints);
          }
        }
        if (msg['rms'] != null) {
          rmsLast = (msg['rms'] as num).toDouble();
          st.lastRms = rmsLast;
          _push(rms, Sample(t, rmsLast));
        }
        if (msg['mdf'] != null) {
          mdfLast = (msg['mdf'] as num).toDouble();
          st.lastMdf = mdfLast;
          _push(mdf, Sample(t, mdfLast));
        }
        if (msg['rs'] != null) {
          _push(rmsSlope, Sample(t, (msg['rs'] as num).toDouble()));
        }
        if (msg['ms'] != null) {
          _push(mdfSlope, Sample(t, (msg['ms'] as num).toDouble()));
        }
        if (msg['mwa'] != null) st.mwAmp = (msg['mwa'] as num).toDouble();
        if (msg['mwc'] != null) st.mwArea = (msg['mwc'] as num).toDouble();
        if (msg['mwl'] != null) st.mwLatency = (msg['mwl'] as num).toDouble();
        if (msg['mwn'] != null) st.mwCount = (msg['mwn'] as num).toInt();
      }

      massagerLevel = (msg['ml'] as num?)?.toInt() ?? massagerLevel;

      st.isRunning = running;
      st.isStimulating = msg['stim'] ?? st.isStimulating;
      st.fatigueDetected = msg['fd'] ?? st.fatigueDetected;
      st.rmsSlope = (msg['rs'] as num?)?.toDouble() ?? st.rmsSlope;
      st.mdfSlope = (msg['ms'] as num?)?.toDouble() ?? st.mdfSlope;
      st.historyCount = (msg['hc'] as num?)?.toInt() ?? st.historyCount;
      st.consecutiveTrigger =
          (msg['ct'] as num?)?.toInt() ?? st.consecutiveTrigger;
      engine.rmsThreshold = st.rmsThreshold;
      engine.mdfThreshold = st.mdfThreshold;
      engine.consecutiveTrigger = st.consecutiveTrigger;

      // ---- 피로 엔진 ----
      final hasMw = msg['mwa'] != null;
      final result = engine.update(
        rmsSlope: st.rmsSlope,
        mdfSlope: st.mdfSlope,
        historyCount: st.historyCount,
        rms: msg['rms'] != null ? (msg['rms'] as num).toDouble() : null,
        mdf: msg['mdf'] != null ? (msg['mdf'] as num).toDouble() : null,
        isStimulating: st.isStimulating,
        mwAmp: hasMw ? (msg['mwa'] as num).toDouble() : null,
        mwArea: hasMw ? (msg['mwc'] as num).toDouble() : null,
        mwLatency: hasMw ? (msg['mwl'] as num).toDouble() : null,
      );
      st.engineFatigueDetected = result.detected;
      st.engineConsecutive = result.consecutive;
      st.engineReasons = result.reasons;
      st.rmsCcMean = engine.rmsChart.mean;
      st.rmsCcUcl = engine.rmsChart.upperLimit;
      st.mdfCcMean = engine.mdfChart.mean;
      st.mdfCcLcl = engine.mdfChart.lowerLimit;

      // 피로 검출 → FES 자동 정지 + 콜백 (1회)
      if (!_fatigueShown && (result.justTriggered || st.fatigueDetected)) {
        _fatigueShown = true;
        if (st.isStimulating) send({'cmd': 'stop'});
        onFatigue?.call();
      }

      // 측정창 요청 팝업
      final reqText = msg['req'] as String?;
      if (reqText != null && reqText.isNotEmpty && !_measureDialogShown) {
        _measureDialogShown = true;
        onMeasureRequest?.call(reqText, (msg['req_dur'] as num?)?.toInt() ?? 5000);
      }
      if (msg['req_end'] == true) _measureDialogShown = false;

      notifyListeners();
    } catch (_) {}
  }

  void _push(Queue<Sample> q, Sample s, {int maxLen = kMaxPoints}) {
    q.add(s);
    while (q.length > maxLen) {
      q.removeFirst();
    }
  }

  void _clearSeries() {
    env.clear();
    rms.clear();
    mdf.clear();
    rmsSlope.clear();
    mdfSlope.clear();
    _t0 = 0;
    _t0Init = false;
    _lastEnvPushT = -1.0;
    envLast = 0;
    rmsLast = 0;
    mdfLast = 0;
  }

  @override
  void dispose() {
    _sim?.stop();
    _dataSub?.cancel();
    _connSub?.cancel();
    _scanSub?.cancel();
    _device?.disconnect();
    super.dispose();
  }
}
