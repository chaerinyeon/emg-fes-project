// 동시 flush 로 인한 행 중복 회귀 테스트.
//
// 실측 배경: 2026-08-20 두 세션의 CSV 파일 끝에서 각각 49행·37행이 통째로 중복됐다
// (stim_index 가 되감기고 완전히 동일한 행이 다시 나타남). 세션을 끝낼 때
//   · 20초 주기 flush 타이머
//   · EV_SESSION_STOP 수신 시 flush
//   · BLE 끊김 시 flush
//   · saveCsv() 의 flush
// 가 겹치는데, flush() 가 `await appendCsvFile(...)` 이 끝난 뒤에야 커서(_flushed)를
// 옮기기 때문에 그 사이 시작한 두 번째 flush 가 같은 구간을 다시 쓴다.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'package:flutter_app/services/epoch_logger.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.docsPath);
  final String docsPath;
  @override
  Future<String?> getApplicationDocumentsPath() async => docsPath;
}

List<String> _rows(String csv) =>
    csv.trim().split('\n').skip(1).where((l) => l.isNotEmpty).toList();

void _fill(EpochLogRecorder log, int n, {int from = 1}) {
  for (var i = 0; i < n; i++) {
    log.add(
      tRelMs: (from + i) * 31,
      stimIndex: from + i,
      sampleIndex: (from + i) * 31,
      driftMs: 0,
      spike: 700,
      p2p: 300,
      area: 2000,
      r: 2.86,
      valid: true,
      satWindow: false,
      satSpike: false,
      mcuState: 'RUNNING',
      level: 0,
      samples: const [1, 2, 3],
    );
  }
}

void main() {
  late Directory tmp;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tmp = await Directory.systemTemp.createTemp('emgfes_epoch_test');
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  // 결정적 검증: 커서가 await 전에 예약되는가. 파일 I/O 경합 결과(중복이냐 덮어쓰기냐)는
  // 타이밍에 좌우돼 재현이 흔들리므로, 오염의 원인인 '낡은 커서' 자체를 고정한다.
  test('진행 중인 flush 가 커서를 즉시 선점한다', () async {
    final log = EpochLogRecorder()..start(filenameTag: 'C_complete');
    _fill(log, 10);
    await log.flush(subjectId: 'subj');
    expect(log.flushedRows, 10);

    _fill(log, 30, from: 11);
    final f1 = log.flush(subjectId: 'subj'); // await 하지 않는다
    expect(log.flushedRows, 40,
        reason: 'await 뒤에 커서를 옮기면 두 번째 flush 가 같은 구간을 다시 쓴다');
    await f1;
  });

  test('동시에 flush 를 두 번 걸어도 파일이 메모리 전문과 같다', () async {
    final log = EpochLogRecorder()..start(filenameTag: 'C_complete');
    _fill(log, 10);
    await log.flush(subjectId: 'subj');
    _fill(log, 30, from: 11);

    final paths = await Future.wait([
      log.flush(subjectId: 'subj'),
      log.flush(subjectId: 'subj'),
    ]);
    final path = paths.firstWhere((p) => p != null)!;
    expect(await File(path).readAsString(), log.toCsv());
  });

  test('세션 종료 패턴(타이머+STOP+끊김+save 동시)에도 중복이 없다', () async {
    final log = EpochLogRecorder()..start();
    _fill(log, 12);
    await log.flush(subjectId: 'subj');
    _fill(log, 28, from: 13);

    // 실제 종료 시 네 경로가 한꺼번에 flush 를 건다.
    await Future.wait([
      log.flush(subjectId: 'subj'),
      log.flush(subjectId: 'subj'),
      log.flush(subjectId: 'subj'),
      log.save(subjectId: 'subj'),
    ]);
    final p = await log.save(subjectId: 'subj');
    final rows = _rows(await File(p!).readAsString());
    final stims = rows.map((l) => int.parse(l.split(',')[1])).toList();
    expect(stims, List.generate(40, (i) => i + 1));
  });

  test('flush 도중 새 데이터가 들어와도 중복·누락이 없다', () async {
    final log = EpochLogRecorder()..start();
    _fill(log, 4);
    await log.flush(subjectId: 'subj');   // 파일 선생성
    _fill(log, 16, from: 5);
    final f1 = log.flush(subjectId: 'subj');
    _fill(log, 20, from: 21); // 쓰는 동안 도착
    final f2 = log.flush(subjectId: 'subj');
    await Future.wait([f1, f2]);
    final p = await log.flush(subjectId: 'subj');

    final rows = _rows(await File(p!).readAsString());
    final stims = rows.map((l) => int.parse(l.split(',')[1])).toList();
    expect(stims, List.generate(40, (i) => i + 1),
        reason: '1..40 이 순서대로 한 번씩');
  });

  test('save 가 flush 와 겹쳐도 최종 파일이 메모리 전문과 같다', () async {
    final log = EpochLogRecorder()..start();
    _fill(log, 10);
    await log.flush(subjectId: 'subj');   // 파일 선생성
    _fill(log, 20, from: 11);
    final f = log.flush(subjectId: 'subj');
    final s = log.save(subjectId: 'subj');
    await Future.wait([f, s]);

    final p = await log.save(subjectId: 'subj');
    expect(await File(p!).readAsString(), log.toCsv());
  });
}
