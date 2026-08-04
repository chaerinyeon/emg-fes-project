// RAW 1kHz 파형 로거.
// 펌웨어가 전용 BLE 캐릭터리스틱(6e400004)으로 보내는 바이너리 패킷을 받아
// 1ms 해상도 CSV(Time(ms),Raw_ADC)로 저장한다.
//
// 패킷 포맷 (little-endian):
//   [uint32 firstSampleMs][uint16 count][int16 raw × count]
// firstSampleMs = 세션 시작 후 첫 샘플의 ms 인덱스 (1kHz라 1샘플=1ms).
//   → 1ms 타임라인 복원 + 인덱스 불연속으로 패킷 누락 감지.
//
// ENV CSV(10Hz, env_*.csv)는 그대로 두고, 이 로거가 raw_*.csv를 따로 만든다.
// 1kHz 원신호는 10Hz로 평균되기 전의 진짜 파형이라 필터링·주파수 재분석·딥러닝에 쓸 수 있다.
//
// 실제 바이너리 디코딩은 core/raw_packet.dart 한 곳에만 있다 — 모니터 배선
// (SessionController.adopt)도 같은 파서를 쓴다. 여기서 다시 파싱하면 포맷이
// 바뀌었을 때 한쪽만 고쳐지는 사고가 난다.
import '../core/raw_packet.dart';
import 'csv_save_stub.dart' if (dart.library.html) 'csv_save_web.dart';

class RawLogRecorder {
  final List<int> _timesMs = [];
  final List<int> _raw = [];
  bool _recording = false;
  int _lastIdx = -1; // 직전 패킷의 마지막 샘플 인덱스 (누락 감지용)
  int _dropped = 0; // 누락 추정 샘플 수

  bool get isRecording => _recording;
  bool get isEmpty => _timesMs.isEmpty;
  int get length => _timesMs.length;
  int get dropped => _dropped;

  /// 세션 시작 — 이전 데이터를 비우고 기록 시작.
  void start() {
    _timesMs.clear();
    _raw.clear();
    _lastIdx = -1;
    _dropped = 0;
    _recording = true;
  }

  /// 세션 종료 — 기록 중단 (데이터는 save 전까지 유지).
  void stop() => _recording = false;

  /// 바이너리 패킷 1건 추가. 잘렸거나 형식이 안 맞으면 폐기.
  void addPacket(List<int> bytes) {
    if (!_recording) return;
    final pkt = RawPacket.parse(bytes);
    if (pkt == null) return; // 잘린 패킷 폐기

    // 누락 감지: 직전 패킷 끝 다음 인덱스와 연속이어야 함
    final firstMs = pkt.firstSampleMs;
    final count = pkt.samples.length;
    if (_lastIdx >= 0 && firstMs > _lastIdx + 1) {
      _dropped += firstMs - (_lastIdx + 1);
    }
    for (var i = 0; i < count; i++) {
      _timesMs.add(firstMs + i);
      _raw.add(pkt.samples[i]);
    }
    _lastIdx = firstMs + count - 1;
  }

  /// `Time(ms),Raw_ADC` 헤더의 CSV 문자열 생성. Time은 펌웨어가 보낸 샘플 인덱스(ms).
  String toCsv() {
    final sb = StringBuffer()..writeln('Time(ms),Raw_ADC');
    for (var i = 0; i < _timesMs.length; i++) {
      sb.writeln('${_timesMs[i]},${_raw[i]}');
    }
    return sb.toString();
  }

  /// CSV 저장 — 모바일: 앱 문서 `data/<subjectId>/raw_<stamp>.csv`, 웹: 다운로드.
  Future<String?> save({String? subjectId}) async {
    if (isEmpty) return null;
    final now = DateTime.now();
    final stamp =
        '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}'
        '_${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}';
    return saveCsvFile('raw_$stamp.csv', toCsv(), subjectId: subjectId);
  }
}
