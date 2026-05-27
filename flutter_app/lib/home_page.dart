import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'constants.dart';
import 'csv_exporter.dart';
import 'csv_save_stub.dart' if (dart.library.html) 'csv_save_web.dart';
import 'models.dart';
import 'profile_service.dart';
import 'widgets/ble_bar.dart';
import 'widgets/chart_card.dart';
import 'widgets/contraction_panel.dart';
import 'widgets/controls.dart';
import 'widgets/fatigue_banner.dart';
import 'widgets/fatigue_dialog.dart';
import 'widgets/fatigue_trigger_panel.dart';
import 'widgets/live_readout.dart';
import 'widgets/pipeline_diagram.dart';
import 'widgets/profile_bar.dart';
import 'widgets/section_title.dart';
import 'widgets/slopes_chart.dart';
import 'widgets/status_bar.dart';

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
  StreamSubscription<BluetoothConnectionState>? _connSub;
  StreamSubscription<List<ScanResult>>? _scanSub;
  bool _scanning = false;
  String _connState =
      'disconnected'; // disconnected / scanning / connecting / connected / error
  String? _lastError;

  // 시계열 (60초 윈도우)
  final Queue<Sample> _env = Queue();
  final Queue<Sample> _rms = Queue();
  final Queue<Sample> _mdf = Queue();
  final Queue<Sample> _rmsSlope = Queue();
  final Queue<Sample> _mdfSlope = Queue();
  double _t0 = 0;
  bool _t0Init = false; // _t0가 첫 메시지에서 설정됐는지
  double _envLast = 0;
  double _rmsLast = 0;
  double _mdfLast = 0;
  double _lastEnvPushT = -1.0; // ENV push의 마지막 t (시간 기반 데시메이션)
  final AppStatus _st = AppStatus();

  // CSV 로깅 (web만) — 1Hz로 다운샘플 (10Hz BLE 중 초당 1번만 기록)
  final List<Map<String, dynamic>> _log = [];
  String? _pendingMarker;
  int? _lastLoggedSec;

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
      if (!running && _st.isRunning) {
        _env.clear();
        _rms.clear();
        _mdf.clear();
        _rmsSlope.clear();
        _mdfSlope.clear();
        _envLast = 0;
        _rmsLast = 0;
        _mdfLast = 0;
        _lastEnvPushT = -1.0;
      }
      // 세션이 새로 시작되면 로그/데시 추적도 리셋
      if (running && !_st.isRunning) {
        _lastLoggedSec = null;
        _lastEnvPushT = -1.0;
      }

      if (running) {
        final envVal = msg['env'] ?? msg['raw'];
        if (envVal != null) {
          final e = (envVal as num).toDouble();
          _envLast = e;
          // 시간 기반 5Hz 데시메이션 — 토글보다 hot reload/누락에 강건
          if (_lastEnvPushT < 0 || (t - _lastEnvPushT) >= kEnvPushIntervalSec) {
            _lastEnvPushT = t;
            _push(_env, Sample(t, e), maxLen: kMaxEnvPoints);
          }
        }
        if (msg['rms'] != null) {
          final r = (msg['rms'] as num).toDouble();
          _rmsLast = r;
          _push(_rms, Sample(t, r));
        }
        if (msg['mdf'] != null) {
          final m = (msg['mdf'] as num).toDouble();
          _mdfLast = m;
          _push(_mdf, Sample(t, m));
        }
        if (msg['rs'] != null) {
          _push(_rmsSlope, Sample(t, (msg['rs'] as num).toDouble()));
        }
        if (msg['ms'] != null) {
          _push(_mdfSlope, Sample(t, (msg['ms'] as num).toDouble()));
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
        showFatigueDialog(
          context,
          rmsSlope: _st.rmsSlope,
          mdfSlope: _st.mdfSlope,
          fesWasOn: wasStimulating,
        );
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
      final filename = downloadCsv(_log);
      _toast('CSV 저장: $filename (${_log.length} rows)', Colors.green);
    } else {
      _toast('세션 기록됨 (모바일 CSV 저장은 PC 로거 사용)', Colors.green);
    }
  }

  void _sendMarker(String label) {
    _pendingMarker = label;
    _send({'cmd': 'marker', 'label': label});
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

  // ============================================================
  // 빌드
  // ============================================================
  @override
  Widget build(BuildContext context) {
    final canSend = _connState == 'connected';
    final active = _connState == 'connected' && _st.isRunning;
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
                onDisconnect: _disconnect,
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
              const SizedBox(height: 10),
              LiveReadout(
                active: active,
                envLast: _envLast,
                rmsLast: _rmsLast,
                mdfLast: _mdfLast,
              ),
              if (_st.fatigueDetected) ...[
                const SizedBox(height: 8),
                FatigueBanner(
                  rmsSlope: _st.rmsSlope,
                  mdfSlope: _st.mdfSlope,
                ),
              ],

              const SizedBox(height: 14),
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
                hint: '√(Σ(raw-mean)²/N) — 1초 윈도우. 피로 시 ↑ 또는 환자가 힘 더 줘도 ↑.',
                baselineY: _st.baselineRms > 0 ? _st.baselineRms : null,
                height: 140,
              ),
              const SizedBox(height: 6),
              ChartCard(
                title: 'MDF (근피로 주파수)',
                queue: _mdf,
                color: cMdf,
                hint: 'FFT 파워 중앙 주파수 (Hz). 피로 시 ↓ (저주파로 left-shift).',
                height: 140,
              ),
              const SizedBox(height: 6),
              SlopesChart(
                rmsSlopeQueue: _rmsSlope,
                mdfSlopeQueue: _mdfSlope,
                rmsThreshold: _st.rmsThreshold,
                mdfThreshold: _st.mdfThreshold,
              ),

              const SizedBox(height: 14),
              const SectionTitle('④ 피로 트리거 (이중 조건 + 연속 카운터)'),
              const SizedBox(height: 6),
              FatigueTriggerPanel(status: _st),

              const SizedBox(height: 18),
              ControlsBar(
                canSend: canSend,
                onStart: _startSession,
                onStop: _stopSession,
                onCalibrate: () => _send({'cmd': 'calibrate'}),
                onMarker: _sendMarker,
                onEmergency: () => _send({'cmd': 'emergency'}),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}
