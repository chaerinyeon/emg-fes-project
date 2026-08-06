import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/data/local/session_store.dart';
import 'package:flutter_app/data/remote/remote_sink.dart';
import 'package:flutter_app/data/remote/sync_service.dart';
import 'package:flutter_app/session/end_conditions.dart';

class FakeSink implements RemoteSink {
  final uploaded = <String>[];
  final live = <Map<String, dynamic>>[];
  final acks = <Map<String, dynamic>>[];

  /// true 면 업로드가 실패한다 (오프라인).
  bool offline = false;

  /// 이 세션 id 만 실패시킨다.
  String? failFor;

  @override
  Future<void> uploadSession({
    required Map<String, dynamic> summary,
    required List<Map<String, dynamic>> series,
    required List<Map<String, dynamic>> events,
  }) async {
    final id = summary['id'] as String;
    if (offline || id == failFor) throw StateError('network down');
    uploaded.add(id);
  }

  @override
  Future<void> upsertLive(Map<String, dynamic> row) async {
    if (offline) throw StateError('network down');
    live.add(row);
  }

  @override
  Future<void> ackCommand({
    required String commandId,
    required String status,
    DateTime? ackedAt,
    DateTime? executedAt,
  }) async {
    if (offline) throw StateError('network down');
    acks.add({
      'id': commandId,
      'status': status,
      'acked_at': ackedAt,
      'executed_at': executedAt,
    });
  }
}

SessionSummary summary(String id, {DateTime? started, bool synced = false}) =>
    SessionSummary(
      id: id,
      patientId: 'p1',
      deviceId: 'd1',
      startedAt: started ?? DateTime.utc(2026, 8, 6, 10),
      endedAt: DateTime.utc(2026, 8, 6, 10, 9),
      durationS: 540,
      gameId: 'fishing',
      stageId: 's1',
      intensityLevel: 3,
      endReason: SessionEndReason.gameComplete,
      repCount: 330,
      successRate: 0.8,
      maxFatigue: 25,
      endFatigue: 18,
      onsetS: null,
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
  late InMemorySessionStore store;
  late FakeSink sink;
  late SyncService sync;
  late DateTime now;

  setUp(() {
    store = InMemorySessionStore();
    sink = FakeSink();
    now = DateTime.utc(2026, 8, 6, 12);
    sync = SyncService(store, sink, now: () => now);
  });

  group('오프라인에서도 훈련은 끝까지', () {
    test('네트워크가 없어도 세션은 로컬에 남는다', () async {
      sink.offline = true;
      await store.saveSession(summary('s1'));
      await store.appendBursts([
        BurstRow(
            sessionId: 's1',
            tS: 0,
            p2p: 500,
            fatigue: 0,
            contractionOk: true,
            valid: true)
      ]);

      final n = await sync.flush();
      expect(n, 0);
      expect((await store.session('s1'))!.synced, isFalse);
      expect((await store.series('s1')).length, 1,
          reason: '업로드가 실패해도 로컬 기록은 온전해야 한다');
    });

    test('연결이 돌아오면 밀린 세션이 올라간다', () async {
      sink.offline = true;
      await store.saveSession(summary('s1'));
      await store.saveSession(summary('s2'));
      expect(await sync.flush(), 0);

      sink.offline = false;
      expect(await sync.flush(), 2);
      expect(sink.uploaded, ['s1', 's2']);
      expect((await store.unsyncedSessions()), isEmpty);
    });

    test('오래된 세션부터 올린다', () async {
      await store.saveSession(
          summary('new', started: DateTime.utc(2026, 8, 6)));
      await store.saveSession(
          summary('old', started: DateTime.utc(2026, 8, 1)));

      await sync.flush();
      expect(sink.uploaded, ['old', 'new']);
    });

    test('하나가 실패해도 나머지는 올라간다', () async {
      await store.saveSession(
          summary('a', started: DateTime.utc(2026, 8, 1)));
      await store.saveSession(
          summary('b', started: DateTime.utc(2026, 8, 2)));
      await store.saveSession(
          summary('c', started: DateTime.utc(2026, 8, 3)));
      sink.failFor = 'b';

      expect(await sync.flush(), 2);
      expect(sink.uploaded, ['a', 'c']);
      expect((await store.unsyncedSessions()).map((s) => s.id), ['b']);
    });

    test('업로드가 실패하면 synced로 표시하지 않는다', () async {
      sink.offline = true;
      await store.saveSession(summary('s1'));
      await sync.flush();
      expect((await store.session('s1'))!.synced, isFalse,
          reason: '올라가지도 않았는데 완료로 찍으면 기록이 영영 사라진다');
    });

    test('이미 올린 세션을 다시 올리지 않는다', () async {
      await store.saveSession(summary('s1'));
      await sync.flush();
      await sync.flush();
      expect(sink.uploaded, ['s1']);
    });

    test('요약·시계열·이벤트가 함께 올라간다', () async {
      await store.saveSession(summary('s1'));
      await store.appendBursts(List.generate(
          3,
          (i) => BurstRow(
              sessionId: 's1',
              tS: i.toDouble(),
              p2p: 500,
              fatigue: 0,
              contractionOk: true,
              valid: true)));
      await store.appendEvent(SessionEventRow(
          sessionId: 's1',
          tS: 1,
          type: SessionEventType.levelChange,
          actor: 'app'));

      await sync.flush();
      expect(sink.uploaded, ['s1']);
    });
  });

  group('라이브 뷰 upsert', () {
    LiveRow row(int elapsed) => LiveRow(
          sessionId: 's1',
          updatedAt: now,
          elapsedS: elapsed,
          repCount: elapsed,
          fatigue: 10,
          successRate50: 0.8,
          signalQuality: 'ok',
          state: 'playing',
        );

    test('첫 행은 바로 올라간다', () async {
      await sync.pushLive(row(1));
      expect(sink.live.length, 1);
    });

    test('간격 안에 들어온 갱신은 건너뛴다', () async {
      await sync.pushLive(row(1));
      now = now.add(const Duration(seconds: 1));
      await sync.pushLive(row(2));
      expect(sink.live.length, 1, reason: '2~5초 간격 정책');
    });

    test('간격이 지나면 다시 올린다', () async {
      await sync.pushLive(row(1));
      now = now.add(const Duration(seconds: 5));
      await sync.pushLive(row(2));
      expect(sink.live.length, 2);
    });

    test('라이브 업로드 실패는 큐에 쌓지 않는다', () async {
      // 지난 라이브 값은 올라가 봐야 쓸모가 없다. 밀리면 버린다.
      sink.offline = true;
      await sync.pushLive(row(1));
      expect(sink.live, isEmpty);

      sink.offline = false;
      now = now.add(const Duration(seconds: 5));
      await sync.pushLive(row(2));
      expect(sink.live.length, 1);
      expect(sink.live.single['elapsed_s'], 2, reason: '최신 값만 올린다');
    });

    test('라이브 실패가 세션 업로드를 막지 않는다', () async {
      sink.offline = true;
      await sync.pushLive(row(1));
      sink.offline = false;
      await store.saveSession(summary('s1'));
      expect(await sync.flush(), 1);
    });
  });

  group('원격 중단', () {
    test('수신 즉시 자극을 끄고 acked/executed를 기록한다', () async {
      var stopped = false;
      final handler = RemoteCommandHandler(
        sink,
        now: () => now,
        onStop: () async => stopped = true,
      );

      await handler.handle(const RemoteCommand(
          id: 'c1', sessionId: 's1', command: 'stop'));

      expect(stopped, isTrue);
      expect(sink.acks.length, 1);
      expect(sink.acks.single['status'], 'executed');
      expect(sink.acks.single['acked_at'], isNotNull);
      expect(sink.acks.single['executed_at'], isNotNull);
    });

    test('자극 정지가 먼저고 보고는 나중이다', () async {
      final order = <String>[];
      final handler = RemoteCommandHandler(
        sink,
        now: () => now,
        onStop: () async => order.add('stop'),
      );
      await handler.handle(const RemoteCommand(
          id: 'c1', sessionId: 's1', command: 'stop'));
      order.add('ack');

      expect(order, ['stop', 'ack']);
    });

    test('보고가 실패해도 자극은 이미 꺼져 있다', () async {
      var stopped = false;
      sink.offline = true;
      final handler = RemoteCommandHandler(
        sink,
        now: () => now,
        onStop: () async => stopped = true,
      );

      await handler.handle(const RemoteCommand(
          id: 'c1', sessionId: 's1', command: 'stop'));

      expect(stopped, isTrue,
          reason: '네트워크 때문에 자극이 안 꺼지면 안 된다');
    });

    test('같은 명령을 두 번 받아도 한 번만 실행한다', () async {
      var count = 0;
      final handler = RemoteCommandHandler(
        sink,
        now: () => now,
        onStop: () async => count++,
      );
      const cmd =
          RemoteCommand(id: 'c1', sessionId: 's1', command: 'stop');
      await handler.handle(cmd);
      await handler.handle(cmd);

      expect(count, 1);
    });

    test('모르는 명령은 실행하지 않고 failed로 보고한다', () async {
      var stopped = false;
      final handler = RemoteCommandHandler(
        sink,
        now: () => now,
        onStop: () async => stopped = true,
      );
      await handler.handle(const RemoteCommand(
          id: 'c1', sessionId: 's1', command: 'launch_missiles'));

      expect(stopped, isFalse);
      expect(sink.acks.single['status'], 'failed');
    });
  });
}
