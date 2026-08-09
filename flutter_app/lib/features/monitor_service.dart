import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../monitor/monitor_address.dart';
import '../monitor/monitor_broadcaster.dart';
import '../monitor/monitor_frame.dart';
import '../monitor/monitor_source.dart' show BroadcasterSink;
import '../monitor/refit_monitor_source.dart';
import '../session/end_conditions.dart';
import 'app_state.dart';
import 'session/session_orchestrator.dart';

/// 노트북에서 보는 화면(웹)의 수명 관리자.
///
/// ## 왜 세션이 아니라 앱에 매다는가
///
/// 처음에는 서버를 세션에 묶었다 — 훈련이 끝나면 서버도 내려갔다. 그러면
/// 치료사가 **지난 기록을 보려고 매번 훈련을 시작해야 한다.** 기록 조회는
/// 세션과 아무 상관이 없는 일이라, 서버는 앱이 켜져 있는 동안 살아 있고
/// 세션은 그 위에 **붙었다 떨어진다**([attachSession]).
///
/// ## 그래도 지난 값을 "지금"으로 그리지 않는다
///
/// 세션이 붙어 있지 않으면 tick 이 아예 나가지 않고, hello 의 링크 상태는
/// `idle` 이다. 훈련이 끝난 화면이 마지막 값을 계속 붙들고 있으면 그게
/// "지금"으로 읽히는데, 그건 관찰 화면이 할 수 있는 가장 나쁜 거짓말이다.
class MonitorService extends ChangeNotifier {
  MonitorBroadcaster? _broadcaster;
  RefitMonitorSource? _live;
  MonitorEndpoint? _endpoint;

  /// 세션 전체·앱 전체에서 고정. 재시작해도 치료사가 적어 둔 주소가 안 바뀐다.
  final String _token = makeToken();

  /// 서버가 떠 있는가.
  bool get isRunning => _broadcaster != null;

  /// 실시간 화면 주소. IP 를 못 찾았으면 null.
  String? get url => _endpoint?.url;

  /// 기록 화면 주소. 훈련 중이 아니어도 열린다.
  String? get recordsUrl {
    final ep = _endpoint;
    if (ep?.ip == null) return null;
    return 'http://${ep!.ip}:${ep.port}/records?k=${ep.token}';
  }

  /// 지금 훈련이 붙어 있는가.
  bool get hasLiveSession => _live != null;

  /// 마지막 실패 원인. 성공하면 null.
  String? lastError;

  Future<void> enable() async {
    if (_broadcaster != null) return;
    try {
      final b = MonitorBroadcaster(
        pageLoader: () => rootBundle.loadString('assets/web/monitor.html'),
        helloBuilder: _buildHello,
        token: _token,
        extraHandler: _serve,
      );
      final ep = await b.start();
      if (ep == null) {
        lastError = '포트를 열지 못했어요 (8080~8090 사용 중)';
        notifyListeners();
        return;
      }
      _broadcaster = b;
      _endpoint = ep;
      lastError = ep.ip == null ? 'Wi-Fi 주소를 찾지 못했어요' : null;
    } catch (e) {
      lastError = '$e';
    }
    notifyListeners();
  }

  Future<void> disable() async {
    _live?.stop();
    _live = null;
    final b = _broadcaster;
    _broadcaster = null;
    _endpoint = null;
    await b?.stop();
    notifyListeners();
  }

  /// 훈련이 시작됐다 — 실시간 프레임을 흘리기 시작한다.
  ///
  /// 서버가 꺼져 있으면 아무 일도 하지 않는다. 관찰은 선택이고, 훈련이
  /// 관찰 때문에 달라져서는 안 된다.
  void attachSession(SessionOrchestrator o) {
    final b = _broadcaster;
    if (b == null || _live != null) return;
    final source = RefitMonitorSource(orchestrator: o, sink: BroadcasterSink(b));
    source.start();
    _live = source;
    notifyListeners();
  }

  void detachSession() {
    _live?.stop();
    _live = null;
    notifyListeners();
  }

  MonitorHello _buildHello() {
    final live = _live;
    if (live != null) return live.buildHello('RE-FIT 세션');
    // 훈련 중이 아니다. 비어 있는 것을 비어 있다고 말한다.
    return const MonitorHello(
      session: '훈련 중이 아님',
      startedAtMs: 0,
      mu0: null,
      sd0: null,
      t1: null,
      t2: null,
      t3: null,
      link: 'idle',
      ticks: [],
    );
  }

  // ── 기록 조회 ───────────────────────────────────────────
  //
  // 폰이 자기 저장소를 그대로 내준다. 서버도 계정도 없고, 데이터가 이
  // 기기 밖으로 나가지 않는다.

  Future<MonitorPayload?> _serve(Uri uri) async {
    final path = uri.path;

    if (path == '/records' || path == '/records.html') {
      return MonitorPayload(
        await rootBundle.loadString('assets/web/records.html'),
        contentType: 'text/html; charset=utf-8',
      );
    }

    if (path == '/api/sessions') {
      // 선택된 환자의 것만. **환자 간 비교·순위를 만들지 않는다**(하드 제약 6).
      final rows = gApp.patientSessions;
      return MonitorPayload(jsonEncode({
        'patient': gApp.patient?.name,
        'sessions': [
          for (final s in rows)
            {
              'id': s.id,
              'started_at': s.startedAt.toIso8601String(),
              'duration_s': s.durationS,
              'rep_count': s.repCount,
              'success_rate': s.successRate,
              'end_reason': s.endReason.code,
              'end_reason_label': _endReasonLabel(s.endReason),
              'grade': s.reliabilityGrade,
              'synced': s.synced,
            },
        ],
      }));
    }

    const prefix = '/api/sessions/';
    if (path.startsWith(prefix)) {
      final id = Uri.decodeComponent(path.substring(prefix.length));
      final s = await gApp.store.session(id);
      if (s == null) return null;
      final series = await gApp.store.series(id);
      return MonitorPayload(jsonEncode({
        'id': s.id,
        'started_at': s.startedAt.toIso8601String(),
        'duration_s': s.durationS,
        'rep_count': s.repCount,
        'success_rate': s.successRate,
        'end_reason_label': _endReasonLabel(s.endReason),
        'max_fatigue': s.maxFatigue,
        'end_fatigue': s.endFatigue,
        'onset_s': s.onsetS,
        'detect_rate': s.detectRate,
        'events_per_burst_median': s.eventsPerBurstMedian,
        'level_change_count': s.levelChangeCount,
        'grade': s.reliabilityGrade,
        'stim_period_ms': s.stimPeriodMs,
        'intensity_level': s.intensityLevel,
        // 버스트 단위 요약만 있다. 원시 파형(1kHz)은 앱에 저장하지 않는다.
        'series': [
          for (final r in series)
            {
              't': r.tS,
              'p2p': r.p2p,
              'fatigue': r.fatigue,
              'rms': r.rms,
              'mdf': r.mdf,
              'ok': r.contractionOk,
            },
        ],
      }));
    }

    return null;
  }

  static String _endReasonLabel(SessionEndReason r) => switch (r) {
        SessionEndReason.fatigueThreshold => '피로 임계',
        SessionEndReason.successRateDrop => '성공률 하락',
        SessionEndReason.gameComplete => '목표 달성',
        SessionEndReason.timeout => '시간 상한',
        SessionEndReason.userStop => '사용자 중단',
        SessionEndReason.remoteStop => '원격 중단',
        SessionEndReason.signalLost => '신호 유실',
        SessionEndReason.deviceDisconnect => '기기 끊김',
        SessionEndReason.error => '오류',
      };
}

final MonitorService gMonitor = MonitorService();
