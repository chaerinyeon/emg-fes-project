// Web implementation — uses dart:html to trigger browser download.
import 'dart:convert';
import 'dart:html' as html;

bool get isWebCsvSupported => true;

/// 브라우저 다운로드를 트리거하고 파일명을 반환한다.
/// 웹은 subject 디렉토리 개념이 없어 [subjectId] 는 무시한다.
Future<String?> saveCsvFile(
  String filename,
  String csvContent, {
  String? subjectId,
}) async {
  final bytes = utf8.encode(csvContent);
  final blob = html.Blob([bytes], 'text/csv');
  final url = html.Url.createObjectUrlFromBlob(blob);
  html.AnchorElement(href: url)
    ..setAttribute('download', filename)
    ..click();
  html.Url.revokeObjectUrl(url);
  return filename;
}
