// M-wave 에포크 CSV 레코더 (프로토콜 v0.2).
//
// 한 행 = 자극 1회. 남기는 것:
//   (a) 에포크 원표본과 면적      — 사후에 오프라인 분석기로 재검증하려면 원표본이 있어야 한다
//   (b) 자극 스파이크 진폭        — R = 면적÷스파이크 정규화의 분모
//   (c) 기준·추세                 — CL0·σ0·phase·느린추세 S·CL_down·CL_stop
//   (d) 두 트랙 상태               — down/stop 여유(σ 단위)·warn_active·danger_active
//   (f) 폰이 내린 명령             — cmd_action·target_level·seq·reliability
//   (e) MCU 가 보고한 상태·세기    — 명령이 실제로 반영됐는지 사후 대조
//
// (c)(d) 가 없으면 폐루프를 사후에 재검증할 수 없다. "왜 그때 DOWN 이 나갔나"를
// 답하려면 판정 근거(ref·σ)와 명령이 같은 행에 있어야 한다(사양서 11장).
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
  // (c) 기준·추세 — 그 에폭 시점의 최신 버스트 스냅샷 (Hybrid C)
  final List<double> _cl0 = [];
  final List<double> _sigma0 = [];
  final List<int> _phase = [];
  final List<double> _slowS = [];
  final List<double> _clDown = [];
  final List<double> _clStop = [];
  // (d) 두 트랙 상태
  final List<double> _downMargin = [];
  final List<double> _stopMargin = [];
  final List<int> _warnAct = [];
  final List<int> _dangerAct = [];
  final List<int> _reliab = [];
  // (d) 명령
  final List<String> _cmdAction = [];
  final List<int> _cmdTarget = [];
  final List<int> _cmdSeq = [];
  // (e) MCU 실제
  final List<int> _stimOn = [];

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
      _phase,
      _warnAct,
      _dangerAct,
      _reliab,
      _cmdTarget,
      _cmdSeq,
      _stimOn,
    ]) {
      l.clear();
    }
    for (final l in [
      _drift,
      _r,
      _cl0,
      _sigma0,
      _slowS,
      _clDown,
      _clStop,
      _downMargin,
      _stopMargin,
    ]) {
      l.clear();
    }
    _cmdAction.clear();
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
    // (c) 기준·추세 · (d) 트랙 상태 · (f) 명령 — 코어가 아직 안 돌면 기본값이 들어간다.
    double cl0 = 0,
    double sigma0 = 0,
    int phase = 0,
    double slowTrendS = 0,
    double clDown = 0,
    double clStop = 0,
    double downMarginSigma = double.nan,
    double stopMarginSigma = double.nan,
    bool warnActive = false,
    bool dangerActive = false,
    int reliability = 0,
    String cmdAction = 'HOLD',
    int cmdTargetLevel = 0,
    int cmdSeq = 0,
    bool stimOn = false,
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
    _cl0.add(cl0);
    _sigma0.add(sigma0);
    _phase.add(phase);
    _slowS.add(slowTrendS);
    _clDown.add(clDown);
    _clStop.add(clStop);
    _downMargin.add(downMarginSigma);
    _stopMargin.add(stopMarginSigma);
    _warnAct.add(warnActive ? 1 : 0);
    _dangerAct.add(dangerActive ? 1 : 0);
    _reliab.add(reliability);
    _cmdAction.add(cmdAction);
    _cmdTarget.add(cmdTargetLevel);
    _cmdSeq.add(cmdSeq);
    _stimOn.add(stimOn ? 1 : 0);
  }

  // Sat_Win / Sat_Spike: 그 에폭이 ADC 레일에 닿았는지. 1 이면 값이 잘려 있어
  // 면적·R 을 물리량으로 못 쓴다. 사후 분석에서 이 행을 걸러내는 데 쓴다.
  static const String _header =
      'Time_ms,Stim_Index,Sample_Index,Drift_ms,Spike,P2P,Area,R,Valid,'
      'Sat_Win,Sat_Spike,MCU_State,Level,Stim_On,'
      'CL0,Sigma0,Phase,Slow_Trend_S,CL_Down,CL_Stop,'
      'Down_Margin_Sigma,Stop_Margin_Sigma,Warn_Active,Danger_Active,'
      'Reliability,Cmd_Action,Cmd_Target_Level,Cmd_Seq,Marker,Samples\n';

  /// NaN 은 빈 칸으로 — pandas 가 그대로 NaN 으로 읽는다. 'NaN' 문자열이 들어가면
  /// 열 dtype 이 object 가 돼 사후 분석에서 조용히 계산이 깨진다.
  static String _f(double v, int digits) =>
      v.isFinite ? v.toStringAsFixed(digits) : '';

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
        '${_stimOn[i]},'
        '${_f(_cl0[i], 1)},'
        '${_f(_sigma0[i], 1)},'
        '${_phase[i]},'
        '${_f(_slowS[i], 1)},'
        '${_f(_clDown[i], 1)},'
        '${_f(_clStop[i], 1)},'
        '${_f(_downMargin[i], 2)},'
        '${_f(_stopMargin[i], 2)},'
        '${_warnAct[i]},'
        '${_dangerAct[i]},'
        '${_reliab[i]},'
        '${_cmdAction[i]},'
        '${_cmdTarget[i]},'
        '${_cmdSeq[i]},'
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
