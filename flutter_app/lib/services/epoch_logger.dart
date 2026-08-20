// M-wave 에포크 CSV 레코더 (프로토콜 v0.2).
//
// 한 행 = 자극 1회. 남기는 것:
//   (a) 에포크 원표본과 면적      — 사후에 오프라인 분석기로 재검증하려면 원표본이 있어야 한다
//   (b) 자극 스파이크 진폭        — R = 면적÷스파이크 정규화의 분모
//   (c) 폰이 계산한 값(R·drift)   — 실시간 판정이 무엇을 보고 있었는지
//   (d) MCU 가 보고한 상태·세기   — 명령이 실제로 반영됐는지 사후 대조
//
// drift_ms 를 남기는 이유: 샘플 인덱스로 만든 시간축과 벽시계가 어긋나면 그 세션의
// 시간축은 실제보다 압축돼 있다. 이 열이 없으면 사후에 그걸 알아낼 방법이 없다.
import 'csv_save_stub.dart' if (dart.library.html) 'csv_save_web.dart';

class EpochLogRecorder {
  final List<int> _tRel = []; // 세션 t0 기준 경과(ms)
  final List<int> _stimIdx = [];
  final List<int> _sampleIdx = [];
  final List<double> _drift = [];
  final List<int> _spike = [];
  final List<int> _p2p = [];
  final List<int> _area = [];
  final List<double> _r = [];
  final List<int> _valid = [];
  final List<int> _satWin = [];
  final List<int> _satSpike = [];
  final List<String> _state = [];
  final List<int> _level = [];
  final List<String> _marker = [];
  final List<String> _samples = [];

  bool _recording = false;
  String? _filename;
  String? _path;
  int _flushed = 0;
  // flush 직렬화용 체인. 두 flush 가 겹치면 커서를 둘 다 낡은 값으로 읽어
  // 같은 구간을 두 번 쓰거나(중복) 같은 오프셋에 겹쳐 쓴다(덮어쓰기).
  // 실측: 2026-08-20 두 세션의 CSV 끝에서 각각 49행·37행이 통째로 중복됐다.
  Future<void> _chain = Future<void>.value();

  bool get isRecording => _recording;
  /// 디스크에 이미 쓴 행 수. flush 는 이 커서를 **await 전에** 옮긴다.
  int get flushedRows => _flushed;
  bool get isEmpty => _tRel.isEmpty;
  int get length => _tRel.length;
  String? get path => _path;

  void start({String filenameTag = 'unknown'}) {
    for (final l in [
      _tRel,
      _stimIdx,
      _sampleIdx,
      _spike,
      _p2p,
      _area,
      _valid,
      _satWin,
      _satSpike,
      _level,
    ]) {
      l.clear();
    }
    _drift.clear();
    _r.clear();
    _state.clear();
    _marker.clear();
    _samples.clear();
    _flushed = 0;
    _path = null;
    _filename = 'epoch_${_stamp()}_$filenameTag.csv';
    _recording = true;
  }

  void stop() => _recording = false;

  static String _stamp() {
    final now = DateTime.now();
    String p2(int n) => n.toString().padLeft(2, '0');
    return '${now.year}${p2(now.month)}${p2(now.day)}'
        '_${p2(now.hour)}${p2(now.minute)}${p2(now.second)}';
  }

  void add({
    required int tRelMs,
    required int stimIndex,
    required int sampleIndex,
    required double driftMs,
    required int spike,
    required int p2p,
    required int area,
    required double r,
    required bool valid,
    required bool satWindow,
    required bool satSpike,
    required String mcuState,
    required int level,
    required List<int> samples,
    String marker = '',
  }) {
    if (!_recording) return;
    _tRel.add(tRelMs);
    _stimIdx.add(stimIndex);
    _sampleIdx.add(sampleIndex);
    _drift.add(driftMs);
    _spike.add(spike);
    _p2p.add(p2p);
    _area.add(area);
    _r.add(r);
    _valid.add(valid ? 1 : 0);
    _satWin.add(satWindow ? 1 : 0);
    _satSpike.add(satSpike ? 1 : 0);
    _state.add(mcuState);
    _level.add(level);
    _marker.add(marker);
    // 표본은 세미콜론 결합 — n 이 바뀌어도(4kHz 전환 등) 열 개수가 흔들리지 않는다.
    _samples.add(samples.join(';'));
  }

  // Sat_Win / Sat_Spike: 그 에폭이 ADC 레일에 닿았는지. 1 이면 값이 잘려 있어
  // 면적·R 을 물리량으로 못 쓴다. 사후 분석에서 이 행을 걸러내는 데 쓴다.
  static const String _header =
      'Time_ms,Stim_Index,Sample_Index,Drift_ms,Spike,P2P,Area,R,Valid,'
      'Sat_Win,Sat_Spike,MCU_State,Level,Marker,Samples\n';

  String _rowsFrom(int from) {
    final sb = StringBuffer();
    for (var i = from; i < _tRel.length; i++) {
      sb.writeln(
        '${_tRel[i]},'
        '${_stimIdx[i]},'
        '${_sampleIdx[i]},'
        '${_drift[i].toStringAsFixed(1)},'
        '${_spike[i]},'
        '${_p2p[i]},'
        '${_area[i]},'
        '${_r[i].toStringAsFixed(4)},'
        '${_valid[i]},'
        '${_satWin[i]},'
        '${_satSpike[i]},'
        '${_state[i]},'
        '${_level[i]},'
        '${_marker[i]},'
        '${_samples[i]}',
      );
    }
    return sb.toString();
  }

  String toCsv() => _header + _rowsFrom(0);

  /// 세션 도중 호출 — 아직 안 쓴 행만 파일 끝에 이어붙인다.
  /// 앱이 죽거나 BLE 가 끊겨도 여기까지는 디스크에 남는다.
  /// 세션 종료 시 주기 타이머·SESSION_STOP·BLE 끊김·save 가 동시에 부를 수 있다.
  /// 커서 선점과 행 스냅샷은 **동기로** 끝내고(→ 두 flush 가 같은 구간을 볼 수 없다),
  /// 실제 파일 쓰기만 체인으로 직렬화한다(→ 블록 순서가 뒤집히지 않는다).
  Future<String?> flush({String? subjectId}) {
    if (_filename == null || _tRel.isEmpty) return Future<String?>.value(null);
    final from = _flushed;
    final upTo = _tRel.length; // 쓰는 동안 add() 가 들어와도 커서가 앞서지 않게 고정
    if (from >= upTo) return Future<String?>.value(_path);
    _flushed = upTo;
    final rows = _rowsFrom(from);
    final done = _chain.then((_) => _write(from, upTo, rows, subjectId));
    _chain = done.then((_) {}, onError: (_) {});
    return done;
  }

  Future<String?> _write(
    int from,
    int upTo,
    String rows,
    String? subjectId,
  ) async {
    final p = await appendCsvFile(
      _filename!,
      _header,
      rows,
      subjectId: subjectId,
    );
    if (p == null) {
      // 실패 — 뒤이은 flush 가 이미 더 멀리 예약했다면 되돌리지 않는다(그 구간은
      // save() 의 전문 쓰기로 회수된다). 단독 실패면 커서를 되돌려 재시도한다.
      if (_flushed == upTo) _flushed = from;
      return null;
    }
    _path = p;
    return _path;
  }

  Future<String?> save({String? subjectId}) async {
    if (isEmpty) return null;
    final flushed = await flush(subjectId: subjectId);
    if (flushed != null) return flushed;
    return saveCsvFile(
      _filename ?? 'epoch_${_stamp()}.csv',
      toCsv(),
      subjectId: subjectId,
    );
  }
}
