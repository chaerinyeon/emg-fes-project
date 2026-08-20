// RE:FIT v0.2 모니터 — M-wave 에포크 수신·기록 화면.
//
// 구화면(HomePage)의 ENV/RMS/MDF 차트는 여기 없다. v0.2 펌웨어는 그 지표를 보내지
// 않으며, 완전마비 대상에서는 RMS/MDF 가 유발반응에 오염돼 무효이기 때문이다.
// 여기서 보는 것은 R = M-wave 면적 ÷ 자극 스파이크 하나다.
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../core/refit_protocol.dart';
import '../services/profile_service.dart';
import '../services/refit_ble_service.dart';

class RefitMonitorScreen extends StatefulWidget {
  const RefitMonitorScreen({super.key});

  @override
  State<RefitMonitorScreen> createState() => _RefitMonitorScreenState();
}

class _RefitMonitorScreenState extends State<RefitMonitorScreen> {
  final _svc = RefitBleService();

  @override
  void initState() {
    super.initState();
    _svc.addListener(_onChange);
    _svc.init();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _svc.removeListener(_onChange);
    _svc.dispose();
    super.dispose();
  }

  void _toast(String msg, Color c) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: c,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _start() async {
    final p = gProfileService.active;
    final ok = await _svc.startSession(
      subjectId: p?.id,
      categoryTag: p?.category?.fileTag ?? 'unknown',
    );
    _toast(
      ok ? 'START 전송 — 기록만 시작(자극 안 켬)' : (_svc.lastError ?? 'START 실패'),
      ok ? Colors.green : Colors.red,
    );
  }

  Future<void> _stop() async {
    final ok = await _svc.stopSession();
    if (!ok) {
      _toast(_svc.lastError ?? 'STOP 실패', Colors.red);
      return;
    }
    final p = await _svc.saveCsv();
    _toast(p == null ? 'STOP — 저장할 데이터 없음' : 'CSV 저장: $p', Colors.green);
  }

  Future<void> _stim(bool on) async {
    final ok = on ? await _svc.enableStim() : await _svc.disableStim();
    _toast(
      ok
          ? (on ? 'STIM_ENABLE 전송' : 'STIM_DISABLE 전송')
          : (_svc.lastError ?? '전송 실패'),
      ok ? Colors.green : Colors.red,
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = _svc.status;
    return Scaffold(
      appBar: AppBar(
        title: const Text('RE:FIT 모니터  ·  v0.2'),
        actions: [
          IconButton(
            tooltip: '연결',
            onPressed: _svc.isConnected ? _svc.disconnect : _svc.scanAndConnect,
            icon: Icon(
              _svc.isConnected ? Icons.bluetooth_connected : Icons.bluetooth,
              color: _svc.isConnected ? Colors.green : Colors.black45,
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          _connCard(),
          const SizedBox(height: 12),
          _controlCard(),
          const SizedBox(height: 12),
          _statsCard(s),
          const SizedBox(height: 12),
          _chartCard(),
          const SizedBox(height: 12),
          _epochCard(),
        ],
      ),
    );
  }

  // ---------- 연결 ----------
  Widget _connCard() {
    final label = switch (_svc.conn) {
      RefitConn.idle => '대기 — 우측 상단 아이콘으로 연결',
      RefitConn.unsupported => 'BLE 미지원',
      RefitConn.scanning => '스캔 중…',
      RefitConn.connecting => '연결 중…',
      RefitConn.connected => '연결됨 · ${_svc.deviceLabel}',
      RefitConn.disconnected => '끊김',
      RefitConn.error => '오류',
    };
    final color = switch (_svc.conn) {
      RefitConn.connected => Colors.green.shade700,
      RefitConn.error || RefitConn.unsupported => Colors.red.shade700,
      _ => Colors.black54,
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.circle, size: 10, color: color),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(color: color, fontWeight: FontWeight.w600),
                  ),
                ),
                if (_svc.conn == RefitConn.idle ||
                    _svc.conn == RefitConn.error ||
                    _svc.conn == RefitConn.disconnected)
                  FilledButton(
                    onPressed: _svc.scanAndConnect,
                    child: const Text('Connect'),
                  ),
              ],
            ),
            if (_svc.lastError != null) ...[
              const SizedBox(height: 6),
              Text(
                _svc.lastError!,
                style: const TextStyle(color: Colors.red, fontSize: 11),
              ),
            ],
            if (_svc.lastEvent != null) ...[
              const SizedBox(height: 6),
              Text(
                '최근 이벤트: ${_svc.lastEvent}',
                style: const TextStyle(color: Colors.black45, fontSize: 11),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ---------- 세션/자극 제어 ----------
  Widget _controlCard() {
    final on = _svc.isConnected;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: on && !_svc.sessionActive ? _start : null,
                    icon: const Icon(Icons.play_arrow, size: 18),
                    label: const Text('기록 시작'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: on && _svc.sessionActive ? _stop : null,
                    icon: const Icon(Icons.stop, size: 18),
                    label: const Text('정지 · 저장'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: on && _svc.sessionActive && !_svc.stimOn
                        ? () => _stim(true)
                        : null,
                    child: const Text('자극 투입'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.red.shade700,
                    ),
                    onPressed: on && _svc.stimOn ? () => _stim(false) : null,
                    child: const Text('자극 차단'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              '기록 시작은 자극을 켜지 않는다. 마사지기 전원·세기는 사람이 직접 조작하며, '
              '앱의 「자극 투입」은 릴레이 배선이 끝난 뒤에만 실제로 동작한다.',
              style: TextStyle(color: Colors.black45, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }

  // ---------- 상태/통계 ----------
  Widget _statsCard(StatusMsg? s) {
    final drift = _svc.driftMs;
    final driftBad = drift.abs() > 200;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Wrap(
          spacing: 20,
          runSpacing: 12,
          children: [
            _stat('MCU', s?.stateName ?? '—'),
            _stat('세기', s == null ? '—' : '${s.level}/${s.maxLevel}'),
            _stat('자극', s == null ? '—' : (s.stimOn ? 'ON' : 'off')),
            _stat('fs', s == null ? '—' : '${s.sampleRate}Hz'),
            _stat('에포크', '${_svc.epochCount}'),
            _stat(
              '유실',
              '${_svc.droppedEpochs}',
              color: _svc.droppedEpochs > 0 ? Colors.orange.shade800 : null,
            ),
            _stat(
              '포화',
              _svc.epochCount == 0
                  ? '—'
                  : '${_svc.saturatedEpochs} '
                        '(${(100 * _svc.saturatedEpochs / _svc.epochCount).round()}%)',
              color: _svc.saturatedEpochs > 0 ? Colors.red.shade700 : null,
            ),
            _stat(
              'drift',
              '${drift.toStringAsFixed(0)}ms',
              color: driftBad ? Colors.red.shade700 : null,
            ),
            if (s != null && s.healthFlags.isNotEmpty)
              _stat(
                'health',
                s.healthFlags.join(','),
                color: Colors.red.shade700,
              ),
            if (_svc.csvPath != null) _stat('CSV', '저장 중', color: Colors.green),
          ],
        ),
      ),
    );
  }

  Widget _stat(String label, String value, {Color? color}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: const TextStyle(color: Colors.black38, fontSize: 10),
        ),
        Text(
          value,
          style: TextStyle(
            color: color ?? Colors.black87,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  // ---------- R 추세 ----------
  Widget _chartCard() {
    final h = _svc.rHistory;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'R = M-wave 면적 ÷ 자극 스파이크',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
            const Text(
              '전극 드리프트는 분자·분모를 함께 움직여 상쇄된다. 내려가면 피로 방향.',
              style: TextStyle(color: Colors.black45, fontSize: 11),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 180,
              child: h.length < 2
                  ? const Center(
                      child: Text(
                        '에포크 대기 중 — 기록을 시작하고 자극기를 켜세요',
                        style: TextStyle(color: Colors.black38, fontSize: 12),
                      ),
                    )
                  : LineChart(
                      LineChartData(
                        gridData: const FlGridData(show: true),
                        titlesData: const FlTitlesData(
                          topTitles: AxisTitles(),
                          rightTitles: AxisTitles(),
                        ),
                        borderData: FlBorderData(show: false),
                        lineBarsData: [
                          LineChartBarData(
                            spots: [
                              for (var i = 0; i < h.length; i++)
                                FlSpot(i.toDouble(), h[i]),
                            ],
                            isCurved: false,
                            barWidth: 1.6,
                            color: const Color(0xFF2E7D32),
                            dotData: const FlDotData(show: false),
                          ),
                        ],
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------- 최근 에포크 파형 ----------
  Widget _epochCard() {
    final ep = _svc.lastEpoch;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '최근 에포크 (+2 ~ +15ms)',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            if (ep == null)
              const Text(
                '아직 수신 없음',
                style: TextStyle(color: Colors.black38, fontSize: 12),
              )
            else ...[
              Text(
                'stim#${ep.stimIndex}  @${ep.tMs}ms  s#${ep.sampleIndex}\n'
                'spike=${ep.spike}  p2p=${ep.p2p}  area=${ep.area}  '
                'R=${ep.r.toStringAsFixed(2)}  ${ep.valid ? "valid" : "INVALID"}',
                style: const TextStyle(fontSize: 11, height: 1.5),
              ),
              if (ep.saturated) ...[
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.red.shade50,
                    border: Border.all(color: Colors.red.shade200),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '포화 — ${[
                      if (ep.spikeSaturated) '스파이크',
                      if (ep.windowSaturated) 'M-wave 창',
                    ].join(' · ')}가 ADC 레일에 닿았다.\n'
                    '${ep.spikeSaturated ? "분모가 상수가 되어 R 정규화가 무력화된다. " : ""}'
                    'MyoWare 게인을 낮추거나 전극을 다시 잡아야 한다.',
                    style: TextStyle(
                      fontSize: 10.5,
                      height: 1.4,
                      color: Colors.red.shade900,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 10),
              SizedBox(
                height: 110,
                child: LineChart(
                  LineChartData(
                    gridData: const FlGridData(show: false),
                    titlesData: const FlTitlesData(show: false),
                    borderData: FlBorderData(show: false),
                    lineBarsData: [
                      LineChartBarData(
                        spots: [
                          for (var i = 0; i < ep.samples.length; i++)
                            FlSpot(i.toDouble(), ep.samples[i].toDouble()),
                        ],
                        isCurved: false,
                        barWidth: 1.8,
                        color: const Color(0xFF1976D2),
                        dotData: const FlDotData(show: true),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
