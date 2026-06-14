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
  final List<String> _markers = []; // 'easy'/'medium'/'hard' 등, 보통은 ''
  bool _recording = false;

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
    _markers.clear();
    _recording = true;
  }

  /// 세션 종료 — 기록 중단 (데이터는 save 전까지 유지).
  void stop() => _recording = false;

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
    _markers.add(marker);
  }

  /// `Time(ms),Raw_ADC,ENV_Value,RMS,MDF,MW_Amp,MW_Area,MW_Latency,Marker` 헤더의 CSV 문자열 생성.
  /// Time은 세션 첫 샘플 기준 상대 경과시간(ms)으로 변환해 0부터 시작.
  String toCsv() {
    final sb = StringBuffer()
      ..writeln(
          'Time(ms),Raw_ADC,ENV_Value,RMS,MDF,MW_Amp,MW_Area,MW_Latency,Marker');
    final t0 = _timesMs.isEmpty ? 0 : _timesMs.first;
    for (var i = 0; i < _timesMs.length; i++) {
      sb.writeln('${_timesMs[i] - t0},'
          '${_raw[i].toStringAsFixed(1)},'
          '${_envValues[i].toStringAsFixed(1)},'
          '${_rms[i].toStringAsFixed(1)},'
          '${_mdf[i].toStringAsFixed(1)},'
          '${_mwAmp[i].toStringAsFixed(1)},'
          '${_mwArea[i].toStringAsFixed(1)},'
          '${_mwLatency[i].toStringAsFixed(1)},'
          '${_markers[i]}');
    }
    return sb.toString();
  }

  /// CSV 저장 — 모바일: 앱 문서 `data/<subjectId>/env_<stamp>.csv`,
  /// 웹: 브라우저 다운로드. 반환값: 저장 경로(또는 파일명), 실패/빈 데이터 시 null.
  Future<String?> save({String? subjectId}) async {
    if (isEmpty) return null;
    final now = DateTime.now();
    final stamp =
        '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}'
        '_${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}';
    return saveCsvFile('env_$stamp.csv', toCsv(), subjectId: subjectId);
  }
}
