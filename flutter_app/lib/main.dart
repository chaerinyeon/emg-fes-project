import 'dart:async';
import 'dart:convert';
import 'dart:collection';
import 'dart:html' as html;

import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as ws_status;

void main() => runApp(const EmgFesApp());

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

class _Sample {
  final double t;
  final double value;
  _Sample(this.t, this.value);
}

class _Status {
  bool isRunning = false;
  bool isStimulating = false;
  bool fatigueDetected = false;
  double rmsSlope = 0;
  int historyCount = 0;
  double baselineRms = 0;
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const int windowSec = 60;
  static const int maxPoints = windowSec;

  final TextEditingController _hostCtrl =
      TextEditingController(text: 'emg-fes.local:81');

  WebSocketChannel? _ch;
  StreamSubscription? _sub;
  bool _connecting = false;
  String _connState = 'disconnected';
  String? _lastError;

  final Queue<_Sample> _env = Queue();
  final Queue<_Sample> _rms = Queue();
  double _t0 = 0;
  double _rawLast = 0;
  double _rmsLast = 0;
  final _Status _st = _Status();

  final List<Map<String, dynamic>> _log = [];
  String? _pendingMarker;

  void _push(Queue<_Sample> q, _Sample s) {
    q.add(s);
    while (q.length > maxPoints) {
      q.removeFirst();
    }
  }

  Future<void> _connect() async {
    if (_connecting) return;
    setState(() {
      _connecting = true;
      _connState = 'connecting';
      _lastError = null;
    });
    try {
      final host = _hostCtrl.text.trim();
      final uri = Uri.parse('ws://$host');
      final ch = WebSocketChannel.connect(uri);
      await ch.ready;
      _ch = ch;
      _sub = ch.stream.listen(
        _onMessage,
        onError: (e) {
          setState(() {
            _connState = 'error';
            _lastError = '$e';
          });
        },
        onDone: () {
          setState(() {
            _connState = 'disconnected';
          });
        },
      );
      setState(() {
        _connState = 'connected';
        _connecting = false;
      });
    } catch (e) {
      setState(() {
        _connState = 'error';
        _lastError = '$e';
        _connecting = false;
      });
    }
  }

  void _disconnect() {
    _sub?.cancel();
    _ch?.sink.close(ws_status.normalClosure);
    _sub = null;
    _ch = null;
    _env.clear();
    _rms.clear();
    _t0 = 0;
    _rawLast = 0;
    _rmsLast = 0;
    setState(() {
      _connState = 'disconnected';
    });
  }

  void _onMessage(dynamic raw) {
    try {
      final msg = jsonDecode(raw as String) as Map<String, dynamic>;
      if (msg['type'] != 'data') return;

      final ts = (msg['timestamp_ms'] as num).toDouble() / 1000.0;
      if (_env.isEmpty || ts < _t0) {
        _t0 = ts;
        _env.clear();
        _rms.clear();
      }
      final t = ts - _t0;

      _st.baselineRms =
          (msg['baseline_rms'] as num?)?.toDouble() ?? _st.baselineRms;

      final running = msg['is_running'] as bool? ?? _st.isRunning;
      if (!running && _st.isRunning) {
        _env.clear();
        _rms.clear();
        _rawLast = 0;
        _rmsLast = 0;
      }

      if (running) {
        final envVal = msg['emg_env'] ?? msg['emg_raw'];
        if (envVal != null) {
          final e = (envVal as num).toDouble();
          _rawLast = e;
          _push(_env, _Sample(t, e));
        }
        if (msg['rms'] != null) {
          final r = (msg['rms'] as num).toDouble();
          final adj = (r - _st.baselineRms).clamp(0.0, double.infinity);
          _rmsLast = adj;
          _push(_rms, _Sample(t, adj));
        }

        _log.add({
          'wall_time': DateTime.now().toIso8601String(),
          'timestamp_ms': msg['timestamp_ms'],
          'emg_raw': msg['emg_raw'],
          'emg_env': msg['emg_env'],
          'rms': msg['rms'],
          'mdf': msg['mdf'],
          'rms_slope': msg['rms_slope'],
          'mdf_slope': msg['mdf_slope'],
          'fatigue_detected': msg['fatigue_detected'],
          'is_running': msg['is_running'],
          'is_stimulating': msg['is_stimulating'],
          'history_count': msg['history_count'],
          'baseline_rms': msg['baseline_rms'],
          'marker': _pendingMarker ?? '',
        });
        _pendingMarker = null;
      }

      final wasFatigued = _st.fatigueDetected;
      _st.isRunning = running;
      _st.isStimulating = msg['is_stimulating'] ?? _st.isStimulating;
      _st.fatigueDetected = msg['fatigue_detected'] ?? _st.fatigueDetected;
      _st.rmsSlope = (msg['rms_slope'] as num?)?.toDouble() ?? _st.rmsSlope;
      _st.historyCount =
          (msg['history_count'] as num?)?.toInt() ?? _st.historyCount;

      if (!wasFatigued && _st.fatigueDetected) {
        _onFatigueDetected();
      }

      setState(() {});
    } catch (_) {
      // ignore parse errors
    }
  }

  void _onFatigueDetected() {
    final ctx = context;
    if (!mounted) return;
    final rms = _st.rmsSlope.toStringAsFixed(1);
    showDialog<void>(
      context: ctx,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        backgroundColor: Colors.red.shade900,
        icon: const Icon(Icons.warning_amber_rounded,
            size: 56, color: Colors.white),
        title: const Text(
          '근피로 감지!',
          textAlign: TextAlign.center,
          style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 22),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'RMS slope  +$rms%',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 16),
            ),
            const SizedBox(height: 8),
            const Text(
              '자극이 자동으로 정지되었습니다.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ],
        ),
        actions: [
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.white),
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('확인',
                style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    ScaffoldMessenger.of(ctx).showSnackBar(
      SnackBar(
        backgroundColor: Colors.red.shade700,
        duration: const Duration(seconds: 4),
        content: Text(
          '🚨 근피로 감지 — RMS +$rms%',
          style: const TextStyle(
              color: Colors.white, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  void _send(Map<String, dynamic> cmd) {
    final ch = _ch;
    if (ch == null) {
      _toast('연결 안 됨 — 먼저 Connect 하세요', Colors.orange);
      return;
    }
    try {
      ch.sink.add(jsonEncode(cmd));
      _toast('→ ${cmd['cmd']}${cmd['label'] != null ? ': ${cmd['label']}' : ''}',
          Colors.green);
    } catch (e) {
      _toast('전송 실패: $e', Colors.red);
    }
  }

  void _startSession() {
    _log.clear();
    _pendingMarker = null;
    _send({'cmd': 'start'});
  }

  void _stopSession() {
    _send({'cmd': 'stop'});
    if (_log.isEmpty) {
      _toast('저장할 데이터 없음', Colors.orange);
      return;
    }
    _downloadCsv();
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
      'is_running',
      'is_stimulating',
      'history_count',
      'baseline_rms',
      'marker',
    ];
    final sb = StringBuffer()..writeln(headers.join(','));
    for (final row in _log) {
      sb.writeln(headers.map((k) {
        final v = row[k];
        if (v == null) return '';
        final s = v.toString();
        return s.contains(',') ? '"$s"' : s;
      }).join(','));
    }
    final csv = sb.toString();
    final bytes = utf8.encode(csv);
    final blob = html.Blob([bytes], 'text/csv');
    final url = html.Url.createObjectUrlFromBlob(blob);
    final now = DateTime.now();
    final stamp =
        '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}'
        '_${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}';
    html.AnchorElement(href: url)
      ..setAttribute('download', 'emg_$stamp.csv')
      ..click();
    html.Url.revokeObjectUrl(url);
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

  @override
  void dispose() {
    _disconnect();
    _hostCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('EMG-FES Monitor'),
        actions: [
          IconButton(
            tooltip: _connState == 'connected' ? 'Disconnect' : 'Connect',
            icon: Icon(
              _connState == 'connected' ? Icons.link : Icons.link_off,
              color: _connState == 'connected' ? Colors.greenAccent : null,
            ),
            onPressed:
                _connState == 'connected' ? _disconnect : _connect,
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildHostBar(),
              const SizedBox(height: 8),
              _buildStatusBar(),
              if (_lastError != null) ...[
                const SizedBox(height: 4),
                Text(
                  _lastError!,
                  style: const TextStyle(color: Colors.redAccent, fontSize: 11),
                ),
              ],
              const SizedBox(height: 8),
              _buildLiveReadout(),
              if (_st.fatigueDetected) ...[
                const SizedBox(height: 8),
                _buildFatigueBanner(),
              ],
              const SizedBox(height: 12),
              Expanded(
                child: Column(
                  children: [
                    Expanded(
                      child: _buildChart('EMG envelope', _env,
                          Colors.lightBlueAccent,
                          fixedRange: const [0, 4095]),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: _buildChart('RMS', _rms, Colors.lightGreenAccent),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              _buildControls(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHostBar() {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _hostCtrl,
            enabled: _connState != 'connected',
            decoration: const InputDecoration(
              labelText: 'host:port',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ),
        const SizedBox(width: 8),
        FilledButton(
          onPressed: _connState == 'connected'
              ? _disconnect
              : (_connecting ? null : _connect),
          child: Text(_connState == 'connected' ? 'Disconnect' : 'Connect'),
        ),
      ],
    );
  }

  Widget _buildStatusBar() {
    final chips = <Widget>[
      _chip(_connState.toUpperCase(),
          _connState == 'connected' ? Colors.green : Colors.grey),
      if (_st.isRunning) _chip('RUN', Colors.indigo),
      if (_st.isStimulating) _chip('STIM', Colors.orange),
      if (_st.fatigueDetected) _chip('FATIGUE', Colors.red),
      _chip('hist ${_st.historyCount}', Colors.blueGrey),
      _chip('rms_slope ${_st.rmsSlope.toStringAsFixed(1)}%', Colors.blueGrey),
    ];
    return Wrap(spacing: 6, runSpacing: 6, children: chips);
  }

  Widget _buildLiveReadout() {
    final active = _connState == 'connected' && _st.isRunning;
    final rawTxt = active ? _rawLast.toStringAsFixed(0) : '—';
    final rmsTxt = active ? _rmsLast.toStringAsFixed(1) : '—';
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        border: Border.all(color: Colors.white24),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('ENV',
                    style: TextStyle(color: Colors.white60, fontSize: 12)),
                Text(
                  rawTxt,
                  style: const TextStyle(
                    color: Colors.lightBlueAccent,
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
          Container(
            width: 1,
            height: 44,
            color: Colors.white24,
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('RMS',
                    style: TextStyle(color: Colors.white60, fontSize: 12)),
                Text(
                  rmsTxt,
                  style: const TextStyle(
                    color: Colors.lightGreenAccent,
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFatigueBanner() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
      decoration: BoxDecoration(
        color: Colors.red.shade800,
        border: Border.all(color: Colors.redAccent, width: 2),
        borderRadius: BorderRadius.circular(10),
        boxShadow: [
          BoxShadow(
            color: Colors.red.withValues(alpha: 0.4),
            blurRadius: 12,
            spreadRadius: 1,
          ),
        ],
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded,
              color: Colors.white, size: 32),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '🚨 근피로 감지됨 — 자극 자동 정지',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'RMS slope +${_st.rmsSlope.toStringAsFixed(1)}%',
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ],
            ),
          ),
        ],
      ),
    );
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

  Widget _buildChart(String title, Queue<_Sample> q, Color color,
      {List<double>? fixedRange}) {
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
    }
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 12, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Expanded(
              child: spots.isEmpty
                  ? const Center(
                      child: Text(
                        '대기 중',
                        style: TextStyle(color: Colors.white38, fontSize: 12),
                      ),
                    )
                  : LineChart(
                      LineChartData(
                        minX: minX,
                        maxX: maxX,
                        minY: minY,
                        maxY: maxY,
                        gridData: const FlGridData(show: true),
                        titlesData: const FlTitlesData(
                          leftTitles: AxisTitles(
                              sideTitles: SideTitles(
                                  showTitles: true, reservedSize: 40)),
                          bottomTitles: AxisTitles(
                              sideTitles: SideTitles(
                                  showTitles: true, reservedSize: 22)),
                          topTitles: AxisTitles(
                              sideTitles: SideTitles(showTitles: false)),
                          rightTitles: AxisTitles(
                              sideTitles: SideTitles(showTitles: false)),
                        ),
                        borderData: FlBorderData(show: true),
                        lineBarsData: [
                          LineChartBarData(
                            spots: spots,
                            isCurved: false,
                            color: color,
                            barWidth: 1.5,
                            dotData: FlDotData(
                              show: spots.length < 80,
                              getDotPainter: (s, p, b, i) =>
                                  FlDotCirclePainter(
                                radius: 2,
                                color: color,
                                strokeWidth: 0,
                              ),
                            ),
                          ),
                        ],
                      ),
                      duration: Duration.zero,
                    ),
            ),
          ],
        ),
      ),
    );
  }

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
