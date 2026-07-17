// Native (iOS / Android / desktop) implementation.
// 앱 문서 디렉토리 아래 data/<subjectId>/<filename> 으로 실제 파일을 쓴다.
// (웹은 csv_save_web.dart 가 대신 사용됨 — 조건부 import)
import 'dart:io';

import 'package:path_provider/path_provider.dart';

bool get isWebCsvSupported => false;

/// `data/<subjectId>/` 디렉토리를 만들고 반환. id 가 없으면 `data/unknown/`.
Future<Directory> _subjectDir(String? subjectId) async {
  final docs = await getApplicationDocumentsDirectory();
  final subject = (subjectId == null || subjectId.trim().isEmpty)
      ? 'unknown'
      : subjectId.trim();
  final dir = Directory('${docs.path}/data/$subject');
  if (!await dir.exists()) {
    await dir.create(recursive: true);
  }
  return dir;
}

/// CSV 를 기기 내부에 저장하고, 저장된 전체 경로를 반환한다. 실패 시 null.
/// [subjectId] 가 있으면 `data/<id>/` 하위에, 없으면 `data/unknown/` 에 저장.
Future<String?> saveCsvFile(
  String filename,
  String csvContent, {
  String? subjectId,
}) async {
  try {
    final dir = await _subjectDir(subjectId);
    final file = File('${dir.path}/$filename');
    await file.writeAsString(csvContent);
    return file.path;
  } catch (_) {
    return null;
  }
}

/// 세션 중 주기적 저장(flush)용 — [rows] 를 파일 끝에 이어붙인다.
/// 파일이 없거나 [rewrite] 가 true 면 [header] 부터 새로 쓴다.
///
/// 세션 전체를 메모리에 들고 있다가 종료 시 한 번에 쓰면, 앱이 죽거나 저장 경로가
/// 막히는 순간 전부 사라진다(실제로 BLE 끊김 → Stop 비활성화로 5분치가 갇힌 적 있음).
/// 이 함수로 중간중간 흘려두면 마지막 flush 까지는 디스크에 남는다.
Future<String?> appendCsvFile(
  String filename,
  String header,
  String rows, {
  String? subjectId,
  bool rewrite = false,
}) async {
  try {
    final dir = await _subjectDir(subjectId);
    final file = File('${dir.path}/$filename');
    if (rewrite || !await file.exists()) {
      await file.writeAsString(header + rows);
    } else {
      await file.writeAsString(rows, mode: FileMode.append);
    }
    return file.path;
  } catch (_) {
    return null;
  }
}
