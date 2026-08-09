// RAW 4kHz 파형 로거.
// 펌웨어가 전용 BLE 캐릭터리스틱(6e400004)으로 보내는 바이너리 패킷을 받아
// 0.25ms 해상도 CSV(Time(ms),Raw_ADC)로 저장한다.
//
// 패킷 포맷 (little-endian):
//   [uint32 firstSampleIndex][uint16 count][int16 raw × count]
// firstSampleIndex = 세션 시작 후 첫 샘플 인덱스 (4kHz라 1샘플=0.25ms).
//   → 0.25ms 타임라인 복원 + 인덱스 불연속으로 패킷 누락 감지.
//
// ENV CSV(10Hz, env_*.csv)는 그대로 두고, 이 로거가 raw_*.csv를 따로 만든다.
// 4kHz 원신호는 10Hz로 평균되기 전의 진짜 파형이라 필터링·주파수 재분석·딥러닝에 쓸 수 있다.
import 'dart:typed_data';
import 'csv_save_stub.dart' if (dart.library.html) 'csv_save_web.dart';

class RawLogRecorder {
  static const int sampleRate = 4000;

  final List<int> _sampleIndices = [];
  final List<int> _raw = [];
  bool _recording = false;
  int _lastIdx = -1; // 직전 패킷의 마지막 샘플 인덱스 (누락 감지용)
  int _dropped = 0; // 누락 추정 샘플 수

  // --- 주기적 flush 상태 ---
  // 파일명은 세션 시작 시 확정한다 — 세션 도중에도 같은 파일에 이어써야 한다.
  String? _filename;
  String? _path; // 마지막으로 성공한 저장 경로
  int _flushed = 0; // 디스크에 이미 쓴 행 수 (다음 flush 의 시작 인덱스)
  bool _rewrite = false; // true 면 다음 flush 가 파일을 헤더부터 새로 쓴다

  bool get isRecording => _recording;
  bool get isEmpty => _sampleIndices.isEmpty;
  int get length => _sampleIndices.length;
  int get dropped => _dropped;

  /// 세션 시작 — 이전 데이터를 비우고 기록 시작.
  void start({String filenameTag = 'unknown'}) {
    _sampleIndices.clear();
    _raw.clear();
    _lastIdx = -1;
    _dropped = 0;
    _flushed = 0;
    _rewrite = false;
    _path = null;
    _filename = 'raw_${_stamp()}_$filenameTag.csv';
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

  /// 바이너리 패킷 1건 추가. 잘렸거나 형식이 안 맞으면 폐기.
  void addPacket(List<int> bytes) {
    if (!_recording || bytes.length < 6) return;
    final bd = ByteData.sublistView(Uint8List.fromList(bytes));
    final firstIndex = bd.getUint32(0, Endian.little);
    final count = bd.getUint16(4, Endian.little);
    if (count <= 0 || bytes.length < 6 + 2 * count) return; // 잘린 패킷 폐기

    // 인덱스가 뒤로 감 = 펌웨어가 세션 시작으로 rawSampleCounter 를 0 으로 리셋했다는 뜻.
    // 리셋 직전에 만들어져 전송 대기 중이던 '이전 세션의 잔여 패킷'이 새 세션 로그의
    // 맨 앞에 붙는 문제가 있었다(Time(ms) 가 단조증가가 아니게 되어 분석이 깨짐).
    // 여기까지 받은 것은 모두 이전 세션 것이므로 버리고 이 패킷부터 다시 시작한다.
    if (_lastIdx >= 0 && firstIndex < _lastIdx) {
      _sampleIndices.clear();
      _raw.clear();
      _dropped = 0;
      // 이미 flush 된 행들도 전부 이전 세션 것이다. 커서를 되감고 rewrite 를 걸어
      // 다음 flush 가 파일을 헤더부터 새로 쓰게 한다 — 안 그러면 디스크에 남은
      // 이전 세션 행 뒤에 새 세션이 붙어 Time(ms) 단조증가가 깨진다.
      _flushed = 0;
      _rewrite = true;
    } else if (_lastIdx >= 0 && firstIndex > _lastIdx + 1) {
      // 누락 감지: 직전 패킷 끝 다음 인덱스와 연속이어야 함
      _dropped += firstIndex - (_lastIdx + 1);
    }
    for (var i = 0; i < count; i++) {
      _sampleIndices.add(firstIndex + i);
      _raw.add(bd.getInt16(6 + 2 * i, Endian.little));
    }
    _lastIdx = firstIndex + count - 1;
  }

  static const String _header = 'Time(ms),Raw_ADC\n';

  /// [from] 번째 행부터 끝까지를 CSV 행 문자열로.
  String _rowsFrom(int from) {
    final sb = StringBuffer();
    for (var i = from; i < _sampleIndices.length; i++) {
      sb.writeln('${_formatTimeMs(_sampleIndices[i])},${_raw[i]}');
    }
    return sb.toString();
  }

  static String _formatTimeMs(int sampleIndex) {
    final samplesPerMs = sampleRate ~/ 1000;
    final wholeMs = sampleIndex ~/ samplesPerMs;
    const fractions = ['', '.25', '.5', '.75'];
    return '$wholeMs${fractions[sampleIndex % samplesPerMs]}';
  }

  /// `Time(ms),Raw_ADC` 헤더의 CSV 전문. Time은 표본 인덱스를 ms로 환산한 값.
  String toCsv() => _header + _rowsFrom(0);

  /// 세션 도중 호출 — 아직 디스크에 안 쓴 행만 파일 끝에 이어붙인다.
  /// 앱이 죽어도 여기까지는 남는다. 반환값: 저장 경로(웹/실패 시 null).
  Future<String?> flush({String? subjectId}) async {
    if (_filename == null || _sampleIndices.isEmpty) return null;
    if (_flushed >= _sampleIndices.length && !_rewrite) {
      return _path; // 새 데이터 없음
    }
    final upTo = _sampleIndices.length; // 쓰는 동안 addPacket 이 들어와도 커서가 앞서지 않게
    final rows = _rowsFrom(_flushed);
    final p = await appendCsvFile(
      _filename!,
      _header,
      rows,
      subjectId: subjectId,
      rewrite: _rewrite,
    );
    if (p == null) return null; // 웹이거나 쓰기 실패 — 커서를 그대로 둬 다음에 재시도
    _path = p;
    _flushed = upTo;
    _rewrite = false;
    return _path;
  }

  /// CSV 저장 — 모바일: 앱 문서 `data/<subjectId>/raw_<stamp>.csv`, 웹: 다운로드.
  /// 네이티브에선 남은 행만 이어쓰고, append 가 불가능한 웹에선 전문을 다운로드한다.
  Future<String?> save({String? subjectId}) async {
    if (isEmpty) return null;
    final flushed = await flush(subjectId: subjectId);
    if (flushed != null) return flushed;
    return saveCsvFile(
      _filename ?? 'raw_${_stamp()}.csv',
      toCsv(),
      subjectId: subjectId,
    );
  }
}
