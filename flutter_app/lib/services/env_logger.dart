// FES 코스(약 5분) 동안 BLE로 수신한 ENV(Envelope) 샘플을 전량 누적하는 레코더.
// 기존 _log(1Hz 다운샘플)와 달리 펌웨어 송신 주기(100ms, 10Hz) 그대로 기록해
// 엑셀 시계열 분석용 고해상도 CSV(Time(ms),ENV_Value,...)를 만든다.
// RMS/MDF(10Hz)는 매 샘플마다 들어온다. M-wave(검출 시)는 이벤트성이라
// 각 행에는 그 시점까지 수신된 "가장 최근" 값을 동봉한다(zero-order hold).
import 'csv_save_stub.dart' if (dart.library.html) 'csv_save_web.dart';

class EnvLogRecorder {
  final List<int> _timesMs = [];
  final List<double> _envValues = [];
  final List<double> _raw = []; // 100ms 평균 ADC 원값 (펌웨어 raw, 10Hz)
  final List<double> _rms = []; // RMS (10Hz 갱신)
  final List<double> _mdf = []; // MDF (10Hz 갱신)
  final List<double> _mwAmp = []; // 최근 M-wave 진폭 (검출 시 갱신)
  final List<double> _mwArea = []; // 최근 M-wave 면적
  final List<double> _mwLatency = []; // 최근 M-wave 잠복기
  final List<int> _mwValid = []; // 최근 M-wave 검출 신뢰도(1/0) — 실패값 마스킹용
  final List<String> _markers = []; // 'easy'/'medium'/'hard' 등, 보통은 ''
  bool _recording = false;

  // --- 주기적 flush 상태 ---
  // 파일명은 세션 시작 시 확정한다(예전엔 save() 시점에 만들었다). 세션 도중에도
  // 같은 파일에 이어써야 하므로, 이름이 중간에 바뀌면 조각난 파일이 생긴다.
  String? _filename;
  String? _path; // 마지막으로 성공한 저장 경로
  int _flushed = 0; // 디스크에 이미 쓴 행 수 (다음 flush 의 시작 인덱스)

  bool get isRecording => _recording;
  bool get isEmpty => _timesMs.isEmpty;
  int get length => _timesMs.length;

  /// 세션 시작 — 이전 데이터를 비우고 기록 시작.
  void start() {
    _timesMs.clear();
    _envValues.clear();
    _raw.clear();
    _rms.clear();
    _mdf.clear();
    _mwAmp.clear();
    _mwArea.clear();
    _mwLatency.clear();
    _mwValid.clear();
    _markers.clear();
    _flushed = 0;
    _path = null;
    _filename = 'env_${_stamp()}.csv';
    _recording = true;
  }

  /// 세션 종료 — 기록 중단 (데이터는 save 전까지 유지).
  void stop() => _recording = false;

  static String _stamp() {
    final now = DateTime.now();
    String p2(int n) => n.toString().padLeft(2, '0');
    return '${now.year}${p2(now.month)}${p2(now.day)}'
        '_${p2(now.hour)}${p2(now.minute)}${p2(now.second)}';
  }

  /// BLE 메시지 1건 기록. [timeMs]는 펌웨어 millis() 타임스탬프.
  /// [marker]는 그 시점에 누른 체감 강도 버튼(easy/medium/hard) 라벨.
  /// [raw]는 100ms 평균 ADC 원값. [rms]/[mdf]/[mwAmp]/[mwArea]/[mwLatency]는 그 시점의 최근 값(없으면 0).
  void add(
    int timeMs,
    double env, {
    String marker = '',
    double raw = 0,
    double rms = 0,
    double mdf = 0,
    double mwAmp = 0,
    double mwArea = 0,
    double mwLatency = 0,
    bool mwValid = false,
  }) {
    if (!_recording) return;
    _timesMs.add(timeMs);
    _envValues.add(env);
    _raw.add(raw);
    _rms.add(rms);
    _mdf.add(mdf);
    _mwAmp.add(mwAmp);
    _mwArea.add(mwArea);
    _mwLatency.add(mwLatency);
    _mwValid.add(mwValid ? 1 : 0);
    _markers.add(marker);
  }

  static const String _header =
      'Time(ms),Raw_ADC,ENV_Value,RMS,MDF,MW_Amp,MW_Area,MW_Latency,MW_Valid,Marker\n';

  /// [from] 번째 행부터 끝까지를 CSV 행 문자열로. Time 은 세션 첫 샘플 기준
  /// 상대 경과시간(ms) — t0 는 세션 내내 고정이라 이어써도 연속이 유지된다.
  String _rowsFrom(int from) {
    final sb = StringBuffer();
    final t0 = _timesMs.isEmpty ? 0 : _timesMs.first;
    for (var i = from; i < _timesMs.length; i++) {
      sb.writeln('${_timesMs[i] - t0},'
          '${_raw[i].toStringAsFixed(1)},'
          '${_envValues[i].toStringAsFixed(1)},'
          '${_rms[i].toStringAsFixed(1)},'
          '${_mdf[i].toStringAsFixed(1)},'
          '${_mwAmp[i].toStringAsFixed(1)},'
          '${_mwArea[i].toStringAsFixed(1)},'
          '${_mwLatency[i].toStringAsFixed(1)},'
          '${_mwValid[i]},'
          '${_markers[i]}');
    }
    return sb.toString();
  }

  /// `Time(ms),Raw_ADC,ENV_Value,RMS,MDF,MW_Amp,MW_Area,MW_Latency,MW_Valid,Marker` 헤더의 CSV 전문.
  /// MW_Valid: 그 시점 최근 M-wave 검출의 신뢰도(1=유효,0=실패/무효). 실패 검출값 마스킹용.
  String toCsv() => _header + _rowsFrom(0);

  /// 세션 도중 호출 — 아직 디스크에 안 쓴 행만 파일 끝에 이어붙인다.
  /// 앱이 죽어도 여기까지는 남는다. 반환값: 저장 경로(웹/실패 시 null).
  Future<String?> flush({String? subjectId}) async {
    if (_filename == null || _timesMs.isEmpty) return null;
    if (_flushed >= _timesMs.length) return _path; // 새 데이터 없음
    final upTo = _timesMs.length; // 쓰는 동안 add() 가 더 들어와도 커서가 앞서지 않게 고정
    final rows = _rowsFrom(_flushed);
    final p =
        await appendCsvFile(_filename!, _header, rows, subjectId: subjectId);
    if (p == null) return null; // 웹이거나 쓰기 실패 — 커서를 그대로 둬 다음에 재시도
    _path = p;
    _flushed = upTo;
    return _path;
  }

  /// CSV 저장 — 모바일: 앱 문서 `data/<subjectId>/env_<stamp>.csv`,
  /// 웹: 브라우저 다운로드. 반환값: 저장 경로(또는 파일명), 실패/빈 데이터 시 null.
  /// 네이티브에선 남은 행만 이어쓰고, append 가 불가능한 웹에선 전문을 다운로드한다.
  Future<String?> save({String? subjectId}) async {
    if (isEmpty) return null;
    final flushed = await flush(subjectId: subjectId);
    if (flushed != null) return flushed;
    return saveCsvFile(_filename ?? 'env_${_stamp()}.csv', toCsv(),
        subjectId: subjectId);
  }
}
