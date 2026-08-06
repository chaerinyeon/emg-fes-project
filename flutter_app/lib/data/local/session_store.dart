import '../../session/end_conditions.dart';

/// `session_events.type` (공통 컨텍스트 6장).
enum SessionEventType {
  levelChange('level_change'),
  signalWarning('signal_warning'),
  userPause('user_pause'),
  remoteStop('remote_stop'),
  stimOff('stim_off');

  const SessionEventType(this.code);
  final String code;

  static SessionEventType fromCode(String c) =>
      SessionEventType.values.firstWhere((e) => e.code == c);
}

/// `sessions` 한 행.
///
/// 웹의 목록·요약 화면 전부를 이 한 행이 커버해야 한다.
/// [synced] 는 **로컬 전용**이라 업로드 payload 에 들어가지 않는다.
class SessionSummary {
  final String id;
  final String patientId;
  final String deviceId;
  final DateTime startedAt;
  final DateTime? endedAt;
  final int durationS;
  final String gameId;
  final String stageId;
  final int intensityLevel;
  final SessionEndReason endReason;
  final int repCount;
  final double successRate;

  /// 전부 **적응형 기준**이다. 전역 기준은 참고용이라 여기 넣지 않는다.
  final double maxFatigue;
  final double endFatigue;
  final double? onsetS;

  final int burstCount;
  final double detectRate;
  final double eventsPerBurstMedian;
  final int levelChangeCount;
  final String reliabilityGrade;
  final int stimPeriodMs;
  final String appVersion;
  final String fwVersion;

  final bool synced;

  const SessionSummary({
    required this.id,
    required this.patientId,
    required this.deviceId,
    required this.startedAt,
    required this.endedAt,
    required this.durationS,
    required this.gameId,
    required this.stageId,
    required this.intensityLevel,
    required this.endReason,
    required this.repCount,
    required this.successRate,
    required this.maxFatigue,
    required this.endFatigue,
    required this.onsetS,
    required this.burstCount,
    required this.detectRate,
    required this.eventsPerBurstMedian,
    required this.levelChangeCount,
    required this.reliabilityGrade,
    required this.stimPeriodMs,
    required this.appVersion,
    required this.fwVersion,
    this.synced = false,
  });

  SessionSummary copyWith({bool? synced}) => SessionSummary(
        id: id,
        patientId: patientId,
        deviceId: deviceId,
        startedAt: startedAt,
        endedAt: endedAt,
        durationS: durationS,
        gameId: gameId,
        stageId: stageId,
        intensityLevel: intensityLevel,
        endReason: endReason,
        repCount: repCount,
        successRate: successRate,
        maxFatigue: maxFatigue,
        endFatigue: endFatigue,
        onsetS: onsetS,
        burstCount: burstCount,
        detectRate: detectRate,
        eventsPerBurstMedian: eventsPerBurstMedian,
        levelChangeCount: levelChangeCount,
        reliabilityGrade: reliabilityGrade,
        stimPeriodMs: stimPeriodMs,
        appVersion: appVersion,
        fwVersion: fwVersion,
        synced: synced ?? this.synced,
      );

  /// 업로드 payload. [synced] 는 빠진다.
  Map<String, dynamic> toJson() => {
        'id': id,
        'patient_id': patientId,
        'device_id': deviceId,
        'started_at': startedAt.toIso8601String(),
        'ended_at': endedAt?.toIso8601String(),
        'duration_s': durationS,
        'game_id': gameId,
        'stage_id': stageId,
        'intensity_level': intensityLevel,
        'end_reason': endReason.code,
        'rep_count': repCount,
        'success_rate': successRate,
        'max_fatigue': maxFatigue,
        'end_fatigue': endFatigue,
        'onset_s': onsetS,
        'burst_count': burstCount,
        'detect_rate': detectRate,
        'events_per_burst_median': eventsPerBurstMedian,
        'level_change_count': levelChangeCount,
        'reliability_grade': reliabilityGrade,
        'stim_period_ms': stimPeriodMs,
        'app_version': appVersion,
        'fw_version': fwVersion,
      };

  static SessionSummary fromJson(Map<dynamic, dynamic> j) => SessionSummary(
        id: j['id'] as String,
        patientId: j['patient_id'] as String,
        deviceId: j['device_id'] as String,
        startedAt: DateTime.parse(j['started_at'] as String),
        endedAt: j['ended_at'] == null
            ? null
            : DateTime.parse(j['ended_at'] as String),
        durationS: (j['duration_s'] as num).toInt(),
        gameId: j['game_id'] as String,
        stageId: j['stage_id'] as String,
        intensityLevel: (j['intensity_level'] as num).toInt(),
        endReason: SessionEndReason.values
            .firstWhere((e) => e.code == j['end_reason']),
        repCount: (j['rep_count'] as num).toInt(),
        successRate: (j['success_rate'] as num).toDouble(),
        maxFatigue: (j['max_fatigue'] as num).toDouble(),
        endFatigue: (j['end_fatigue'] as num).toDouble(),
        onsetS: (j['onset_s'] as num?)?.toDouble(),
        burstCount: (j['burst_count'] as num).toInt(),
        detectRate: (j['detect_rate'] as num).toDouble(),
        eventsPerBurstMedian:
            (j['events_per_burst_median'] as num).toDouble(),
        levelChangeCount: (j['level_change_count'] as num).toInt(),
        reliabilityGrade: j['reliability_grade'] as String,
        stimPeriodMs: (j['stim_period_ms'] as num).toInt(),
        appVersion: j['app_version'] as String,
        fwVersion: j['fw_version'] as String,
        synced: (j['synced'] as bool?) ?? false,
      );

  /// 로컬 저장용 (synced 포함).
  Map<String, dynamic> toLocalJson() => toJson()..['synced'] = synced;
}

/// `session_series` 한 행 — 버스트 단위. **raw 는 저장하지 않는다.**
class BurstRow {
  final String sessionId;
  final double tS;
  final double p2p;
  final double fatigue;
  final bool contractionOk;
  final bool valid;

  const BurstRow({
    required this.sessionId,
    required this.tS,
    required this.p2p,
    required this.fatigue,
    required this.contractionOk,
    required this.valid,
  });

  Map<String, dynamic> toJson() => {
        'session_id': sessionId,
        't_s': tS,
        'p2p': p2p,
        'fatigue': fatigue,
        'contraction_ok': contractionOk,
        'valid': valid,
      };

  static BurstRow fromJson(Map<dynamic, dynamic> j) => BurstRow(
        sessionId: j['session_id'] as String,
        tS: (j['t_s'] as num).toDouble(),
        p2p: (j['p2p'] as num).toDouble(),
        fatigue: (j['fatigue'] as num).toDouble(),
        contractionOk: j['contraction_ok'] as bool,
        valid: j['valid'] as bool,
      );
}

/// `session_events` 한 행.
class SessionEventRow {
  final String sessionId;
  final double tS;
  final SessionEventType type;
  final String actor;
  final Map<String, dynamic>? payload;

  const SessionEventRow({
    required this.sessionId,
    required this.tS,
    required this.type,
    required this.actor,
    this.payload,
  });

  Map<String, dynamic> toJson() => {
        'session_id': sessionId,
        't_s': tS,
        'type': type.code,
        'actor': actor,
        'payload': payload,
      };

  static SessionEventRow fromJson(Map<dynamic, dynamic> j) => SessionEventRow(
        sessionId: j['session_id'] as String,
        tS: (j['t_s'] as num).toDouble(),
        type: SessionEventType.fromCode(j['type'] as String),
        actor: j['actor'] as String,
        payload: (j['payload'] as Map?)?.cast<String, dynamic>(),
      );
}

/// `session_live` 한 행 — 세션당 1행 upsert (웹 라이브 뷰용).
class LiveRow {
  final String sessionId;
  final DateTime updatedAt;
  final int elapsedS;
  final int repCount;
  final double fatigue;
  final double successRate50;
  final String signalQuality;
  final String state;

  const LiveRow({
    required this.sessionId,
    required this.updatedAt,
    required this.elapsedS,
    required this.repCount,
    required this.fatigue,
    required this.successRate50,
    required this.signalQuality,
    required this.state,
  });

  Map<String, dynamic> toJson() => {
        'session_id': sessionId,
        'updated_at': updatedAt.toIso8601String(),
        'elapsed_s': elapsedS,
        'rep_count': repCount,
        'fatigue': fatigue,
        'success_rate_50': successRate50,
        'signal_quality': signalQuality,
        'state': state,
      };
}

/// 로컬 저장소.
///
/// **오프라인에서도 훈련은 끝까지 되어야 한다.** 업로드는 나중 문제이고,
/// 기록은 언제나 로컬에 먼저 확정된다.
abstract class SessionStore {
  Future<void> saveSession(SessionSummary s);
  Future<SessionSummary?> session(String id);
  Future<List<SessionSummary>> allSessions();
  Future<List<SessionSummary>> unsyncedSessions();
  Future<void> markSynced(String id);

  Future<void> appendBursts(List<BurstRow> rows);
  Future<List<BurstRow>> series(String sessionId);

  Future<void> appendEvent(SessionEventRow e);
  Future<List<SessionEventRow>> events(String sessionId);

  Future<void> deleteSession(String id);
}

/// 테스트·프로토타입용 인메모리 구현.
class InMemorySessionStore implements SessionStore {
  final Map<String, SessionSummary> _sessions = {};
  final Map<String, List<BurstRow>> _series = {};
  final Map<String, List<SessionEventRow>> _events = {};

  @override
  Future<void> saveSession(SessionSummary s) async => _sessions[s.id] = s;

  @override
  Future<SessionSummary?> session(String id) async => _sessions[id];

  @override
  Future<List<SessionSummary>> allSessions() async =>
      _sessions.values.toList();

  @override
  Future<List<SessionSummary>> unsyncedSessions() async =>
      _sessions.values.where((s) => !s.synced).toList()
        ..sort((a, b) => a.startedAt.compareTo(b.startedAt));

  @override
  Future<void> markSynced(String id) async {
    final s = _sessions[id];
    if (s != null) _sessions[id] = s.copyWith(synced: true);
  }

  @override
  Future<void> appendBursts(List<BurstRow> rows) async {
    for (final r in rows) {
      (_series[r.sessionId] ??= <BurstRow>[]).add(r);
    }
  }

  @override
  Future<List<BurstRow>> series(String sessionId) async =>
      List.of(_series[sessionId] ?? const []);

  @override
  Future<void> appendEvent(SessionEventRow e) async =>
      (_events[e.sessionId] ??= <SessionEventRow>[]).add(e);

  @override
  Future<List<SessionEventRow>> events(String sessionId) async =>
      List.of(_events[sessionId] ?? const []);

  @override
  Future<void> deleteSession(String id) async {
    _sessions.remove(id);
    _series.remove(id);
    _events.remove(id);
  }
}
