/// 원격 저장소로 나가는 출구.
///
/// Supabase 구현은 `supabase_flutter` 의존이 들어온 뒤 이 인터페이스에
/// 붙인다. 정책(큐·재시도·순서·오프라인)은 전부 [SyncService] 에 있고
/// 여기에는 전송만 있다 — 네트워크 없이 정책을 검증하기 위해서다.
abstract class RemoteSink {
  /// 세션 요약 + 시계열 + 이벤트 일괄 업로드.
  ///
  /// 셋이 원자적으로 올라가야 한다. 요약만 올라가고 시계열이 빠지면
  /// 웹 리포트가 빈 그래프를 그린다.
  Future<void> uploadSession({
    required Map<String, dynamic> summary,
    required List<Map<String, dynamic>> series,
    required List<Map<String, dynamic>> events,
  });

  /// `session_live` upsert (세션당 1행).
  Future<void> upsertLive(Map<String, dynamic> row);

  /// `remote_commands` 상태 보고.
  Future<void> ackCommand({
    required String commandId,
    required String status, // sent | acked | executed | failed
    DateTime? ackedAt,
    DateTime? executedAt,
  });
}

/// 서버에서 내려온 원격 명령 1건.
class RemoteCommand {
  final String id;
  final String sessionId;
  final String command;

  const RemoteCommand({
    required this.id,
    required this.sessionId,
    required this.command,
  });

  static RemoteCommand fromJson(Map<dynamic, dynamic> j) => RemoteCommand(
        id: j['id'] as String,
        sessionId: j['session_id'] as String,
        command: j['command'] as String,
      );
}
