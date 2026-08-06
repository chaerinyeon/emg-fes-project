import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:flutter_app/data/local/hive_session_store.dart';
import 'package:flutter_app/data/local/session_store.dart';
import 'package:flutter_app/session/end_conditions.dart';

SessionSummary _s(String id, {bool synced = false}) => SessionSummary(
      id: id,
      patientId: 'p1',
      deviceId: 'd1',
      startedAt: DateTime.utc(2026, 8, 6, 10),
      endedAt: DateTime.utc(2026, 8, 6, 10, 9),
      durationS: 540,
      gameId: 'fishing',
      stageId: 's1',
      intensityLevel: 3,
      endReason: SessionEndReason.fatigueThreshold,
      repCount: 330,
      successRate: 0.8,
      maxFatigue: 27.4,
      endFatigue: 18,
      onsetS: 400,
      burstCount: 330,
      detectRate: 0.95,
      eventsPerBurstMedian: 19,
      levelChangeCount: 2,
      reliabilityGrade: 'A',
      stimPeriodMs: 1619,
      appVersion: '1.0.0',
      fwVersion: '2026.7',
      synced: synced,
    );

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('refit_hive_');
    Hive.init(dir.path);
  });

  tearDown(() async {
    await Hive.close();
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  test('세션이 디스크에 남아 재시작 후에도 읽힌다', () async {
    final a = await HiveSessionStore.open();
    await a.saveSession(_s('s1'));
    await a.appendBursts(List.generate(
        340,
        (i) => BurstRow(
            sessionId: 's1',
            tS: i * 1.618,
            p2p: 500 - i.toDouble(),
            fatigue: i / 20,
            contractionOk: i % 4 != 0,
            valid: true)));
    await a.appendEvent(SessionEventRow(
        sessionId: 's1',
        tS: 5,
        type: SessionEventType.signalWarning,
        actor: 'app'));
    await a.close();

    // 앱이 죽었다가 다시 켜진 상황.
    final b = await HiveSessionStore.open();
    final got = await b.session('s1');
    expect(got, isNotNull);
    expect(got!.repCount, 330);
    expect(got.endReason, SessionEndReason.fatigueThreshold);
    expect((await b.series('s1')).length, 340);
    expect((await b.events('s1')).length, 1);
  });

  test('재시작 후에도 미동기 세션이 큐에 남는다', () async {
    final a = await HiveSessionStore.open();
    await a.saveSession(_s('s1', synced: false));
    await a.saveSession(_s('s2', synced: true));
    await a.close();

    final b = await HiveSessionStore.open();
    expect((await b.unsyncedSessions()).map((s) => s.id), ['s1'],
        reason: '재시작으로 업로드 대기열이 사라지면 기록이 유실된다');
  });

  test('markSynced가 디스크에 반영된다', () async {
    final a = await HiveSessionStore.open();
    await a.saveSession(_s('s1'));
    await a.markSynced('s1');
    await a.close();

    final b = await HiveSessionStore.open();
    expect((await b.session('s1'))!.synced, isTrue);
    expect(await b.unsyncedSessions(), isEmpty);
  });

  test('세션을 지우면 시계열·이벤트도 사라진다', () async {
    final a = await HiveSessionStore.open();
    await a.saveSession(_s('s1'));
    await a.appendBursts([
      BurstRow(
          sessionId: 's1',
          tS: 0,
          p2p: 1,
          fatigue: 0,
          contractionOk: true,
          valid: true)
    ]);
    await a.deleteSession('s1');
    await a.close();

    final b = await HiveSessionStore.open();
    expect(await b.session('s1'), isNull);
    expect(await b.series('s1'), isEmpty);
  });

  test('세션 하나가 수십 KB 규모다', () async {
    final a = await HiveSessionStore.open();
    await a.saveSession(_s('s1'));
    await a.appendBursts(List.generate(
        340,
        (i) => BurstRow(
            sessionId: 's1',
            tS: i * 1.618,
            p2p: 500 - i.toDouble(),
            fatigue: i / 20,
            contractionOk: true,
            valid: true)));
    await a.close();

    var bytes = 0;
    for (final f in dir.listSync(recursive: true).whereType<File>()) {
      bytes += f.lengthSync();
    }
    expect(bytes, lessThan(500 * 1024),
        reason: 'raw 를 저장하면 여기서 터진다. 버스트 지표만 남겨야 한다');
  });
}
