import 'dart:collection';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../core/models.dart';
import '../services/session_controller.dart';
import '../services/simulator_service.dart';
import '../widgets/controls/controls.dart';
import '../widgets/controls/massager_control.dart';
import '../widgets/measurement/measurement_request_dialog.dart';

/// 데스크탑/태블릿용 와이드 모니터 화면 (다크 테마).
/// SessionController(시뮬레이터/BLE) 를 구독해 ENV/RMS/MDF 와 컨트롤을 보여준다.
class MonitorScreen extends StatefulWidget {
  const MonitorScreen({super.key});
  @override
  State<MonitorScreen> createState() => _MonitorScreenState();
}

class _MonitorScreenState extends State<MonitorScreen> {
  late final SessionController _c;

  // 다크 팔레트
  static const _bg = Color(0xFF0E1116);
  static const _panel = Color(0xFF171B22);
  static const _panelBorder = Color(0xFF262C36);

  @override
  void initState() {
    super.initState();
    _c = SessionController();
    _c.onMeasureRequest = (prompt, dur) {
      if (mounted) {
        showMeasurementRequestDialog(context, prompt: prompt, durationMs: dur);
      }
    };
    _c.onFatigue = () {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('근피로 감지 — 계속 진행 중 (정지는 STOP)'),
          backgroundColor: Colors.redAccent,
        ),
      );
    };
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Future<void> _pickScenarioAndStart() async {
    final scenario = await showDialog<SimScenario>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('시뮬레이터 시나리오'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, SimScenario.continuousFatigue),
            child: const ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.trending_down, color: Colors.redAccent),
              title: Text('연속 자연 피로 → 알림만 (자동 정지 안 함)'),
              subtitle: Text('자발 수축 → FES 두드림 지속 → ~3분 후 피로 검출'),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, SimScenario.clinical),
            child: const ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.repeat),
              title: Text('임상 프로토콜 (3사이클)'),
              subtitle: Text('baseline → 자극 → 측정 팝업 3회 후 피로 검출'),
            ),
          ),
        ],
      ),
    );
    if (scenario != null) _c.startSimulator(scenario);
  }

  @override
  Widget build(BuildContext context) {
    final dark = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF4CAF50),
        brightness: Brightness.dark,
      ).copyWith(surface: _panel, surfaceTint: Colors.transparent),
      scaffoldBackgroundColor: _bg,
    );
    return Theme(
      data: dark,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) => Scaffold(
          backgroundColor: _bg,
          appBar: AppBar(
            backgroundColor: _bg,
            surfaceTintColor: Colors.transparent,
            title: const Text(
              'EMG-FES Monitor',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            centerTitle: true,
          ),
          body: SafeArea(
            child: Column(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 1400),
                        child: _content(),
                      ),
                    ),
                  ),
                ),
                _bottomBar(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ----------------------------------------------------------------
  Widget _content() {
    final connected = _c.connState == 'connected';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _connectionBar(connected),
        const SizedBox(height: 12),
        _statusBanner(),
        const SizedBox(height: 12),
        _readouts(),
        const SizedBox(height: 12),
        _panelBox(
          child: _MonitorChart(
            title: 'EMG envelope',
            queue: _c.env,
            color: cEnv,
            height: 200,
          ),
        ),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, cons) {
            final rmsChart = _panelBox(
              child: _MonitorChart(
                title: 'RMS (근활성도)',
                queue: _c.rms,
                color: cRms,
                height: 180,
                centerY: _c.st.rmsCcMean,
                upperLimitY: _c.st.rmsCcUcl,
              ),
            );
            final mdfChart = _panelBox(
              child: _MonitorChart(
                title: 'MDF (근피로 주파수)',
                queue: _c.mdf,
                color: cMdf,
                height: 180,
                centerY: _c.st.mdfCcMean,
                lowerLimitY: _c.st.mdfCcLcl,
              ),
            );
            if (cons.maxWidth < 720) {
              return Column(children: [
                rmsChart,
                const SizedBox(height: 12),
                mdfChart,
              ]);
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: rmsChart),
                const SizedBox(width: 12),
                Expanded(child: mdfChart),
              ],
            );
          },
        ),
        if (_c.st.engineFatigueDetected || _c.st.fatigueDetected) ...[
          const SizedBox(height: 12),
          _fatigueBanner(),
        ],
      ],
    );
  }

  // 연결 바: 기기명 + 상태칩 + hist/slope + 버튼
  Widget _connectionBar(bool connected) {
    return _panelBox(
      child: Row(
        children: [
          Icon(
            connected ? Icons.link : Icons.link_off,
            color: connected ? Colors.greenAccent : Colors.white38,
            size: 20,
          ),
          const SizedBox(width: 8),
          Text(
            connected
                ? (_c.deviceLabel.isNotEmpty ? _c.deviceLabel : 'CONNECTED')
                : '연결 안 됨',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 12),
          if (connected) ...[
            _chip('hist ${_c.st.historyCount}'),
            const SizedBox(width: 6),
            _chip('rms_slope ${_c.st.rmsSlope.toStringAsFixed(1)}%'),
          ],
          if (_c.lastError != null) ...[
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                _c.lastError!,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.redAccent, fontSize: 11),
              ),
            ),
          ],
          const Spacer(),
          if (connected)
            OutlinedButton.icon(
              onPressed: _c.disconnect,
              icon: const Icon(Icons.close, size: 18),
              label: const Text('연결 해제'),
            )
          else ...[
            OutlinedButton.icon(
              onPressed: _c.connState == 'scanning' ? null : _c.scanAndConnect,
              icon: const Icon(Icons.bluetooth_searching, size: 18),
              label: Text(_c.connState == 'scanning' ? '스캔 중…' : 'BLE 연결'),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: _pickScenarioAndStart,
              icon: const Icon(Icons.science_outlined, size: 18),
              label: const Text('시뮬레이터'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _statusBanner() {
    final s = _c.st;
    final (label, sub, color) = switch (s.muscleState) {
      'fatigue' => ('근피로 감지', '계속 진행 중 — 정지는 STOP', Colors.redAccent),
      'high' => ('활성 높음', '', Colors.orangeAccent),
      'low' => ('활성 낮음', '', Colors.blueAccent),
      'normal' => ('정상', '운동 진행 중', Colors.greenAccent),
      'calibrating' => ('보정 중', 'baseline 학습', Colors.amberAccent),
      _ => ('대기', 'Start 누르면 측정 시작', Colors.white54),
    };
    return _panelBox(
      child: Row(
        children: [
          Icon(Icons.power_settings_new, color: color, size: 30),
          const SizedBox(width: 14),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
              if (sub.isNotEmpty)
                Text(sub, style: const TextStyle(color: Colors.white54)),
            ],
          ),
          const Spacer(),
          Text(
            s.baselineRms > 0
                ? 'baseline ${s.baselineRms.toStringAsFixed(1)}'
                : 'baseline —',
            style: const TextStyle(color: Colors.white54),
          ),
        ],
      ),
    );
  }

  Widget _readouts() {
    final s = _c.st;
    return Row(
      children: [
        Expanded(child: _readoutTile('ENV', _c.envLast.toStringAsFixed(0), cEnv)),
        const SizedBox(width: 12),
        Expanded(child: _readoutTile('RMS', _c.rmsLast.toStringAsFixed(1), cRms)),
        const SizedBox(width: 12),
        Expanded(child: _readoutTile('MDF', _c.mdfLast.toStringAsFixed(1), cMdf)),
        const SizedBox(width: 12),
        Expanded(
          child: _readoutTile(
            '연속',
            '${s.engineConsecutive}/${s.consecutiveTrigger}',
            Colors.purpleAccent,
          ),
        ),
      ],
    );
  }

  Widget _readoutTile(String label, String value, Color color) {
    return _panelBox(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: Colors.white54, fontSize: 12)),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              fontSize: 30,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _fatigueBanner() {
    final s = _c.st;
    return _panelBox(
      child: Row(
        children: [
          const Icon(Icons.warning_amber, color: Colors.redAccent),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '근피로 검출 — RMS ${s.rmsSlope.toStringAsFixed(1)}% · '
                  'MDF ${s.mdfSlope.toStringAsFixed(1)}%',
                  style: const TextStyle(
                    color: Colors.redAccent,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (s.engineReasons.isNotEmpty)
                  Text(
                    s.engineReasons.join(' · '),
                    style: const TextStyle(color: Colors.white54, fontSize: 11),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _bottomBar() {
    final canSend = _c.connState == 'connected';
    return Container(
      decoration: const BoxDecoration(
        color: _panel,
        border: Border(top: BorderSide(color: _panelBorder)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          MassagerControl(
            canSend: canSend,
            onUp: _c.massagerUp,
            onDown: _c.massagerDown,
            level: _c.massagerLevel,
          ),
          const SizedBox(height: 10),
          ControlsBar(
            canSend: canSend,
            // 연결과 무관하게 세션 중이면 Stop 가능 — 저장이 Stop 에 달려 있다.
            canStop: _c.isRunning,
            onStart: _c.startSession,
            onStop: _c.stopSession,
            onCalibrate: _c.calibrate,
            onMarker: _c.marker,
            onEmergency: _c.emergency,
          ),
        ],
      ),
    );
  }

  // ----- 공통 패널/칩 -----
  Widget _panelBox({
    required Widget child,
    EdgeInsets padding = const EdgeInsets.all(14),
  }) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _panelBorder),
      ),
      child: child,
    );
  }

  Widget _chip(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.white10,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(text, style: const TextStyle(fontSize: 11, color: Colors.white70)),
    );
  }
}

// ============================================================
// 다크용 라인 차트
// ============================================================
class _MonitorChart extends StatelessWidget {
  final String title;
  final Queue<Sample> queue;
  final Color color;
  final double height;
  final double? centerY;
  final double? upperLimitY;
  final double? lowerLimitY;

  const _MonitorChart({
    required this.title,
    required this.queue,
    required this.color,
    this.height = 180,
    this.centerY,
    this.upperLimitY,
    this.lowerLimitY,
  });

  @override
  Widget build(BuildContext context) {
    final spots = queue.map((s) => FlSpot(s.t, s.value)).toList();
    double minX = 0, maxX = kWindowSec.toDouble();
    if (spots.isNotEmpty) {
      maxX = spots.last.x + 0.5;
      minX = maxX - kWindowSec;
    }
    double minY = 0, maxY = 1;
    if (spots.isNotEmpty) {
      final ys = spots.map((s) => s.y);
      final lo = ys.reduce((a, b) => a < b ? a : b);
      final hi = ys.reduce((a, b) => a > b ? a : b);
      final pad = ((hi - lo).abs() * 0.15).clamp(0.5, double.infinity);
      minY = lo - pad;
      maxY = hi + pad;
      for (final v in [centerY, upperLimitY, lowerLimitY]) {
        if (v == null) continue;
        if (v < minY) minY = v - pad;
        if (v > maxY) maxY = v + pad;
      }
    }

    HorizontalLine limit(double y, Color c, String label) => HorizontalLine(
          y: y,
          color: c,
          strokeWidth: 1,
          dashArray: const [4, 4],
          label: HorizontalLineLabel(
            show: true,
            alignment: Alignment.topRight,
            style: TextStyle(color: c, fontSize: 9),
            labelResolver: (_) => label,
          ),
        );
    final lines = <HorizontalLine>[
      if (centerY != null) limit(centerY!, Colors.tealAccent, 'mean'),
      if (upperLimitY != null) limit(upperLimitY!, Colors.redAccent, 'UCL'),
      if (lowerLimitY != null) limit(lowerLimitY!, Colors.redAccent, 'LCL'),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(width: 8, height: 8, color: color),
            const SizedBox(width: 6),
            Text(title,
                style: const TextStyle(
                    fontWeight: FontWeight.w600, fontSize: 13)),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: height,
          child: spots.isEmpty
              ? const Center(
                  child: Text('대기 중',
                      style: TextStyle(color: Colors.white24, fontSize: 12)),
                )
              : RepaintBoundary(
                  child: LineChart(
                    LineChartData(
                      minX: minX,
                      maxX: maxX,
                      minY: minY,
                      maxY: maxY,
                      gridData: FlGridData(
                        show: true,
                        getDrawingHorizontalLine: (_) =>
                            const FlLine(color: Color(0xFF222831), strokeWidth: 1),
                        getDrawingVerticalLine: (_) =>
                            const FlLine(color: Color(0xFF222831), strokeWidth: 1),
                      ),
                      titlesData: const FlTitlesData(
                        leftTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 40,
                            getTitlesWidget: _leftTitle,
                          ),
                        ),
                        bottomTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 22,
                            getTitlesWidget: _bottomTitle,
                          ),
                        ),
                        topTitles:
                            AxisTitles(sideTitles: SideTitles(showTitles: false)),
                        rightTitles:
                            AxisTitles(sideTitles: SideTitles(showTitles: false)),
                      ),
                      borderData: FlBorderData(
                        show: true,
                        border: Border.all(color: const Color(0xFF2A313C)),
                      ),
                      extraLinesData: ExtraLinesData(horizontalLines: lines),
                      lineBarsData: [
                        LineChartBarData(
                          spots: spots,
                          isCurved: false,
                          color: color,
                          barWidth: 1.6,
                          dotData: const FlDotData(show: false),
                        ),
                      ],
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  static Widget _leftTitle(double v, TitleMeta meta) {
    if (v == meta.min || v == meta.max) return const SizedBox.shrink();
    return Text(v.toStringAsFixed(0),
        style: const TextStyle(color: Colors.white38, fontSize: 10));
  }

  static Widget _bottomTitle(double v, TitleMeta meta) {
    return Text(v.toStringAsFixed(0),
        style: const TextStyle(color: Colors.white38, fontSize: 10));
  }
}
