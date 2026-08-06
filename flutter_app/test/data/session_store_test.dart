import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/data/local/session_store.dart';
import 'package:flutter_app/session/end_conditions.dart';

SessionSummary _summary({String id = 's1', bool synced = false}) =>
    SessionSummary(
      id: id,
      patientId: 'p1',
      deviceId: 'd1',
      startedAt: DateTime.utc(2026, 8, 6, 10),
      endedAt: DateTime.utc(2026, 8, 6, 10, 9, 18),
      durationS: 558,
      gameId: 'fishing',
      stageId: 'stage_1',
      intensityLevel: 3,
      endReason: SessionEndReason.gameComplete,
      repCount: 340,
      successRate: 0.82,
      maxFatigue: 27.4,
      endFatigue: 19.1,
      onsetS: 412.0,
      burstCount: 340,
      detectRate: 0.95,
      eventsPerBurstMedian: 19.0,
      levelChangeCount: 3,
      reliabilityGrade: 'A',
      stimPeriodMs: 1619,
      appVersion: '1.0.0',
      fwVersion: '2026.7',
      synced: synced,
    );

BurstRow _burst(int i) => BurstRow(
      sessionId: 's1',
      tS: i * 1.618,
      p2p: 500.0 - i,
      fatigue: i / 10.0,
      contractionOk: i % 5 != 0,
      valid: true,
    );

void main() {
  group('스키마 — 공통 컨텍스트 6장', () {
    test('sessions 컬럼 이름이 DB와 일치한다', () {
      final j = _summary().toJson();
      expect(
        j.keys.toSet(),
        {
          'id', 'patient_id', 'device_id', 'started_at', 'ended_at',
          'duration_s', 'game_id', 'stage_id', 'intensity_level',
          'end_reason', 'rep_count', 'success_rate', 'max_fatigue',
          'end_fatigue', 'onset_s', 'burst_count', 'detect_rate',
          'events_per_burst_median', 'level_change_count',
          'reliability_grade', 'stim_period_ms', 'app_version', 'fw_version',
        },
        reason: 'synced 는 로컬 전용이라 업로드 payload 에 들어가면 안 된다',
      );
    });

    test('end_reason은 5장 enum 문자열로 나간다', () {
      expect(_summary().toJson()['end_reason'], 'game_complete');
    });

    test('session_series 컬럼이 일치한다', () {
      expect(_burst(0).toJson().keys.toSet(),
          {'session_id', 't_s', 'p2p', 'fatigue', 'contraction_ok', 'valid'});
    });

    test('session_events 컬럼이 일치한다', () {
      final e = SessionEventRow(
        sessionId: 's1',
        tS: 12.0,
        type: SessionEventType.levelChange,
        actor: 'app',
        payload: {'from': 1, 'to': 2},
      );
      expect(e.toJson().keys.toSet(),
          {'session_id', 't_s', 'type', 'actor', 'payload'});
      expect(e.toJson()['type'], 'level_change');
    });

    test('session_live 컬럼이 일치한다', () {
      final l = LiveRow(
        sessionId: 's1',
        updatedAt: DateTime.utc(2026, 8, 6, 10, 5),
        elapsedS: 300,
        repCount: 185,
        fatigue: 21.0,
        successRate50: 0.78,
        signalQuality: 'ok',
        state: 'playing',
      );
      expect(l.toJson().keys.toSet(), {
        'session_id', 'updated_at', 'elapsed_s', 'rep_count', 'fatigue',
        'success_rate_50', 'signal_quality', 'state',
      });
    });

    test('직렬화 왕복이 값을 보존한다', () {
      final a = _summary();
      final b = SessionSummary.fromJson(a.toJson()..['synced'] = false);
      expect(b.id, a.id);
      expect(b.endReason, a.endReason);
      expect(b.maxFatigue, a.maxFatigue);
      expect(b.repCount, a.repCount);
    });
  });

  group('raw는 저장하지 않는다', () {
    test('버스트 행에 원시 표본이 없다', () {
      final j = _burst(0).toJson();
      for (final k in j.keys) {
        expect(k, isNot(contains('raw')));
        expect(k, isNot(contains('sample')));
      }
    });

    test('세션 하나가 수십 KB 규모다', () {
      final rows = List.generate(340, _burst);
      final bytes = rows
          .map((r) => r.toJson().toString().length)
          .reduce((a, b) => a + b);
      expect(bytes, lessThan(100 * 1024),
          reason: '세션당 약 340행, 수십 KB 여야 한다');
    });
  });

  group('InMemorySessionStore', () {
    late SessionStore store;
    setUp(() => store = InMemorySessionStore());

    test('세션을 저장하고 다시 읽는다', () async {
      await store.saveSession(_summary());
      final got = await store.session('s1');
      expect(got, isNotNull);
      expect(got!.repCount, 340);
    });

    test('시계열을 저장하고 읽는다', () async {
      await store.saveSession(_summary());
      await store.appendBursts(List.generate(340, _burst));
      final rows = await store.series('s1');
      expect(rows.length, 340);
      expect(rows.first.tS, 0.0);
    });

    test('동기화 안 된 세션만 골라낸다', () async {
      await store.saveSession(_summary(id: 's1', synced: false));
      await store.saveSession(_summary(id: 's2', synced: true));
      await store.saveSession(_summary(id: 's3', synced: false));

      final pending = await store.unsyncedSessions();
      expect(pending.map((s) => s.id).toList(), ['s1', 's3']);
    });

    test('동기화 완료를 표시한다', () async {
      await store.saveSession(_summary(id: 's1'));
      await store.markSynced('s1');
      expect((await store.unsyncedSessions()), isEmpty);
      expect((await store.session('s1'))!.synced, isTrue);
    });

    test('같은 id로 저장하면 덮어쓴다', () async {
      await store.saveSession(_summary(id: 's1'));
      await store.saveSession(_summary(id: 's1', synced: true));
      expect((await store.session('s1'))!.synced, isTrue);
    });

    test('이벤트를 저장하고 읽는다', () async {
      await store.saveSession(_summary());
      await store.appendEvent(SessionEventRow(
        sessionId: 's1',
        tS: 12.0,
        type: SessionEventType.signalWarning,
        actor: 'app',
      ));
      expect((await store.events('s1')).length, 1);
    });

    test('세션을 지우면 시계열·이벤트도 같이 지워진다', () async {
      await store.saveSession(_summary());
      await store.appendBursts([_burst(0)]);
      await store.appendEvent(SessionEventRow(
          sessionId: 's1', tS: 1, type: SessionEventType.userPause, actor: 'user'));

      await store.deleteSession('s1');
      expect(await store.session('s1'), isNull);
      expect(await store.series('s1'), isEmpty);
      expect(await store.events('s1'), isEmpty);
    });
  });
}
