import '../local/session_store.dart';
import 'remote_sink.dart';

export 'remote_sink.dart' show RemoteCommand;

/// `session_live` 최소 upsert 간격(초). 공통 컨텍스트: 2~5초.
const int kLiveUpsertIntervalS = 3;

/// 로컬 → 원격 동기화 정책.
///
/// **오프라인에서도 훈련은 끝까지 되어야 한다.** 기록은 언제나 로컬에
/// 먼저 확정되고, 업로드는 나중에 따라간다. 업로드가 실패하면
/// `synced` 를 찍지 않고 그대로 둔다 — 올라가지도 않았는데 완료로
/// 표시하면 그 세션은 영영 사라진다.
class SyncService {
  SyncService(this.store, this.sink, {DateTime Function()? now})
      : _now = now ?? DateTime.now;

  final SessionStore store;
  final RemoteSink sink;
  final DateTime Function() _now;

  DateTime? _lastLiveAt;

  /// 밀린 세션을 오래된 순서로 올린다. 올라간 개수를 반환한다.
  ///
  /// 하나가 실패해도 멈추지 않는다 — 한 세션의 문제로 나머지가 볼모가
  /// 되면 안 된다. 실패한 것은 다음 [flush] 에서 다시 시도된다.
  Future<int> flush() async {
    final pending = await store.unsyncedSessions();
    var count = 0;

    for (final s in pending) {
      try {
        final series = await store.series(s.id);
        final events = await store.events(s.id);
        await sink.uploadSession(
          summary: s.toJson(),
          series: series.map((r) => r.toJson()).toList(),
          events: events.map((e) => e.toJson()).toList(),
        );
        await store.markSynced(s.id);
        count++;
      } catch (_) {
        // 로컬에 그대로 남는다. 다음 기회에 다시 올린다.
        continue;
      }
    }
    return count;
  }

  /// 라이브 뷰 갱신. [kLiveUpsertIntervalS] 간격으로 throttle 한다.
  ///
  /// 실패해도 큐에 쌓지 않는다. 지난 라이브 값은 올라가 봐야 쓸모가 없고,
  /// 밀린 것을 뒤늦게 밀어 넣으면 웹이 과거 상태를 현재로 표시한다.
  Future<void> pushLive(LiveRow row) async {
    final now = _now();
    if (_lastLiveAt != null &&
        now.difference(_lastLiveAt!).inSeconds < kLiveUpsertIntervalS) {
      return;
    }
    _lastLiveAt = now;
    try {
      await sink.upsertLive(row.toJson());
    } catch (_) {
      // 버린다.
    }
  }
}

/// 원격 중단 명령 처리.
///
/// **원격 중단은 안전 기능의 1차가 될 수 없다**(하드 제약 8).
/// 로컬 자동 종료가 항상 1차이고 이것은 보조다. 그래서 여기서는
/// 네트워크 상태와 무관하게 자극을 먼저 끄고, 보고는 그 다음이다.
class RemoteCommandHandler {
  RemoteCommandHandler(
    this.sink, {
    required this.onStop,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final RemoteSink sink;

  /// 자극을 끄는 콜백. 예외를 던지지 않아야 한다.
  final Future<void> Function() onStop;

  final DateTime Function() _now;
  final Set<String> _handled = <String>{};

  Future<void> handle(RemoteCommand cmd) async {
    if (!_handled.add(cmd.id)) return; // 같은 명령 재수신 — 한 번만

    final acked = _now();

    if (cmd.command != 'stop') {
      await _report(cmd.id, 'failed', acked, null);
      return;
    }

    // 1) 자극부터 끈다. 네트워크가 죽어 있어도 여기는 반드시 돈다.
    await onStop();

    // 2) 그 다음에 보고한다. 실패해도 자극은 이미 꺼져 있다.
    await _report(cmd.id, 'executed', acked, _now());
  }

  Future<void> _report(
      String id, String status, DateTime acked, DateTime? executed) async {
    try {
      await sink.ackCommand(
        commandId: id,
        status: status,
        ackedAt: acked,
        executedAt: executed,
      );
    } catch (_) {
      // 보고 실패는 삼킨다. 안전 동작은 이미 끝났다.
    }
  }
}
