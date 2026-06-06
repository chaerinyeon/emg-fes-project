import 'dart:async';

import 'package:flutter/services.dart' show rootBundle;

/// 번들된 CSV 를 읽어 펌웨어 BLE 패킷처럼 재생하는 시뮬레이터.
///
/// CSV 컬럼은 앱 메시지 short-key 와 동일(ms→ts 로 매핑). 값이 빈 칸이면 해당
/// 키는 메시지에 넣지 않는다. rms/mdf 는 1Hz 행에만 채워져 있어, 그대로
/// home_page 의 [FatigueEngine] 1Hz 판정 경로를 타고 RMS/MDF 로 피로가 검출된다.
class CsvReplayService {
  CsvReplayService({
    required this.onMessage,
    this.asset = 'assets/sim/fatigue_rmsmdf.csv',
    this.tickMs = 100,
  });

  final void Function(Map<String, dynamic>) onMessage;
  final String asset;
  final int tickMs;

  Timer? _timer;
  List<Map<String, dynamic>> _frames = const [];
  int _i = 0;
  bool _loading = false;

  bool get isRunning => _timer != null;

  // 키별 타입 변환
  static const _intKeys = {'hc', 'cc', 'ct', 'mwn', 'req_dur'};
  static const _doubleKeys = {
    'env', 'rms', 'mdf', 'rs', 'b', 'rr', 'mwa', 'mwc', 'mwl',
  };
  static const _boolKeys = {'run', 'stim', 'fd', 'req_end'};

  Future<void> _ensureLoaded() async {
    if (_frames.isNotEmpty || _loading) return;
    _loading = true;
    try {
      final raw = await rootBundle.loadString(asset);
      final lines = raw
          .split('\n')
          .map((l) => l.trimRight())
          .where((l) => l.isNotEmpty)
          .toList();
      if (lines.isEmpty) return;
      final header = lines.first.split(',');
      final frames = <Map<String, dynamic>>[];
      for (var r = 1; r < lines.length; r++) {
        final cells = lines[r].split(',');
        final msg = <String, dynamic>{};
        for (var c = 0; c < header.length && c < cells.length; c++) {
          final col = header[c].trim();
          final v = cells[c].trim();
          if (v.isEmpty) continue;
          final key = col == 'ms' ? 'ts' : col;
          if (col == 'ms' || _intKeys.contains(key)) {
            msg[key] = int.tryParse(v) ?? num.tryParse(v)?.toInt();
          } else if (_doubleKeys.contains(key)) {
            msg[key] = double.tryParse(v);
          } else if (_boolKeys.contains(key)) {
            msg[key] = v.toLowerCase() == 'true';
          } else {
            msg[key] = v; // st, mk, req 등 문자열
          }
        }
        if (msg.isNotEmpty) frames.add(msg);
      }
      _frames = frames;
    } finally {
      _loading = false;
    }
  }

  /// 토글 켤 때 호출 — 에셋 미리 로드만(재생은 'start' 명령에서).
  void start() {
    _ensureLoaded();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _i = 0;
  }

  /// home_page._send 가 시뮬레이터 활성 상태에서 호출.
  Future<void> handleCommand(Map<String, dynamic> cmd) async {
    switch (cmd['cmd'] as String? ?? '') {
      case 'start':
        await _ensureLoaded();
        _i = 0;
        _timer?.cancel();
        _timer = Timer.periodic(Duration(milliseconds: tickMs), (_) => _emit());
        break;
      case 'stop':
      case 'emergency':
        _timer?.cancel();
        _timer = null;
        // 정지 패킷 — 차트/상태가 멈춤을 인지하도록.
        onMessage({'ts': _lastTs + tickMs, 'run': false, 'stim': false});
        break;
      // calibrate/marker/set_thresholds 등은 재생 모드에서 무시
    }
  }

  int _lastTs = 0;

  void _emit() {
    if (_i >= _frames.length) {
      // 재생 끝 — 마지막 상태 유지하며 정지.
      _timer?.cancel();
      _timer = null;
      return;
    }
    final frame = _frames[_i++];
    final ts = frame['ts'];
    if (ts is int) _lastTs = ts;
    onMessage(frame);
  }
}
