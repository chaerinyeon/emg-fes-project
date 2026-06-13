// Native (iOS / Android / desktop) implementation.
// 앱 문서 디렉토리 아래 data/<subjectId>/<filename> 으로 실제 파일을 쓴다.
// (웹은 csv_save_web.dart 가 대신 사용됨 — 조건부 import)
import 'dart:io';

import 'package:path_provider/path_provider.dart';

bool get isWebCsvSupported => false;

/// CSV 를 기기 내부에 저장하고, 저장된 전체 경로를 반환한다. 실패 시 null.
/// [subjectId] 가 있으면 `data/<id>/` 하위에, 없으면 `data/unknown/` 에 저장.
Future<String?> saveCsvFile(
  String filename,
  String csvContent, {
  String? subjectId,
}) async {
  try {
    final docs = await getApplicationDocumentsDirectory();
    final subject = (subjectId == null || subjectId.trim().isEmpty)
        ? 'unknown'
        : subjectId.trim();
    final dir = Directory('${docs.path}/data/$subject');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final file = File('${dir.path}/$filename');
    await file.writeAsString(csvContent);
    return file.path;
  } catch (_) {
    return null;
  }
}
