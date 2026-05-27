import 'csv_save_stub.dart' if (dart.library.html) 'csv_save_web.dart';

const List<String> kCsvHeaders = [
  'wall_time',
  'timestamp_ms',
  'emg_raw',
  'emg_env',
  'rms',
  'mdf',
  'rms_slope',
  'mdf_slope',
  'fatigue_detected',
  'consecutive',
  'is_running',
  'is_stimulating',
  'history_count',
  'baseline_rms',
  'rms_ratio',
  'muscle_state',
  'marker',
];

/// 세션 로그를 CSV 문자열로 직렬화 후 브라우저 다운로드 트리거.
/// 반환값: 저장한 파일명 (호출자가 토스트 등에 사용).
String downloadCsv(List<Map<String, dynamic>> log) {
  final sb = StringBuffer()..writeln(kCsvHeaders.join(','));
  for (final row in log) {
    sb.writeln(
      kCsvHeaders
          .map((k) {
            final v = row[k];
            if (v == null) return '';
            final s = v.toString();
            return s.contains(',') ? '"$s"' : s;
          })
          .join(','),
    );
  }
  final now = DateTime.now();
  final stamp =
      '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}'
      '_${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}';
  final filename = 'emg_$stamp.csv';
  saveCsvFile(filename, sb.toString());
  return filename;
}
