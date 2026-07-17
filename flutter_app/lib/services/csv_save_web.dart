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

/// 웹은 파일 끝에 이어쓰기가 불가능하다(다운로드만 가능) — 주기적 flush 는 지원하지
/// 않고 항상 null 을 반환한다. 웹에서는 기존대로 세션 종료 시 saveCsvFile 로
/// 한 번에 다운로드된다. 시그니처만 네이티브와 맞춰 조건부 import 가 성립하게 한다.
Future<String?> appendCsvFile(
  String filename,
  String header,
  String rows, {
  String? subjectId,
  bool rewrite = false,
}) async =>
    null;
