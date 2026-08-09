// 세션 중 주기적 flush(디스크 이어쓰기) 로직 검증.
//
// 배경: 예전엔 세션 전체를 메모리에 들고 있다가 Stop 에서 한 번에 저장했다.
// 측정 중 블루투스가 끊겨 Stop 이 비활성화되자 5분치가 통째로 갇힌 사고가 있었고,
// 그래서 로거가 중간중간 파일에 이어쓰도록 바뀌었다. 이어쓰기는 커서(_flushed)를
// 잘못 다루면 행이 중복되거나 누락되므로, 그 부분을 여기서 고정한다.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'package:flutter_app/services/env_logger.dart';
import 'package:flutter_app/services/raw_logger.dart';
import 'package:flutter_app/services/csv_exporter.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.docsPath);
  final String docsPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => docsPath;
}

/// 저장된 CSV 를 읽는다. subjectId 는 테스트 전체에서 'subj'.
Future<String> _read(String path) => File(path).readAsString();

/// 헤더를 뺀 데이터 행들.
List<String> _rows(String csv) =>
    csv.trim().split('\n').skip(1).where((l) => l.isNotEmpty).toList();

void main() {
  late Directory tmp;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tmp = await Directory.systemTemp.createTemp('emgfes_logger_test');
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  group('EnvLogRecorder', () {
    test('분류 태그가 파일명에 포함된다', () async {
      final log = EnvLogRecorder()..start(filenameTag: 'B_incomplete');
      log.add(1000, 1);
      final path = await log.flush(subjectId: 'subj');
      expect(path, endsWith('_B_incomplete.csv'));
    });

    test('여러 번 flush 해도 행이 중복·누락되지 않는다', () async {
      final log = EnvLogRecorder()..start();
      for (var i = 0; i < 5; i++) {
        log.add(1000 + i * 100, i.toDouble());
      }
      final p1 = await log.flush(subjectId: 'subj');
      expect(p1, isNotNull);
      expect(_rows(await _read(p1!)).length, 5);

      // 이어서 5개 더 — 새로 들어온 것만 붙어야 한다
      for (var i = 5; i < 10; i++) {
        log.add(1000 + i * 100, i.toDouble());
      }
      final p2 = await log.flush(subjectId: 'subj');
      expect(p2, p1, reason: '같은 세션은 같은 파일에 이어써야 한다');
      expect(_rows(await _read(p2!)).length, 10);
    });

    test('새 데이터 없이 flush 하면 파일이 그대로다', () async {
      final log = EnvLogRecorder()..start();
      log.add(1000, 1);
      final p = await log.flush(subjectId: 'subj');
      final before = await _read(p!);
      expect(await log.flush(subjectId: 'subj'), p);
      expect(await _read(p), before, reason: '중복 append 가 없어야 한다');
    });

    test('flush 를 거친 뒤 save 해도 최종 파일이 메모리 전문과 같다', () async {
      final log = EnvLogRecorder()..start();
      for (var i = 0; i < 3; i++) {
        log.add(1000 + i * 100, i.toDouble());
      }
      await log.flush(subjectId: 'subj');
      for (var i = 3; i < 6; i++) {
        log.add(1000 + i * 100, i.toDouble());
      }
      log.stop();
      final p = await log.save(subjectId: 'subj');
      expect(
        await _read(p!),
        log.toCsv(),
        reason: '이어쓴 파일이 toCsv() 전문과 바이트 단위로 일치해야 한다',
      );
    });

    test('Time(ms) 는 flush 경계를 넘어도 첫 샘플 기준 상대값을 유지한다', () async {
      final log = EnvLogRecorder()..start();
      log.add(5000, 1); // t0 = 5000
      await log.flush(subjectId: 'subj');
      log.add(5100, 2);
      final p = await log.save(subjectId: 'subj');
      final rows = _rows(await _read(p!));
      expect(rows[0].split(',').first, '0');
      expect(
        rows[1].split(',').first,
        '100',
        reason: 'flush 이후 행도 같은 t0 로 정규화돼야 한다',
      );
    });
  });

  test('요약 EMG 파일명에도 분류 태그가 포함된다', () async {
    final path = await downloadCsv(
      const [],
      subjectId: 'subj',
      filenameTag: 'C_complete',
    );
    expect(path, endsWith('_C_complete.csv'));
  });

  group('RawLogRecorder', () {
    /// [firstMs] 부터 [count] 개 샘플을 담은 패킷 바이트 생성.
    List<int> packet(int firstMs, int count) {
      final b = BytesBuilder();
      b.add([
        firstMs & 0xFF,
        (firstMs >> 8) & 0xFF,
        (firstMs >> 16) & 0xFF,
        (firstMs >> 24) & 0xFF,
        count & 0xFF,
        (count >> 8) & 0xFF,
      ]);
      for (var i = 0; i < count; i++) {
        b.add([i & 0xFF, 0]); // int16 little-endian
      }
      return b.toBytes();
    }

    test('분류 태그가 파일명에 포함된다', () async {
      final log = RawLogRecorder()..start(filenameTag: 'C_complete');
      log.addPacket(packet(0, 1));
      final path = await log.flush(subjectId: 'subj');
      expect(path, endsWith('_C_complete.csv'));
    });

    test('여러 번 flush 해도 행이 중복·누락되지 않는다', () async {
      final log = RawLogRecorder()..start();
      log.addPacket(packet(0, 4));
      final p1 = await log.flush(subjectId: 'subj');
      expect(_rows(await _read(p1!)).length, 4);

      log.addPacket(packet(4, 4));
      final p2 = await log.flush(subjectId: 'subj');
      expect(p2, p1);
      expect(_rows(await _read(p2!)).length, 8);
    });

    test('4kHz 표본 인덱스를 0.25ms 간격으로 기록한다', () {
      final log = RawLogRecorder()..start();
      log.addPacket(packet(0, 5));

      final times = _rows(
        log.toCsv(),
      ).map((row) => row.split(',').first).toList();
      expect(times, ['0', '0.25', '0.5', '0.75', '1']);
    });

    test('펌웨어 카운터 리셋 시 이미 flush 된 이전 세션 행이 파일에 남지 않는다', () async {
      final log = RawLogRecorder()..start();
      log.addPacket(packet(900, 4)); // 이전 세션 잔여 패킷
      final p1 = await log.flush(subjectId: 'subj');
      expect(_rows(await _read(p1!)).length, 4);

      // 인덱스가 뒤로 감 = 새 세션 시작 → 메모리를 비우고 파일도 새로 써야 한다
      log.addPacket(packet(0, 3));
      final p2 = await log.flush(subjectId: 'subj');
      final rows = _rows(await _read(p2!));
      expect(rows.length, 3, reason: '리셋 전 4행이 디스크에서 지워져야 한다');
      expect(rows.first.split(',').first, '0');

      // Time(ms) 단조증가 — 이게 깨지면 분석 파이프라인이 망가진다
      final times = rows.map((r) => double.parse(r.split(',').first)).toList();
      for (var i = 1; i < times.length; i++) {
        expect(times[i], greaterThan(times[i - 1]));
      }
    });

    test('flush 를 거친 뒤 save 해도 최종 파일이 메모리 전문과 같다', () async {
      final log = RawLogRecorder()..start();
      log.addPacket(packet(0, 3));
      await log.flush(subjectId: 'subj');
      log.addPacket(packet(3, 3));
      log.stop();
      final p = await log.save(subjectId: 'subj');
      expect(await _read(p!), log.toCsv());
    });
  });
}
