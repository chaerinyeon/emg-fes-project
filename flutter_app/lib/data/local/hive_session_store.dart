import 'package:hive/hive.dart';

import 'session_store.dart';

/// Hive 기반 영속 저장소.
///
/// **오프라인에서도 훈련은 끝까지** 되려면 기록이 프로세스보다 오래
/// 살아남아야 한다. 앱이 죽었다 켜져도 업로드 대기열이 그대로 남는다.
///
/// 왜 Hive 인가 — 앱 개발 프롬프트는 drift(SQLite)를 지정하지만,
/// drift 는 새 의존성 + build_runner 코드생성이 필요하다. Hive 는 이미
/// 이 프로젝트 의존성에 있고 codegen 없이 쓸 수 있어, 지금 단계에서
/// 빌드를 흔들지 않고 내구성을 확보한다. [SessionStore] 인터페이스
/// 뒤에 있으므로 drift 로 갈아끼우는 것은 이 파일 하나 교체다.
/// 월 캘린더 집계(단계 6)에서 쿼리가 필요해지면 그때 옮기는 게 맞다.
class HiveSessionStore implements SessionStore {
  HiveSessionStore._(this._sessions, this._series, this._events);

  static const _sessionsBox = 'refit_sessions';
  static const _seriesBox = 'refit_series';
  static const _eventsBox = 'refit_events';

  final Box<dynamic> _sessions;
  final Box<dynamic> _series;
  final Box<dynamic> _events;

  /// `Hive.init(path)` (또는 `Hive.initFlutter()`) 이후에 부른다.
  static Future<HiveSessionStore> open() async {
    final s = await Hive.openBox<dynamic>(_sessionsBox);
    final se = await Hive.openBox<dynamic>(_seriesBox);
    final ev = await Hive.openBox<dynamic>(_eventsBox);
    return HiveSessionStore._(s, se, ev);
  }

  Future<void> close() async {
    await _sessions.close();
    await _series.close();
    await _events.close();
  }

  @override
  Future<void> saveSession(SessionSummary s) =>
      _sessions.put(s.id, s.toLocalJson());

  @override
  Future<SessionSummary?> session(String id) async {
    final raw = _sessions.get(id);
    if (raw == null) return null;
    return SessionSummary.fromJson((raw as Map).cast<dynamic, dynamic>());
  }

  @override
  Future<List<SessionSummary>> allSessions() async => _sessions.values
      .map((r) => SessionSummary.fromJson((r as Map).cast<dynamic, dynamic>()))
      .toList();

  @override
  Future<List<SessionSummary>> unsyncedSessions() async =>
      (await allSessions()).where((s) => !s.synced).toList()
        ..sort((a, b) => a.startedAt.compareTo(b.startedAt));

  @override
  Future<void> markSynced(String id) async {
    final s = await session(id);
    if (s == null) return;
    await _sessions.put(id, (s..synced = true).toLocalJson());
  }

  @override
  Future<void> appendBursts(List<BurstRow> rows) async {
    if (rows.isEmpty) return;
    // 세션당 한 덩어리로 보관한다. 340행 × 수십 바이트라 통째로 읽어도
    // 부담이 없고, 행마다 키를 만들면 삭제·조회가 오히려 느려진다.
    final byId = <String, List<Map<String, dynamic>>>{};
    for (final r in rows) {
      (byId[r.sessionId] ??= <Map<String, dynamic>>[]).add(r.toJson());
    }
    for (final entry in byId.entries) {
      final existing =
          (_series.get(entry.key) as List<dynamic>?) ?? const <dynamic>[];
      await _series.put(entry.key, [...existing, ...entry.value]);
    }
  }

  @override
  Future<List<BurstRow>> series(String sessionId) async {
    final raw = _series.get(sessionId) as List<dynamic>?;
    if (raw == null) return const [];
    return raw
        .map((r) => BurstRow.fromJson((r as Map).cast<dynamic, dynamic>()))
        .toList();
  }

  @override
  Future<void> appendEvent(SessionEventRow e) async {
    final existing =
        (_events.get(e.sessionId) as List<dynamic>?) ?? const <dynamic>[];
    await _events.put(e.sessionId, [...existing, e.toJson()]);
  }

  @override
  Future<List<SessionEventRow>> events(String sessionId) async {
    final raw = _events.get(sessionId) as List<dynamic>?;
    if (raw == null) return const [];
    return raw
        .map((r) =>
            SessionEventRow.fromJson((r as Map).cast<dynamic, dynamic>()))
        .toList();
  }

  @override
  Future<void> deleteSession(String id) async {
    await _sessions.delete(id);
    await _series.delete(id);
    await _events.delete(id);
  }
}
