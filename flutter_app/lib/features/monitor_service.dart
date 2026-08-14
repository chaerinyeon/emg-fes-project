import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart' show rootBundle;

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
  ///
  /// **저장된 값을 읽는다.** 예전에는 여기서 `makeToken()` 을 직접 불러
  /// 앱을 켤 때마다 코드가 바뀌었다 — 주석은 "안 바뀐다"였는데 실제로는
  /// 매번 바뀌어서, 어제 적어 둔 주소가 오늘 403 이 됐다.
  late final String _token = gApp.settings.monitorToken;

  /// 서버가 떠 있는가.
  bool get isRunning => _broadcaster != null;

  /// 실시간 화면 주소. IP 를 못 찾았으면 null.
  String? get url => _endpoint?.url;

  /// **USB 로 붙은 노트북**에서 열 주소.
  ///
  /// 서버는 `InternetAddress.anyIPv4` 에 붙어 있어 Wi-Fi 뿐 아니라 USB
  /// 터널로도 같은 포트가 열린다. 맥에서 [usbCommand] 를 한 번 띄우면
  /// 이 주소가 그대로 통한다.
  ///
  /// **Wi-Fi 주소와 달리 안 바뀐다.** IP 가 개입하지 않고(항상 localhost),
  /// 접속 코드는 저장돼 있다. 망을 옮기든 병원 Wi-Fi 가 기기 간 통신을
  /// 막든 상관없다.
  String? get usbUrl {
    final ep = _endpoint;
    if (ep == null) return null;
    return 'http://localhost:${ep.port}/?k=${ep.token}';
  }

  /// 노트북에서 한 번 띄워 두는 명령. 케이블이 물려 있는 동안 계속 산다.
  String? get usbCommand {
    final ep = _endpoint;
    return ep == null ? null : 'iproxy ${ep.port} ${ep.port}';
  }

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

  Timer? _addressWatch;

  bool _disposed = false;

  /// 빌드 도중에 난 알림은 다음 프레임으로 미룬다.
  ///
  /// [attachSession] 은 훈련 화면의 `initState` 에서 불린다 — 거기는 **빌드
  /// 단계 안**이라, 그 자리에서 알리면 다른 가지에 있는 구독자(설정 탭의
  /// `ListenableBuilder`)를 빌드 중에 더럽히게 된다. Flutter 는 이번 프레임에
  /// 그 위젯을 다시 방문한다고 보장할 수 없어 assertion 으로 막는다.
  ///
  /// 미루는 것은 **알림 한 장**뿐이다. 상태는 그대로 즉시 바뀌므로
  /// `hasLiveSession` 같은 값을 곧바로 읽어도 최신이고, 화면만 다음 프레임에
  /// 따라온다.
  ///
  /// 호출자마다 `addPostFrameCallback` 을 씌우지 않고 여기 한 곳에서 처리한다 —
  /// 나중에 다른 화면이 이 서비스를 붙였다 뗄 때 같은 사고를 반복하지 않는다.
  void _notify() {
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (!_disposed) notifyListeners();
      });
      return;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    // 주소 감시는 5초마다 알림을 낸다. 살려 두면 죽은 서비스에 대고
    // notifyListeners 를 불러 예외가 난다.
    _addressWatch?.cancel();
    _addressWatch = null;
    super.dispose();
  }

  /// 주소를 다시 확인하는 주기.
  ///
  /// 망 전환은 드문 사건이지만, 틀린 주소를 띄워 둔 채 치료사가 노트북 앞에서
  /// 헤매는 시간이 훨씬 비싸다. [NetworkInterface.list] 는 로컬 조회라 5초마다
  /// 불러도 부담이 없고, [refreshAddress] 는 IP 가 실제로 바뀌었을 때만
  /// 알림을 내므로 불필요한 리빌드도 생기지 않는다.
  static const Duration _addressWatchPeriod = Duration(seconds: 5);

  void _startAddressWatch() {
    _addressWatch?.cancel();
    _addressWatch =
        Timer.periodic(_addressWatchPeriod, (_) => unawaited(refreshAddress()));
  }

  Future<void> enable() async {
    if (_broadcaster != null) return;
    try {
      final b = MonitorBroadcaster(
        pageLoader: () => rootBundle.loadString('assets/web/monitor.html'),
        helloBuilder: _buildHello,
        token: _token,
        extraHandler: _serve,
        onError: _noteServeError,
      );
      final ep = await b.start();
      if (ep == null) {
        lastError = '포트를 열지 못했어요 (8080~8090 사용 중)';
        _notify();
        return;
      }
      _broadcaster = b;
      _endpoint = ep;
      lastError = ep.ip == null ? 'Wi-Fi 주소를 찾지 못했어요' : null;
      _startAddressWatch();
    } catch (e) {
      lastError = '$e';
    }
    _notify();
  }

  /// 웹 요청 처리 중 난 마지막 오류. 설정 탭이 이걸 그대로 보여 준다.
  ///
  /// 500 본문은 브라우저까지 가야 보이는데, 탭이 옛 페이지를 들고 있으면
  /// 그 한 줄이 화면에 안 뜬다. 그때 폰 화면이 두 번째 경로가 된다.
  String? lastServeError;

  void _noteServeError(Uri uri, Object error) {
    // 예외의 toString 이 다시 던질 수 있다. 그러면 타입 이름이라도 남긴다 —
    // 진단 경로가 스스로 무너지면 아무것도 안 하느니만 못하다.
    String reason;
    try {
      reason = error.toString();
    } catch (_) {
      reason = error.runtimeType.toString();
    }
    lastServeError = '${uri.path} → $reason';
    // 개발 중에는 콘솔이 가장 빠른 경로다.
    debugPrint('[monitor] 요청 처리 실패: $lastServeError');
    _notify();
  }

  /// 표시할 주소를 **지금 망 기준으로** 다시 잡는다.
  ///
  /// ## 왜 필요한가
  ///
  /// 서버는 앱이 켜질 때 한 번 뜨고([main]), 그때의 IP 가 [_endpoint] 에
  /// 박힌다. 그 뒤 폰이 Wi-Fi 를 옮기면 — 병원 망 → 집 공유기, 핫스팟 켜기 —
  /// 화면에 적힌 주소는 **어느 망에도 존재하지 않는 IP** 가 된다. 치료사는
  /// 그 주소를 노트북에 그대로 옮겨 적고 `ERR_CONNECTION_TIMED_OUT` 만 본다.
  /// 원인이 화면에 드러나지 않으니 앱이 고장 난 것처럼 보인다.
  ///
  /// 서버 자체는 `anyIPv4` 라 새 망에서도 멀쩡히 듣고 있다. 껐다 켜지 않고
  /// 주소만 새로 잡으면 되고, 그래서 포트와 접속 코드도 그대로 유지된다.
  Future<void> refreshAddress() async {
    final b = _broadcaster;
    if (b == null) return;
    final ep = await b.refreshAddress();
    if (ep == null || ep.ip == _endpoint?.ip) return;
    _endpoint = ep;
    lastError = ep.ip == null ? 'Wi-Fi 주소를 찾지 못했어요' : null;
    _notify();
  }

  Future<void> disable() async {
    _addressWatch?.cancel();
    _addressWatch = null;
    _live?.stop();
    _live = null;
    final b = _broadcaster;
    _broadcaster = null;
    _endpoint = null;
    await b?.stop();
    _notify();
  }

  /// 훈련이 시작됐다 — 실시간 프레임을 흘리기 시작한다.
  ///
  /// 서버가 꺼져 있으면 아무 일도 하지 않는다. 관찰은 선택이고, 훈련이
  /// 관찰 때문에 달라져서는 안 된다.
  void attachSession(SessionOrchestrator o) {
    final b = _broadcaster;
    if (b == null || _live != null) return;
    final source = RefitMonitorSource(
      orchestrator: o,
      sink: BroadcasterSink(b),
    );
    source.start();
    _live = source;
    _notify();
  }

  void detachSession() {
    _live?.stop();
    _live = null;
    _notify();
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
      return MonitorPayload(
        jsonEncode({
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
        }),
      );
    }

    const prefix = '/api/sessions/';
    if (path.startsWith(prefix)) {
      final id = Uri.decodeComponent(path.substring(prefix.length));
      final s = await gApp.store.session(id);
      if (s == null) return null;
      final series = await gApp.store.series(id);
      return MonitorPayload(
        jsonEncode({
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
        }),
      );
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
