// EMG-FES Monitor — BLE 클라이언트 + 근피로 추출 파이프라인 시각화
//
// 통신: BLE GATT (Nordic UART Service 호환)
//   Service:  6E400001-B5A3-F393-E0A9-E50E24DCCA9E
//   DATA char (notify, ESP32 → Phone): 6E400003-...
//   CMD char  (write,  Phone → ESP32): 6E400002-...
//
// 펌웨어가 매 1초마다 보내는 JSON (짧은 키):
//   ts, raw, env, rms, mdf, rs, ms, fd, run, stim, hc, cc, rt, mt, ct, b, rr, st, mk

import 'dart:async';
import 'dart:convert';
import 'dart:collection';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'csv_save_stub.dart' if (dart.library.html) 'csv_save_web.dart';
import 'profile_service.dart';

// ===== BLE UUID =====
const String kServiceUuid = '6e400001-b5a3-f393-e0a9-e50e24dcca9e';
const String kDataCharUuid = '6e400003-b5a3-f393-e0a9-e50e24dcca9e';
const String kCmdCharUuid = '6e400002-b5a3-f393-e0a9-e50e24dcca9e';
const String kDeviceName = 'EMG-FES-01';

// ===== 색상 =====
const _cEnv = Color(0xFF82B1FF); // 하늘색
const _cRms = Color(0xFF69F0AE); // 연두
const _cMdf = Color(0xFFFFD180); // 주황
const _cRmsSlope = Color(0xFFFF8A80); // 분홍 (slope 강조)
const _cMdfSlope = Color(0xFFB388FF); // 보라
const _cThr = Color(0xFFFF5252); // 임계값 빨강

final ProfileService gProfileService = ProfileService();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Hive.initFlutter();
  await gProfileService.init();
  runApp(const EmgFesApp());
}

class EmgFesApp extends StatelessWidget {
  const EmgFesApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'EMG-FES Monitor',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.indigo,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

// ---------- 데이터 모델 ----------
class _Sample {
  final double t;
  final double value;
  const _Sample(this.t, this.value);
}

class _Status {
  bool isRunning = false;
  bool isStimulating = false;
  bool fatigueDetected = false;
  double rmsSlope = 0;
  double mdfSlope = 0;
  int historyCount = 0;
  int consecutive = 0; // 0~5
  int consecutiveTrigger = 5; // 펌웨어 기본값
  double rmsThreshold = 20.0;
  double mdfThreshold = -3.0;
  double baselineRms = 0;
  double rmsRatio = 1.0;
  String muscleState = 'idle';

  // 수축 상태머신 (펌웨어로부터)
  int contractState = 0; // 0=rest, 1=onset, 2=sustained
  int contractDurMs = 0; // 현재 수축 지속 시간 ms
  String lastContractType = '-'; // 'b'/'t'/'s'/'-'
  int lastContractDurMs = 0;
  double lastContractPeak = 0;
  int burstCount = 0;
  int sustainedCount = 0;
  int transientCount = 0;

  // 세션 중 관측된 최대 RMS (MVC 추정용)
  double sessionMaxRms = 0;
}

// ---------- HomePage ----------
class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const int windowSec = 60;
  static const int maxPoints = windowSec;          // 1Hz 신호용 (rms/mdf/slope)
  static const int maxEnvPoints = windowSec * 5;   // 5Hz envelope 60초치 (UI 부하 절감)

  // BLE
  BluetoothDevice? _device;
  BluetoothCharacteristic? _dataChar;
  BluetoothCharacteristic? _cmdChar;
  StreamSubscription<List<int>>? _dataSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  StreamSubscription<List<ScanResult>>? _scanSub;
  bool _scanning = false;
  String _connState =
      'disconnected'; // disconnected / scanning / connecting / connected / error
  String? _lastError;

  // 시계열 (60초 윈도우)
  final Queue<_Sample> _env = Queue();
  final Queue<_Sample> _rms = Queue();
  final Queue<_Sample> _mdf = Queue();
  final Queue<_Sample> _rmsSlope = Queue();
  final Queue<_Sample> _mdfSlope = Queue();
  double _t0 = 0;
  double _envLast = 0;
  double _rmsLast = 0;
  double _mdfLast = 0;
  bool _envDecim = false;          // ENV 데시메이션 토글 (10Hz 입력 → 5Hz 저장)
  final _Status _st = _Status();

  // CSV 로깅 (web만) — 1Hz로 다운샘플 (10Hz BLE 중 초당 1번만 기록)
  final List<Map<String, dynamic>> _log = [];
  String? _pendingMarker;
  int? _lastLoggedSec;

  // ---------- 라이프사이클 ----------
  @override
  void initState() {
    super.initState();
    _initBle();
  }

  @override
  void dispose() {
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
    // 어댑터 상태
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
      _connSub = device.connectionState.listen((s) {
        if (s == BluetoothConnectionState.disconnected) {
          setState(() {
            _connState = 'disconnected';
            _device = null;
            _dataChar = null;
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
        setState(() {
          _connState = 'error';
          _lastError = '필요한 characteristic을 찾지 못함.';
          _scanning = false;
        });
        return;
      }

      await dataChar.setNotifyValue(true);
      _dataSub = dataChar.lastValueStream.listen(_onCharData);

      setState(() {
        _device = device;
        _dataChar = dataChar;
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
      await _connSub?.cancel();
      _connSub = null;
      await _device?.disconnect();
    } catch (_) {}
    _env.clear();
    _rms.clear();
    _mdf.clear();
    _rmsSlope.clear();
    _mdfSlope.clear();
    _t0 = 0;
    _envLast = 0;
    _rmsLast = 0;
    _mdfLast = 0;
    if (mounted) {
      setState(() {
        _device = null;
        _dataChar = null;
        _cmdChar = null;
        _connState = 'disconnected';
      });
    }
  }

  // ---------- 메시지 수신 ----------
  void _onCharData(List<int> bytes) {
    if (bytes.isEmpty) return;
    try {
      final s = utf8.decode(bytes);
      final msg = jsonDecode(s) as Map<String, dynamic>;

      final tsMs = (msg['ts'] as num).toDouble();
      final ts = tsMs / 1000.0;
      if (_env.isEmpty || ts < _t0) {
        _t0 = ts;
        _env.clear();
        _rms.clear();
        _mdf.clear();
        _rmsSlope.clear();
        _mdfSlope.clear();
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
      if (!running && _st.isRunning) {
        _env.clear();
        _rms.clear();
        _mdf.clear();
        _rmsSlope.clear();
        _mdfSlope.clear();
        _envLast = 0;
        _rmsLast = 0;
        _mdfLast = 0;
      }
      // 세션이 새로 시작되면 로그 다운샘플 추적도 리셋
      if (running && !_st.isRunning) {
        _lastLoggedSec = null;
      }

      if (running) {
        final envVal = msg['env'] ?? msg['raw'];
        if (envVal != null) {
          final e = (envVal as num).toDouble();
          _envLast = e;
          _envDecim = !_envDecim;
          if (_envDecim) {
            // 5Hz로 데시메이션 (10Hz 들어오는 것 중 절반만 차트 큐에 push)
            _push(_env, _Sample(t, e), maxLen: maxEnvPoints);
          }
        }
        if (msg['rms'] != null) {
          final r = (msg['rms'] as num).toDouble();
          _rmsLast = r;
          _push(_rms, _Sample(t, r));
        }
        if (msg['mdf'] != null) {
          final m = (msg['mdf'] as num).toDouble();
          _mdfLast = m;
          _push(_mdf, _Sample(t, m));
        }
        if (msg['rs'] != null) {
          _push(_rmsSlope, _Sample(t, (msg['rs'] as num).toDouble()));
        }
        if (msg['ms'] != null) {
          _push(_mdfSlope, _Sample(t, (msg['ms'] as num).toDouble()));
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

      final wasFatigued = _st.fatigueDetected;
      final wasStimulating = _st.isStimulating;
      _st.isRunning = running;
      _st.isStimulating = msg['stim'] ?? _st.isStimulating;
      _st.fatigueDetected = msg['fd'] ?? _st.fatigueDetected;
      _st.rmsSlope = (msg['rs'] as num?)?.toDouble() ?? _st.rmsSlope;
      _st.mdfSlope = (msg['ms'] as num?)?.toDouble() ?? _st.mdfSlope;
      _st.historyCount = (msg['hc'] as num?)?.toInt() ?? _st.historyCount;

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

      if (!wasFatigued && _st.fatigueDetected) {
        _onFatigueDetected(fesWasOn: wasStimulating);
      }
      if (mounted) setState(() {});
    } catch (_) {
      // parse 실패는 무시
    }
  }

  void _push(Queue<_Sample> q, _Sample s, {int maxLen = maxPoints}) {
    q.add(s);
    while (q.length > maxLen) {
      q.removeFirst();
    }
  }

  // ---------- 명령 ----------
  Future<void> _send(Map<String, dynamic> cmd) async {
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

  void _startSession() {
    _log.clear();
    _pendingMarker = null;
    _st.sessionMaxRms = 0;
    _send({'cmd': 'start'});
  }

  Future<void> _stopSession() async {
    _send({'cmd': 'stop'});

    // 활성 프로파일에 세션 결과 기록
    await gProfileService.recordSession(
      baselineRms: _st.baselineRms > 0 ? _st.baselineRms : null,
      baselineMdf: null, // 펌웨어가 MDF baseline 분리 송신 시 추가
      maxRms: _st.sessionMaxRms > 0 ? _st.sessionMaxRms : null,
      fatigueRmsSlope: _st.fatigueDetected ? _st.rmsSlope : null,
      fatigueMdfSlope: _st.fatigueDetected ? _st.mdfSlope : null,
    );
    if (mounted) setState(() {});

    if (_log.isEmpty) {
      _toast('저장할 데이터 없음', Colors.orange);
      return;
    }
    if (isWebCsvSupported) {
      _downloadCsv();
    } else {
      _toast('세션 기록됨 (모바일 CSV 저장은 PC 로거 사용)', Colors.green);
    }
  }

  void _sendMarker(String label) {
    _pendingMarker = label;
    _send({'cmd': 'marker', 'label': label});
  }

  void _downloadCsv() {
    const headers = [
      'wall_time',
      'timestamp_ms',
      'emg_raw',
      'emg_env',
      'rms',
      'mdf',
      'rms_slope',
      'mdf_slope',
      'fatigue_detected',
      'consecutive',
      'is_running',
      'is_stimulating',
      'history_count',
      'baseline_rms',
      'rms_ratio',
      'muscle_state',
      'marker',
    ];
    final sb = StringBuffer()..writeln(headers.join(','));
    for (final row in _log) {
      sb.writeln(
        headers
            .map((k) {
              final v = row[k];
              if (v == null) return '';
              final s = v.toString();
              return s.contains(',') ? '"$s"' : s;
            })
            .join(','),
      );
    }
    final now = DateTime.now();
    final stamp =
        '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}'
        '_${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}';
    saveCsvFile('emg_$stamp.csv', sb.toString());
    _toast('CSV 저장: emg_$stamp.csv (${_log.length} rows)', Colors.green);
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

  // ---------- 피로 감지 다이얼로그 ----------
  void _onFatigueDetected({bool fesWasOn = false}) {
    if (!mounted) return;
    final rs = _st.rmsSlope.toStringAsFixed(1);
    final ms = _st.mdfSlope.toStringAsFixed(1);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.red.shade900,
        icon: const Icon(
          Icons.warning_amber_rounded,
          size: 56,
          color: Colors.white,
        ),
        title: const Text(
          '근피로 감지!',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 22,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'RMS slope +$rs%   |   MDF slope $ms%',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
            const SizedBox(height: 6),
            Text(
              fesWasOn
                  ? '자극이 자동으로 정지되었습니다.'
                  : '연속 만족 카운트 5/5 도달 (FES 미가동 — 자동 정지 없음).',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ],
        ),
        actions: [
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.white),
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('확인', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // 빌드
  // ============================================================
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('EMG-FES Monitor'),
        actions: [
          IconButton(
            tooltip: _connState == 'connected'
                ? 'Disconnect'
                : 'Scan & Connect',
            icon: Icon(
              _connState == 'connected'
                  ? Icons.bluetooth_connected
                  : Icons.bluetooth_searching,
              color: _connState == 'connected' ? Colors.greenAccent : null,
            ),
            onPressed: _connState == 'connected'
                ? _disconnect
                : _scanAndConnect,
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildProfileBar(),
              const SizedBox(height: 8),
              _buildBleBar(),
              const SizedBox(height: 8),
              _buildStatusBar(),
              if (_lastError != null) ...[
                const SizedBox(height: 4),
                Text(
                  _lastError!,
                  style: const TextStyle(color: Colors.redAccent, fontSize: 11),
                ),
              ],
              const SizedBox(height: 10),
              _buildLiveReadout(),
              if (_st.fatigueDetected) ...[
                const SizedBox(height: 8),
                _buildFatigueBanner(),
              ],

              const SizedBox(height: 14),
              _sectionTitle('① 수축 검출 (Contraction state machine)'),
              const SizedBox(height: 6),
              _buildContractionPanel(),

              const SizedBox(height: 14),
              _sectionTitle('② 근피로 추출 파이프라인'),
              const SizedBox(height: 6),
              _buildPipelineDiagram(),

              const SizedBox(height: 14),
              _sectionTitle('③ 신호 차트 (60초 윈도우)'),
              const SizedBox(height: 6),
              _buildChart(
                'EMG envelope',
                _env,
                _cEnv,
                hint: 'RAW의 |x-DC| → IIR LPF (10Hz 갱신). 힘 주면 즉시 ↑, 풀면 ↓.',
                height: 140,
              ),
              const SizedBox(height: 6),
              _buildChart(
                'RMS (근활성도 크기)',
                _rms,
                _cRms,
                hint: '√(Σ(raw-mean)²/N) — 1초 윈도우. 피로 시 ↑ 또는 환자가 힘 더 줘도 ↑.',
                baselineY: _st.baselineRms > 0 ? _st.baselineRms : null,
                height: 140,
              ),
              const SizedBox(height: 6),
              _buildChart(
                'MDF (근피로 주파수)',
                _mdf,
                _cMdf,
                hint: 'FFT 파워 중앙 주파수 (Hz). 피로 시 ↓ (저주파로 left-shift).',
                height: 140,
              ),
              const SizedBox(height: 6),
              _buildSlopesChart(),

              const SizedBox(height: 14),
              _sectionTitle('④ 피로 트리거 (이중 조건 + 연속 카운터)'),
              const SizedBox(height: 6),
              _buildFatigueTriggerPanel(),

              const SizedBox(height: 18),
              _buildControls(),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  // ---------- 섹션 타이틀 ----------
  Widget _sectionTitle(String t) => Text(
    t,
    style: const TextStyle(
      color: Colors.white70,
      fontSize: 13,
      fontWeight: FontWeight.w700,
    ),
  );

  // ---------- BLE 바 ----------
  Widget _buildBleBar() {
    final isConn = _connState == 'connected';
    return Row(
      children: [
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.white10,
              border: Border.all(color: Colors.white24),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(
                  isConn
                      ? Icons.bluetooth_connected
                      : Icons.bluetooth_searching,
                  size: 18,
                  color: isConn ? Colors.greenAccent : Colors.white60,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    isConn
                        ? (_device?.platformName.isNotEmpty == true
                              ? _device!.platformName
                              : kDeviceName)
                        : 'Device: $kDeviceName  (UUID ${kServiceUuid.substring(0, 8)}…)',
                    style: const TextStyle(fontSize: 12),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        FilledButton(
          onPressed: isConn
              ? _disconnect
              : (_scanning ? null : _scanAndConnect),
          child: Text(
            isConn
                ? 'Disconnect'
                : (_scanning ? 'Scanning…' : 'Scan & Connect'),
          ),
        ),
      ],
    );
  }

  // ---------- 상태 칩 ----------
  Widget _buildStatusBar() {
    Color stateColor;
    switch (_connState) {
      case 'connected':
        stateColor = Colors.green;
        break;
      case 'connecting':
      case 'scanning':
        stateColor = Colors.orange;
        break;
      case 'error':
        stateColor = Colors.red;
        break;
      default:
        stateColor = Colors.grey;
    }
    final chips = <Widget>[
      _chip(_connState.toUpperCase(), stateColor),
      if (_st.isRunning) _chip('RUN', Colors.indigo),
      if (_st.isStimulating) _chip('STIM', Colors.orange),
      if (_st.fatigueDetected) _chip('FATIGUE', Colors.red),
      _chip('state: ${_st.muscleState}', Colors.blueGrey),
      _chip('hist ${_st.historyCount}', Colors.blueGrey),
    ];
    return Wrap(spacing: 6, runSpacing: 6, children: chips);
  }

  Widget _chip(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.25),
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(label, style: TextStyle(color: color, fontSize: 12)),
    );
  }

  // ---------- 라이브 큰숫자 (ENV / RMS / MDF) ----------
  Widget _buildLiveReadout() {
    final active = _connState == 'connected' && _st.isRunning;
    Widget tile(String label, String val, Color color, String unit) {
      return Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: const TextStyle(color: Colors.white60, fontSize: 11),
            ),
            const SizedBox(height: 2),
            RichText(
              text: TextSpan(
                children: [
                  TextSpan(
                    text: val,
                    style: TextStyle(
                      color: color,
                      fontSize: 26,
                      fontWeight: FontWeight.bold,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  TextSpan(
                    text: '  $unit',
                    style: const TextStyle(color: Colors.white38, fontSize: 11),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        border: Border.all(color: Colors.white24),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          tile('ENV', active ? _envLast.toStringAsFixed(0) : '—', _cEnv, ''),
          Container(width: 1, height: 38, color: Colors.white24),
          const SizedBox(width: 10),
          tile('RMS', active ? _rmsLast.toStringAsFixed(1) : '—', _cRms, ''),
          Container(width: 1, height: 38, color: Colors.white24),
          const SizedBox(width: 10),
          tile('MDF', active ? _mdfLast.toStringAsFixed(1) : '—', _cMdf, 'Hz'),
        ],
      ),
    );
  }

  Widget _buildFatigueBanner() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
      decoration: BoxDecoration(
        color: Colors.red.shade800,
        border: Border.all(color: Colors.redAccent, width: 2),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.warning_amber_rounded,
            color: Colors.white,
            size: 28,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '🚨 근피로 감지 — 자극 자동 정지',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  'RMS slope +${_st.rmsSlope.toStringAsFixed(1)}%  |  MDF slope ${_st.mdfSlope.toStringAsFixed(1)}%',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---------- 파이프라인 다이어그램 ----------
  Widget _buildPipelineDiagram() {
    final running = _st.isRunning;
    final baselineReady = _st.baselineRms > 0;
    final sloping = _st.historyCount >= 30;
    final cond1 = _st.rmsSlope > _st.rmsThreshold;
    final cond2 = _st.mdfSlope < _st.mdfThreshold;
    final consec = _st.consecutive;

    Widget stage({
      required String label,
      required String value,
      required bool active,
      Color? activeColor,
    }) {
      final color = active
          ? (activeColor ?? Colors.indigoAccent)
          : Colors.white24;
      final bg = active ? color.withValues(alpha: 0.15) : Colors.white10;
      return Container(
        constraints: const BoxConstraints(minWidth: 78),
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
        decoration: BoxDecoration(
          color: bg,
          border: Border.all(color: color, width: active ? 1.5 : 1),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                color: active ? Colors.white : Colors.white54,
                fontSize: 10,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              value,
              style: TextStyle(
                color: color,
                fontSize: 13,
                fontWeight: FontWeight.bold,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      );
    }

    Widget arrow(bool active) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Icon(
        Icons.east,
        size: 16,
        color: active ? Colors.white70 : Colors.white24,
      ),
    );

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          stage(
            label: 'RAW EMG\nESP 1kHz',
            value: running ? '✓' : '—',
            active: running,
            activeColor: Colors.white70,
          ),
          arrow(running),
          stage(
            label: 'ENV (LPF)\n10Hz',
            value: running ? _envLast.toStringAsFixed(0) : '—',
            active: running,
            activeColor: _cEnv,
          ),
          arrow(running),
          stage(
            label: '1초 윈도우\nRMS / MDF',
            value: running
                ? '${_rmsLast.toStringAsFixed(0)} / ${_mdfLast.toStringAsFixed(0)}'
                : '—',
            active: running,
            activeColor: _cRms,
          ),
          arrow(running),
          stage(
            label: '60s 버퍼',
            value: '${_st.historyCount}/60',
            active: running && _st.historyCount > 0,
            activeColor: Colors.cyanAccent,
          ),
          arrow(sloping),
          stage(
            label: 'slope %\n(선형회귀)',
            value: sloping
                ? '${_st.rmsSlope >= 0 ? '+' : ''}${_st.rmsSlope.toStringAsFixed(0)} / ${_st.mdfSlope.toStringAsFixed(0)}'
                : '대기',
            active: sloping,
            activeColor: _cRmsSlope,
          ),
          arrow(sloping),
          stage(
            label: '이중 조건\nRMS↑ ∧ MDF↓',
            value: (cond1 && cond2) ? '✓ 만족' : '✗',
            active: sloping && (cond1 || cond2),
            activeColor: (cond1 && cond2) ? Colors.amberAccent : Colors.white24,
          ),
          arrow(_st.consecutive > 0),
          stage(
            label: '5× 카운터',
            value: '$consec/${_st.consecutiveTrigger}',
            active: _st.consecutive > 0,
            activeColor: consec >= _st.consecutiveTrigger
                ? Colors.red
                : Colors.orangeAccent,
          ),
          arrow(_st.fatigueDetected),
          stage(
            label: 'FATIGUE',
            value: _st.fatigueDetected ? '🚨 ON' : 'OFF',
            active: _st.fatigueDetected,
            activeColor: _cThr,
          ),
          arrow(_st.fatigueDetected),
          stage(
            label: 'FES 제어',
            value: _st.isStimulating ? 'STIM ON' : 'OFF',
            active: _st.isStimulating,
            activeColor: Colors.orange,
          ),
        ],
      ),
    );
  }

  // ---------- 일반 라인 차트 (ENV/RMS/MDF) ----------
  Widget _buildChart(
    String title,
    Queue<_Sample> q,
    Color color, {
    String? hint,
    List<double>? fixedRange,
    double? baselineY,
    double height = 160,
  }) {
    final spots = q.map((s) => FlSpot(s.t, s.value)).toList();
    double minX = 0, maxX = windowSec.toDouble();
    if (spots.isNotEmpty) {
      maxX = spots.last.x + 0.5;
      minX = maxX - windowSec;
    }
    double minY = 0, maxY = 1;
    if (fixedRange != null) {
      minY = fixedRange[0];
      maxY = fixedRange[1];
    } else if (spots.isNotEmpty) {
      final ys = spots.map((s) => s.y);
      final lo = ys.reduce((a, b) => a < b ? a : b);
      final hi = ys.reduce((a, b) => a > b ? a : b);
      final pad = ((hi - lo).abs() * 0.15).clamp(0.5, double.infinity);
      minY = lo - pad;
      maxY = hi + pad;
      if (baselineY != null) {
        if (baselineY < minY) minY = baselineY - pad;
        if (baselineY > maxY) maxY = baselineY + pad;
      }
    }

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 12, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
            if (hint != null) ...[
              const SizedBox(height: 2),
              Text(
                hint,
                style: const TextStyle(color: Colors.white54, fontSize: 10),
              ),
            ],
            const SizedBox(height: 4),
            SizedBox(
              height: height,
              child: spots.isEmpty
                  ? const Center(
                      child: Text(
                        '대기 중',
                        style: TextStyle(color: Colors.white38, fontSize: 11),
                      ),
                    )
                  : RepaintBoundary(
                      child: LineChart(
                        LineChartData(
                          minX: minX,
                          maxX: maxX,
                          minY: minY,
                          maxY: maxY,
                          gridData: const FlGridData(show: true),
                          titlesData: const FlTitlesData(
                            leftTitles: AxisTitles(
                              sideTitles: SideTitles(
                                showTitles: true,
                                reservedSize: 38,
                              ),
                            ),
                            bottomTitles: AxisTitles(
                              sideTitles: SideTitles(
                                showTitles: true,
                                reservedSize: 20,
                              ),
                            ),
                            topTitles: AxisTitles(
                              sideTitles: SideTitles(showTitles: false),
                            ),
                            rightTitles: AxisTitles(
                              sideTitles: SideTitles(showTitles: false),
                            ),
                          ),
                          borderData: FlBorderData(show: true),
                          extraLinesData: baselineY != null
                              ? ExtraLinesData(
                                  horizontalLines: [
                                    HorizontalLine(
                                      y: baselineY,
                                      color: Colors.white38,
                                      strokeWidth: 1,
                                      dashArray: [4, 4],
                                      label: HorizontalLineLabel(
                                        show: true,
                                        alignment: Alignment.topRight,
                                        style: const TextStyle(
                                          color: Colors.white54,
                                          fontSize: 9,
                                        ),
                                        labelResolver: (_) => 'baseline',
                                      ),
                                    ),
                                  ],
                                )
                              : const ExtraLinesData(),
                          lineBarsData: [
                            LineChartBarData(
                              spots: spots,
                              isCurved: false,
                              color: color,
                              barWidth: 1.5,
                              dotData: FlDotData(show: spots.length < 60),
                            ),
                          ],
                        ),
                        duration: Duration.zero,
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------- Slopes 차트 (RMS%, MDF% + 임계값 가로선) ----------
  Widget _buildSlopesChart() {
    final rsSpots = _rmsSlope.map((s) => FlSpot(s.t, s.value)).toList();
    final msSpots = _mdfSlope.map((s) => FlSpot(s.t, s.value)).toList();
    final all = [...rsSpots, ...msSpots];

    double minX = 0, maxX = windowSec.toDouble();
    if (all.isNotEmpty) {
      maxX = all.map((s) => s.x).reduce((a, b) => a > b ? a : b) + 0.5;
      minX = maxX - windowSec;
    }
    double minY = -30, maxY = 30;
    if (all.isNotEmpty) {
      final lo = all.map((s) => s.y).reduce((a, b) => a < b ? a : b);
      final hi = all.map((s) => s.y).reduce((a, b) => a > b ? a : b);
      minY = lo < -30 ? lo - 5 : -30;
      maxY = hi > 30 ? hi + 5 : 30;
    }

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 12, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _legendDot(_cRmsSlope, 'RMS slope %'),
                const SizedBox(width: 14),
                _legendDot(_cMdfSlope, 'MDF slope %'),
                const SizedBox(width: 14),
                _legendDot(_cThr, '임계값', dashed: true),
              ],
            ),
            const SizedBox(height: 2),
            const Text(
              '30초 선형회귀 변화율. 두 선이 동시에 각자 임계값 넘으면 → 피로 카운터 +1.',
              style: TextStyle(color: Colors.white54, fontSize: 10),
            ),
            const SizedBox(height: 4),
            SizedBox(
              height: 160,
              child: (rsSpots.isEmpty && msSpots.isEmpty)
                  ? const Center(
                      child: Text(
                        '대기 중 (30초치 모일 때까지)',
                        style: TextStyle(color: Colors.white38, fontSize: 11),
                      ),
                    )
                  : RepaintBoundary(
                      child: LineChart(
                      LineChartData(
                        minX: minX,
                        maxX: maxX,
                        minY: minY,
                        maxY: maxY,
                        gridData: const FlGridData(show: true),
                        titlesData: const FlTitlesData(
                          leftTitles: AxisTitles(
                            sideTitles: SideTitles(
                              showTitles: true,
                              reservedSize: 38,
                            ),
                          ),
                          bottomTitles: AxisTitles(
                            sideTitles: SideTitles(
                              showTitles: true,
                              reservedSize: 20,
                            ),
                          ),
                          topTitles: AxisTitles(
                            sideTitles: SideTitles(showTitles: false),
                          ),
                          rightTitles: AxisTitles(
                            sideTitles: SideTitles(showTitles: false),
                          ),
                        ),
                        borderData: FlBorderData(show: true),
                        extraLinesData: ExtraLinesData(
                          horizontalLines: [
                            HorizontalLine(
                              y: 0,
                              color: Colors.white24,
                              strokeWidth: 1,
                            ),
                            HorizontalLine(
                              y: _st.rmsThreshold,
                              color: _cThr.withValues(alpha: 0.7),
                              strokeWidth: 1.2,
                              dashArray: [5, 4],
                              label: HorizontalLineLabel(
                                show: true,
                                alignment: Alignment.topRight,
                                style: TextStyle(color: _cThr, fontSize: 9),
                                labelResolver: (_) =>
                                    'RMS thr +${_st.rmsThreshold.toStringAsFixed(0)}%',
                              ),
                            ),
                            HorizontalLine(
                              y: _st.mdfThreshold,
                              color: _cThr.withValues(alpha: 0.7),
                              strokeWidth: 1.2,
                              dashArray: [5, 4],
                              label: HorizontalLineLabel(
                                show: true,
                                alignment: Alignment.bottomRight,
                                style: TextStyle(color: _cThr, fontSize: 9),
                                labelResolver: (_) =>
                                    'MDF thr ${_st.mdfThreshold.toStringAsFixed(0)}%',
                              ),
                            ),
                          ],
                        ),
                        lineBarsData: [
                          LineChartBarData(
                            spots: rsSpots,
                            isCurved: false,
                            color: _cRmsSlope,
                            barWidth: 1.8,
                            dotData: const FlDotData(show: false),
                          ),
                          LineChartBarData(
                            spots: msSpots,
                            isCurved: false,
                            color: _cMdfSlope,
                            barWidth: 1.8,
                            dotData: const FlDotData(show: false),
                          ),
                        ],
                      ),
                      duration: Duration.zero,
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _legendDot(Color color, String label, {bool dashed = false}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 14,
          height: 3,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: const TextStyle(color: Colors.white70, fontSize: 10),
        ),
      ],
    );
  }

  // ---------- 피로 트리거 패널 ----------
  Widget _buildFatigueTriggerPanel() {
    final rs = _st.rmsSlope;
    final ms = _st.mdfSlope;
    final rt = _st.rmsThreshold;
    final mt = _st.mdfThreshold;

    // 진행률: 0 ~ 1
    final rsProgress = rt > 0 ? (rs / rt).clamp(0.0, 1.5) : 0.0;
    final msProgress = mt < 0 ? (ms / mt).clamp(0.0, 1.5) : 0.0;

    final cond1 = rs > rt;
    final cond2 = ms < mt;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 조건 1: RMS slope > +20%
            _condRow(
              label: 'RMS slope > +${rt.toStringAsFixed(0)}%',
              value: '${rs >= 0 ? '+' : ''}${rs.toStringAsFixed(1)}%',
              progress: rsProgress,
              met: cond1,
              color: _cRmsSlope,
            ),
            const SizedBox(height: 10),
            // 조건 2: MDF slope < -3%
            _condRow(
              label: 'MDF slope < ${mt.toStringAsFixed(0)}%',
              value: '${ms.toStringAsFixed(1)}%',
              progress: msProgress,
              met: cond2,
              color: _cMdfSlope,
            ),
            const Divider(height: 22, color: Colors.white24),
            // 연속 카운터
            Row(
              children: [
                const Expanded(
                  child: Text(
                    '연속 만족 카운트',
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                ),
                Text(
                  '${_st.consecutive} / ${_st.consecutiveTrigger}',
                  style: TextStyle(
                    color: _st.consecutive >= _st.consecutiveTrigger
                        ? _cThr
                        : Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(_st.consecutiveTrigger, (i) {
                final filled = i < _st.consecutive;
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: filled
                          ? (i + 1 == _st.consecutiveTrigger
                                ? _cThr
                                : Colors.orangeAccent)
                          : Colors.white10,
                      border: Border.all(
                        color: filled
                            ? (i + 1 == _st.consecutiveTrigger
                                  ? _cThr
                                  : Colors.orangeAccent)
                            : Colors.white24,
                      ),
                    ),
                  ),
                );
              }),
            ),
            const SizedBox(height: 6),
            Text(
              cond1 && cond2
                  ? (_st.consecutive >= _st.consecutiveTrigger
                        ? '✅ 트리거 발동 — FES 자동 정지'
                        : '⚠️ 두 조건 만족 — 카운터 누적 중')
                  : (cond1 || cond2 ? '한 조건만 만족 (피로 아님)' : '조건 미충족 — 안정'),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: cond1 && cond2
                    ? (_st.consecutive >= _st.consecutiveTrigger
                          ? _cThr
                          : Colors.amberAccent)
                    : Colors.white54,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _condRow({
    required String label,
    required String value,
    required double progress,
    required bool met,
    required Color color,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(
              met ? Icons.check_circle : Icons.radio_button_unchecked,
              size: 16,
              color: met ? color : Colors.white38,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: met ? Colors.white : Colors.white70,
                  fontSize: 12,
                ),
              ),
            ),
            Text(
              value,
              style: TextStyle(
                color: met ? color : Colors.white70,
                fontSize: 13,
                fontWeight: FontWeight.bold,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: Stack(
            children: [
              Container(height: 6, color: Colors.white10),
              FractionallySizedBox(
                widthFactor: (progress / 1.5).clamp(0.0, 1.0),
                child: Container(
                  height: 6,
                  color: met ? color : color.withValues(alpha: 0.4),
                ),
              ),
              // 임계값 마커 (66.7% 위치 = progress 1.0)
              Positioned(
                left: MediaQuery.of(context).size.width * 0.66 - 30,
                child: Container(width: 1.5, height: 6, color: _cThr),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ---------- 환자 프로파일 바 ----------
  Widget _buildProfileBar() {
    final profile = gProfileService.active;
    final list = gProfileService.all();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.indigo.withValues(alpha: 0.15),
        border: Border.all(color: Colors.indigoAccent.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          const Icon(Icons.person, size: 18, color: Colors.indigoAccent),
          const SizedBox(width: 8),
          Expanded(
            child: profile == null
                ? const Text(
                    '환자 프로파일 없음',
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Text(
                            profile.name,
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.indigoAccent.withValues(alpha: 0.3),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              '${profile.sessionCount} 세션',
                              style: const TextStyle(fontSize: 10),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        [
                          if (profile.mvcRms != null)
                            'MVC ${profile.mvcRms!.toStringAsFixed(0)}',
                          if (profile.restingRms != null)
                            'rest ${profile.restingRms!.toStringAsFixed(0)}',
                          if (profile.mdfBaseline != null)
                            'MDF baseline ${profile.mdfBaseline!.toStringAsFixed(0)}Hz',
                        ].join('  |  '),
                        style: const TextStyle(
                          color: Colors.white60,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
          ),
          PopupMenuButton<String>(
            icon: const Icon(
              Icons.expand_more,
              size: 20,
              color: Colors.white70,
            ),
            tooltip: '프로파일 전환/관리',
            onSelected: (v) async {
              if (v == '__new') {
                await _showCreateProfileDialog();
              } else if (v == '__delete' && profile != null) {
                await _showDeleteProfileDialog(profile.id);
              } else {
                await gProfileService.setActive(v);
                setState(() {});
              }
            },
            itemBuilder: (_) => [
              for (final p in list)
                PopupMenuItem(
                  value: p.id,
                  child: Row(
                    children: [
                      Icon(
                        p.id == profile?.id
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                        size: 16,
                        color: p.id == profile?.id
                            ? Colors.indigoAccent
                            : Colors.white54,
                      ),
                      const SizedBox(width: 8),
                      Text(p.name),
                    ],
                  ),
                ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: '__new',
                child: Row(
                  children: [
                    Icon(Icons.add, size: 16, color: Colors.greenAccent),
                    SizedBox(width: 8),
                    Text('+ 새 프로파일'),
                  ],
                ),
              ),
              if (profile != null && list.length > 1)
                const PopupMenuItem(
                  value: '__delete',
                  child: Row(
                    children: [
                      Icon(
                        Icons.delete_outline,
                        size: 16,
                        color: Colors.redAccent,
                      ),
                      SizedBox(width: 8),
                      Text('현재 프로파일 삭제'),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _showCreateProfileDialog() async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('새 프로파일'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '환자 이름 또는 ID',
            hintText: 'Subject B',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('생성'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    final id = 'subject_${DateTime.now().millisecondsSinceEpoch}';
    final p = UserProfile(id: id, name: name);
    await gProfileService.save(p);
    await gProfileService.setActive(id);
    if (mounted) setState(() {});
  }

  Future<void> _showDeleteProfileDialog(String id) async {
    final p = gProfileService.get(id);
    if (p == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('프로파일 삭제'),
        content: Text('${p.name}을(를) 삭제하시겠습니까? (세션 기록 ${p.sessionCount}회)'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await gProfileService.delete(id);
      if (mounted) setState(() {});
    }
  }

  // ---------- 수축 검출 패널 ----------
  Widget _buildContractionPanel() {
    String stateLabel(int s) {
      switch (s) {
        case 0:
          return '휴식 (REST)';
        case 1:
          return '시작 (ONSET)';
        case 2:
          return '지속 (SUSTAINED)';
        default:
          return '—';
      }
    }

    Color stateColor(int s) {
      switch (s) {
        case 1:
          return Colors.orangeAccent;
        case 2:
          return Colors.greenAccent;
        default:
          return Colors.white38;
      }
    }

    String typeLabel(String t) {
      switch (t) {
        case 'b':
          return 'BURST (<2s, 일시적)';
        case 't':
          return 'TRANSIENT (2~5s)';
        case 's':
          return 'SUSTAINED (≥5s, 분석 유효)';
        default:
          return '없음';
      }
    }

    Color typeColor(String t) {
      switch (t) {
        case 'b':
          return Colors.redAccent;
        case 't':
          return Colors.amberAccent;
        case 's':
          return Colors.greenAccent;
        default:
          return Colors.white38;
      }
    }

    final dur = (_st.contractDurMs / 1000).toStringAsFixed(1);
    final lastDur = (_st.lastContractDurMs / 1000).toStringAsFixed(1);
    final total = _st.burstCount + _st.transientCount + _st.sustainedCount;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 현재 상태
            Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: stateColor(_st.contractState),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '현재 상태',
                  style: const TextStyle(color: Colors.white60, fontSize: 11),
                ),
                const SizedBox(width: 8),
                Text(
                  stateLabel(_st.contractState),
                  style: TextStyle(
                    color: stateColor(_st.contractState),
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                if (_st.contractState != 0)
                  Text(
                    '${dur}s',
                    style: TextStyle(
                      color: stateColor(_st.contractState),
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
              ],
            ),
            const Divider(height: 18, color: Colors.white12),

            // 마지막 수축
            Row(
              children: [
                const Icon(Icons.history, size: 14, color: Colors.white54),
                const SizedBox(width: 6),
                const Text(
                  '마지막 수축',
                  style: TextStyle(color: Colors.white60, fontSize: 11),
                ),
                const SizedBox(width: 8),
                Text(
                  typeLabel(_st.lastContractType),
                  style: TextStyle(
                    color: typeColor(_st.lastContractType),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            if (_st.lastContractType != '-') ...[
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.only(left: 20),
                child: Text(
                  '지속 ${lastDur}s   |   peak RMS ${_st.lastContractPeak.toStringAsFixed(0)}',
                  style: const TextStyle(color: Colors.white54, fontSize: 11),
                ),
              ),
            ],
            const Divider(height: 18, color: Colors.white12),

            // 누적 카운터
            Row(
              children: [
                const Icon(Icons.bar_chart, size: 14, color: Colors.white54),
                const SizedBox(width: 6),
                const Text(
                  '세션 누적',
                  style: TextStyle(color: Colors.white60, fontSize: 11),
                ),
                const SizedBox(width: 8),
                Text(
                  '총 $total회',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            _contractionCountRow(
              'SUSTAINED',
              _st.sustainedCount,
              total,
              Colors.greenAccent,
              '분석에 유효',
            ),
            const SizedBox(height: 4),
            _contractionCountRow(
              'TRANSIENT',
              _st.transientCount,
              total,
              Colors.amberAccent,
              '경계, 주의',
            ),
            const SizedBox(height: 4),
            _contractionCountRow(
              'BURST',
              _st.burstCount,
              total,
              Colors.redAccent,
              '톱니파 원인 — 분석 제외 권장',
            ),
          ],
        ),
      ),
    );
  }

  Widget _contractionCountRow(
    String label,
    int count,
    int total,
    Color color,
    String hint,
  ) {
    final ratio = total > 0 ? count / total : 0.0;
    return Row(
      children: [
        SizedBox(
          width: 80,
          child: Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: Stack(
              children: [
                Container(height: 6, color: Colors.white10),
                FractionallySizedBox(
                  widthFactor: ratio.clamp(0.0, 1.0),
                  child: Container(height: 6, color: color),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 28,
          child: Text(
            '$count',
            textAlign: TextAlign.right,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            hint,
            style: const TextStyle(color: Colors.white38, fontSize: 9),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  // ---------- 컨트롤 버튼 ----------
  Widget _buildControls() {
    final canSend = _connState == 'connected';
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      alignment: WrapAlignment.center,
      children: [
        FilledButton.icon(
          onPressed: canSend ? _startSession : null,
          icon: const Icon(Icons.play_arrow),
          label: const Text('Start'),
        ),
        FilledButton.tonalIcon(
          onPressed: canSend ? _stopSession : null,
          icon: const Icon(Icons.stop),
          label: const Text('Stop'),
        ),
        OutlinedButton.icon(
          onPressed: canSend ? () => _send({'cmd': 'calibrate'}) : null,
          icon: const Icon(Icons.refresh),
          label: const Text('Calibrate'),
        ),
        OutlinedButton.icon(
          onPressed: canSend ? () => _sendMarker('easy') : null,
          icon: const Icon(Icons.flag_outlined),
          label: const Text('Easy'),
        ),
        OutlinedButton.icon(
          onPressed: canSend ? () => _sendMarker('medium') : null,
          icon: const Icon(Icons.flag_outlined),
          label: const Text('Medium'),
        ),
        OutlinedButton.icon(
          onPressed: canSend ? () => _sendMarker('hard') : null,
          icon: const Icon(Icons.flag),
          label: const Text('Hard'),
        ),
        FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: Colors.red),
          onPressed: canSend ? () => _send({'cmd': 'emergency'}) : null,
          icon: const Icon(Icons.warning),
          label: const Text('Emergency'),
        ),
      ],
    );
  }
}
