import 'dart:async' show unawaited;

import 'package:flame/game.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../../monitor/monitor_address.dart';
import '../../monitor/monitor_broadcaster.dart';
import '../../monitor/monitor_source.dart';
import '../../services/session_controller.dart';
import '../../widgets/monitor/monitor_address_card.dart';
import '../data/fatigue_feed.dart';
import '../data/live_fatigue_feed.dart';
import '../data/mock_fatigue_feed.dart';
import '../engine/rest_policy.dart';
import '../flame/baseball_game.dart';
import '../model/zone.dart';
import 'widgets/rest_overlay.dart';
import 'widgets/session_hud.dart';

/// 캐치 게임 풀스크린 화면.
///
/// Flame 게임 위에 Flutter 위젯 HUD 를 얹는다(`overlayBuilderMap`).
/// 야구장·공·글러브는 Flame 이, σ 게이지·배너·휴식 오버레이는 Flutter 가 그린다.
///
/// ## 설계 원칙
///
/// - **스킬 판정 없음**: 완전마비 환자라 "수축=성공"으로 되먹임만 준다.
/// - **힘 크기 미사용**: 피로는 M-wave 기반 SPC σ 로만 판별하고, 게임에는
///   수축 **타이밍**만 쓴다.
/// - **SPC = 1차 라벨**(인과적·실시간·자기기준), **LSTM = 선제 예측**(겹쳐 표시).
/// - **피로가 점수를 깎지 않는다** — 애초에 점수가 없다. 위험 시 개입은
///   "휴식 이닝" 뿐이고 페널티 개념이 없다.
class GameScreen extends StatefulWidget {
  const GameScreen({super.key, this.session, this.feed});

  /// 실측 모드용 세션. 없으면 데모(재생) 피드를 쓴다.
  final SessionController? session;

  /// 직접 피드를 주입할 때(테스트·시연).
  final FatigueFeed? feed;

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> with WidgetsBindingObserver {
  late final FatigueFeed _feed;
  MonitorBroadcaster? _broadcaster;
  MonitorSource? _monitorSource;
  BroadcasterSink? _monitorSink;
  MonitorEndpoint? _monitorEndpoint;

  /// [_monitorEndpoint] 를 그대로 미러링한다. `showDialog` 로 띄운 주소
  /// 다이얼로그는 `_GameScreenState` 와 별개의 라우트(자기만의 Element 트리)
  /// 라 이 위젯의 `setState` 로는 재빌드되지 않는다 — 다이얼로그 안에서
  /// [ValueListenableBuilder] 로 이걸 구독해야 배경 전환으로 주소가
  /// null 이 돼도 다이얼로그가 죽은 주소를 계속 보여주지 않는다.
  final ValueNotifier<MonitorEndpoint?> _monitorEndpointNotifier =
      ValueNotifier<MonitorEndpoint?>(null);

  /// 접속 토큰. 세션 시작 시 한 번만 만들어 재사용한다 — 백그라운드 복귀로
  /// 방송기가 재생성돼도(아래 [_startMonitor] 참고) 같은 토큰이라 URL이
  /// 바뀌지 않고, 치료사가 열어 둔 브라우저 탭이 그대로 유효하다.
  late final String _monitorToken;

  /// [_startMonitor] 재진입 방지. [MonitorBroadcaster.start] 는 그 안에 await
  /// 지점이 두 번 있어, 그 사이에 `initState` 와 `didChangeAppLifecycleState`
  /// 양쪽에서 겹쳐 부르면 idempotency 체크(`_broadcaster?.endpoint != null`)를
  /// 둘 다 통과해 포트를 두 번 바인딩할 수 있다.
  bool _monitorStarting = false;

  /// 앱이 배경으로 간 뒤(또는 초기 바인딩 도중 배경으로 간) true. **이 위젯이
  /// 동기적으로** 관리한다 — [MonitorBroadcaster.endpoint] 는 [MonitorBroadcaster.stop]
  /// 이 소켓들을 다 닫은 *뒤에야* null 이 되므로, 그 필드로 resumed 를 게이팅하면
  /// stop() 이 아직 끝나지 않은 사이에 resumed 가 와서 게이트가 영영 안 열릴 수
  /// 있다(iOS는 paused 직후 곧바로 isolate 를 재운다).
  bool _monitorPaused = false;

  /// 가장 최근에 폐기 중인 [MonitorBroadcaster.stop]. resumed 에서 재바인딩하기
  /// 전에 이걸 먼저 기다려야 포트(예: 8080)가 OS 에 반환돼 같은 포트를 다시
  /// 잡을 수 있다. paused 브랜치와 [_startMonitor] 의 "좀비" 브랜치 양쪽에서
  /// 이 필드에 쓴다 — 어느 한쪽만 쓰면 다른 쪽에서 폐기한 방송기의 stop() 을
  /// 아무도 기다리지 않게 된다.
  Future<void>? _stopping;

  /// [_monitorStarting] 가드에 막혀 버려질 뻔한 재시작 요청. 가드를 통과하지
  /// 못한 `_startMonitor()` 호출은 그냥 사라지지 않고 이 플래그만 남긴다 —
  /// 지금 진행 중인 호출이 끝나면(`finally`) 이 플래그를 보고 자기 자신을
  /// 다시 부른다. 이게 없으면: paused→resumed 도중 다시 paused 가 껴들어 온
  /// 바인딩을 좀비로 만들고, 그 좀비를 정리하는 사이에 온 resumed 의
  /// `_startMonitor()` 호출이 가드에 막혀 조용히 사라져 모니터가 세션 내내
  /// 죽은 채로 남는다.
  bool _restartRequested = false;

  late final BaseballGame _game;
  late final bool _isMock;

  final RestPolicy _rest = RestPolicy();

  double? _sigma;
  double? _predicted;
  final List<({double t, double z})> _history = [];
  int _catches = 0;
  int _inning = 1;
  bool _resting = false;

  @override
  void initState() {
    super.initState();
    final injected = widget.feed;
    final session = widget.session;
    if (injected != null) {
      _feed = injected;
      _isMock = injected is MockFatigueFeed;
    } else if (session != null && session.connState == 'connected') {
      _feed = LiveFatigueFeed(session: session);
      _isMock = false;
    } else {
      // 센서가 없으면 실측 세션 **재생**으로 돈다. 가짜 신호를 지어내지 않고
      // 실제 기록을 트는 것이라, 화면에 어느 세션인지 그대로 표시한다.
      //
      // 배속을 걸지 않는다(등속). 배속은 자극 리듬까지 빨라지게 만들어 1.6초
      // 간격이던 수축이 겹치고 포구 연출이 무너진다. 앞부분 건너뛰기는
      // MockFatigueFeed 의 startAtSec 기본값이 처리한다.
      _feed = MockFatigueFeed();
      _isMock = true;
    }
    // 세션 전체에서 고정 — 방송기가 재생성돼도(백그라운드 복귀) 같은 URL 을
    // 유지하려면 토큰의 수명이 위젯(=게임 화면 한 판)과 같아야 한다.
    _monitorToken = makeToken();

    _game = BaseballGame(feed: _feed)..onCatch = _onCatch;
    _startMonitor();
    WidgetsBinding.instance.addObserver(this);
    _tickHud();
  }

  void _onCatch() {
    if (!mounted) return;
    setState(() => _catches = _game.catchCount);
  }

  /// σ·예측은 스트림으로 오고 Flame 이 들고 있다. HUD 는 프레임마다 읽어간다.
  void _tickHud() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final z = _game.sigmaNow;
      final p = _game.sigmaPredicted;
      final now = _game.feedNowSec;

      // 위험 도달 판단은 현재 σ 와 **예측 σ 중 더 나쁜 쪽**으로 한다.
      // 예측이 위험을 먼저 말하면 그때 쉬는 것이 선제 대응의 목적이다.
      final worst = [z, p].whereType<double>().fold<double?>(
            null,
            (a, b) => a == null || b > a ? b : a,
          );

      if (!_resting && _rest.shouldTriggerRest(now, worst)) {
        _resting = true;
        _game.setResting(true);
        // 휴식 이닝은 이 화면(정확히는 RestPolicy)만 안다 — 모니터가 그걸
        // 모르면 정지된 화면과 구분이 안 된다(Important 4). MonitorSource 가
        // 없어도(모니터 비활성) 게임은 그대로 진행돼야 하므로 `?.`.
        _monitorSource?.restStart(now);
      }

      if (z != _sigma || p != _predicted || _resting != _game.resting) {
        if (z != null && z != _sigma) _history.add((t: now, z: z));
        setState(() {
          _sigma = z;
          _predicted = p;
        });
      }
      _tickHud();
    });
  }

  void _finishRest() {
    final decision = _rest.finishRest(_sigma);
    final now = _game.feedNowSec;
    setState(() {
      _resting = false;
      _game.setResting(false);
      if (decision != RestDecision.endSession) _inning++;
    });
    _monitorSource?.restEnd(now);
  }

  String get _sourceLabel {
    final f = _feed;
    if (f is MockFatigueFeed) return '▶ 재생: ${f.sessionName}';
    return '실측 M-wave';
  }

  /// 관찰 서버를 올린다. 실패해도 게임은 그대로 진행된다 — 모든 예외를 여기서
  /// 삼켜, 콜백 내부 구현이 앞으로 바뀌어도 이 경계 자체가 방어선이 되게 한다.
  ///
  /// 두 번째 이후 호출(백그라운드 복귀)에서는 **방송기만** 새로 만들고 소스는
  /// 그대로 둔다. 소스를 다시 만들면 세션 시계와 링버퍼가 초기화된다.
  Future<void> _startMonitor() async {
    // dispose() 는 그 시점에 존재하는 _broadcaster/_monitorSource 만 안다.
    // _restartRequested 의 finally-재실행이 disposal 이후에 불릴 수 있는데
    // (예: 좀비 정리 도중 위젯이 통째로 pop 됐다), 그때 여기를 통과시키면
    // dispose() 가 모르는 새 소켓 바인딩이 시작돼 아무도 그걸 stop() 해줄
    // 사람이 없다 — 자기 자신의 `!mounted` 자가진단(아래)이 언젠가 정리는
    // 하지만, 그 사이 창이 열려 있는 동안 들어온 요청을 처리하다 이미 죽은
    // 위젯의 자원(예: 테스트에서는 다음 테스트로 넘어간 rootBundle mock)을
    // 참조해 엉뚱한 곳에서 예외가 튈 수 있다. 그래서 진입 자체를 막는다.
    if (!mounted) return;
    final session = widget.session;
    final feed = _feed;
    if (session == null || feed is! LiveFatigueFeed) return; // 목 피드는 방송하지 않는다
    if (_broadcaster?.endpoint != null) return; // 이미 떠 있다
    if (_monitorStarting) {
      // 이미 다른 _startMonitor() 호출이 진행 중이다. 그냥 버리면 안 된다 —
      // 그 호출이 시작된 뒤에 상황이 다시 바뀌었을 수 있다(예: paused 도중
      // 온 resumed). 표시만 해 두면 진행 중인 호출의 finally 가 끝나면서
      // 이 요청을 대신 재실행해 준다 (재발 방지 상세는 _restartRequested
      // 독스트링 참고).
      _restartRequested = true;
      return;
    }
    _monitorStarting = true;
    if (debugOnBindStarting != null) await debugOnBindStarting!();

    try {
      late final MonitorBroadcaster broadcaster;
      broadcaster = MonitorBroadcaster(
        pageLoader: () => rootBundle.loadString('assets/web/monitor.html'),
        helloBuilder: () =>
            _monitorSource!.buildHello(_sessionLabel()),
        token: _monitorToken, // 세션 전체에서 고정 — 재생성돼도 URL 이 안 바뀐다
      );

      var source = _monitorSource;
      if (source == null) {
        final sink = BroadcasterSink(broadcaster);
        source = MonitorSource(session: session, feed: feed, sink: sink);
        _monitorSink = sink;
        _monitorSource = source;
        source.start();
      } else {
        _monitorSink!.broadcaster = broadcaster; // 소스는 유지, 방송기만 교체
      }

      final ep = await broadcaster.start();
      if (!mounted || _monitorPaused) {
        // 위젯이 이미 죽었거나, 바인딩 도중(또는 그 사이) 앱이 배경으로
        // 갔다. 방금 띄운 방송기를 살려두면 화면엔 안 보이는 채로 OS 소켓만
        // 열려 있다가 재개 시 죽은 소켓 주소를 광고하게 된다.
        //
        // 이 stop() 도 _stopping 에 반드시 게시한다 — paused 브랜치만 쓰면
        // 여기서 폐기하는 방송기는 아무도 기다려주지 않아, resumed 가 재빨리
        // 다시 바인딩을 시도할 때 방금 닫기 시작한 포트를 놓고 경합한다.
        // 로컬 변수에 먼저 담아 두고 그걸 기다린다 — 아래 훅이 재진입해
        // `_stopping` 필드를 다시 null 로 되돌려도(정상적인 resumed 처리의
        // 일부다) 여기서 기다리는 대상은 바뀌지 않는다.
        final stopping = broadcaster.stop();
        _stopping = stopping;
        if (debugOnZombieStopping != null) await debugOnZombieStopping!();
        await stopping;
        return;
      }
      setState(() {
        _broadcaster = broadcaster;
        _monitorEndpoint = ep;
      });
      _monitorEndpointNotifier.value = ep;
    } catch (e) {
      // 모니터 실패가 게임·자극 경로로 절대 전파되지 않는다는 보장을 이 경계
      // 스스로도 갖는다 — 콜백들의 자체 삼킴에만 기대지 않는다. 다만 그냥
      // 삼키기만 하면 setState 실패나 helloBuilder 안의 _monitorSource!
      // 같은 진짜 프로그래밍 버그도 조용히 사라져 디버깅이 불가능해지므로
      // 로그는 남긴다.
      debugPrint('GameScreen._startMonitor 실패(격리됨, 세션엔 영향 없음): $e');
    } finally {
      _monitorStarting = false;
      if (_restartRequested) {
        _restartRequested = false;
        // 가드에 막혀 사라질 뻔한 재시작 요청을 지금 대신 실행한다 — 단,
        // 그 사이 위젯이 죽었으면 다시 부르지 않는다(맨 위의 `!mounted`
        // 체크가 어차피 걸러내지만, 여기서 거르면 불필요한 재바인딩 시도
        // 자체를 만들지 않는다).
        if (mounted) unawaited(_startMonitor());
      }
    }
  }

  String _sessionLabel() {
    final f = _feed;
    return f is MockFatigueFeed ? '재생: ${f.sessionName}' : '실측 세션';
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      // 폰 화면이 꺼지면 소켓이 죽는다. phone_background 이벤트로 미리 알리려
      // 해도 outbox 드레인은 16ms 주기 타이머가 처리하는데 stop() 이 그
      // 타이머부터 취소해 이벤트가 도착하기 전에 죽는다 — 그래서 이벤트는
      // 보내지 않는다. 웹은 소켓 종료 자체를 stale 신호로 받아들인다.
      //
      // _monitorPaused 는 _broadcaster 존재 여부와 무관하게 항상 세운다.
      // 아직 초기 바인딩 중(_broadcaster == null)이어도 표시해 둬야
      // _startMonitor 가 나중에 완료됐을 때 "배경에서 새로 뜬 좀비 엔드포인트"
      // 를 스스로 정리할 수 있다 (Finding 4).
      _monitorPaused = true;
      final b = _broadcaster;
      if (b != null) {
        _stopping = b.stop();
        // 이 핸들을 지운다 — 안 지우면 이 직후에 또 paused 가 오는(화면
        // 잠금·전화 수신 등) 경우 이미 죽은 b 를 또 stop() 해 _stopping 을
        // 의미 없는 no-op 으로 덮어써 버린다. 그 사이 진짜로 떠 있던 다음
        // 방송기(_startMonitor 가 만든)의 stop() 은 "좀비" 브랜치가 따로
        // _stopping 에 게시하므로 여기서 잃을 게 없다.
        _broadcaster = null;
        _monitorEndpointNotifier.value = null;
        if (mounted) setState(() => _monitorEndpoint = null);
      }
    } else if (state == AppLifecycleState.resumed) {
      if (!_monitorPaused) return; // 배경에 간 적이 없으면(혹은 초기 바인딩 전) 할 일 없음
      _monitorPaused = false;
      _resumeMonitor();
    }
  }

  /// resumed 진입점. 직전 [MonitorBroadcaster.stop] 이 아직 끝나지 않았으면
  /// 먼저 기다린다 — 그래야 OS 가 포트(예: 8080)를 회수한 뒤에 재바인딩해
  /// 같은 포트를 다시 잡을 확률이 높아진다. [_startMonitor] 자체의 재진입
  /// 방지는 `_monitorStarting` 이 맡는다.
  Future<void> _resumeMonitor() async {
    final stopping = _stopping;
    _stopping = null;
    if (stopping != null) {
      try {
        await stopping;
      } catch (_) {}
    }
    await _startMonitor();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // MonitorSource.stop() 은 session_stop 이벤트를 outbox 에 큐잉만 한다.
    // 바로 다음 줄의 broadcaster.stop() 이 16ms 드레인 타이머를 그 이벤트가
    // 한 번도 못 돈 채로 취소해 버리므로(Finding 3 과 같은 패턴), 이 이벤트도
    // 클라이언트에 절대 도달하지 않는다 — dispose() 는 async 가 아니라 여기서
    // await 로 순서를 바꿀 수도 없다. 문제 없다: broadcaster.stop() 이 곧이어
    // 소켓을 닫고, 웹은 그 소켓 종료 자체로 세션 종료를 판단한다.
    _monitorSource?.stop();
    _broadcaster?.stop();
    _monitorEndpointNotifier.dispose();
    _game.onRemove(); // feed.dispose() 는 이 안에서 호출된다
    super.dispose();
  }

  // ── 테스트 전용 진단 게터 ─────────────────────────────────────────
  // 프로덕션 코드는 쓰지 않는다. `_GameScreenState` 는 라이브러리 비공개라
  // 테스트가 타입으로 직접 잡을 수 없으므로, `tester.state(...)` 로 얻은
  // 인스턴스를 `dynamic` 으로 다뤄 이 이름들로 내부 배선을 검증한다
  // (재진입 가드·pause/resume 후 동일 MonitorSource 유지·토큰 불변).
  @visibleForTesting
  MonitorEndpoint? get debugMonitorEndpoint => _monitorEndpoint;
  @visibleForTesting
  MonitorSource? get debugMonitorSource => _monitorSource;
  @visibleForTesting
  bool get debugHasBroadcaster => _broadcaster != null;
  @visibleForTesting
  String get debugMonitorToken => _monitorToken;

  /// 테스트 전용 동기화 훅 두 개. 프로덕션에서는 항상 null(오버헤드 없음).
  /// "몇 ms 쯤 기다렸다 이벤트를 흘려보내는" 식으로 폴링해 이 파일의
  /// 레이스 순간을 맞히려던 시도는 기계마다 실 소켓 바인딩/종료 속도가
  /// 달라 들쭉날쭉했다 — 진짜 배경 전환이 겹치는 사용자 시나리오를
  /// 안정적으로 재현하려면 아래 두 지점을 정확히 짚어야 한다.
  ///
  /// [debugOnBindStarting] 은 `_monitorStarting = true` 직후, 아직
  /// `broadcaster.start()` 를 부르기 전에 불린다.
  @visibleForTesting
  Future<void> Function()? debugOnBindStarting;

  /// [debugOnZombieStopping] 은 "좀비" 분기가 방금 뜬 방송기의 stop() 을
  /// 막 시작한 그 정확한 순간에 불린다.
  @visibleForTesting
  Future<void> Function()? debugOnZombieStopping;

  @override
  Widget build(BuildContext context) {
    final zone = _sigma == null ? null : zoneOf(_sigma!);

    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      body: Stack(
        fit: StackFit.expand,
        children: [
          GameWidget(game: _game),
          // HUD 는 **코너로 몰고 중앙·하단은 비운다.** 공이 날아와 글러브에
          // 잡히는 장면이 이 화면의 전부라, 거기 위로는 아무것도 올리지 않는다.
          SafeArea(
            child: Stack(
              children: [
                if (_isMock)
                  const Align(
                    alignment: Alignment.topCenter,
                    child: _SimulationBanner(),
                  ),
                // 좌상단 — 세션 정보
                Positioned(
                  left: 10,
                  top: _isMock ? 34 : 8,
                  child: SessionHud(
                    inning: _inning,
                    catchCount: _catches,
                    sourceLabel: _sourceLabel,
                    isSimulated: _isMock,
                  ),
                ),
                // 우상단 — 피로 게이지(임상 알맹이는 항상 보인다)
                Positioned(
                  right: 10,
                  top: _isMock ? 34 : 8,
                  child: SizedBox(
                    width: 176,
                    child: FatiguePanel(
                      sigma: _sigma,
                      predicted: _predicted,
                      horizonSec: _feed.predictionHorizonSec,
                      compact: true,
                    ),
                  ),
                ),
                // 포구 팝업 — 글러브보다 위, HUD 보다 아래 중간 높이.
                Align(
                  alignment: const Alignment(0, 0.28),
                  child: CatchPopup(trigger: _catches),
                ),
                // 관찰 주소 — 상시 카드가 아니라 작은 트리거 버튼이다.
                //
                // 예전엔 top-center 에 Align 으로 풀사이즈 카드를 얹었는데,
                // Align 은 loosen() 된 constraints 를 자식에게 넘길 뿐이라
                // ListTile 이 (StackFit.expand 로 finite 해진) 가로 전체를
                // 채워 좌상단 SessionHud·우상단 FatiguePanel 을 통째로 덮었다
                // — 이 화면의 "임상 알맹이"(FatiguePanel 독스트링 참고)가
                // 세션 내내 가려지는 셈이라 카드 대신 우하단의 작은 아이콘
                // 버튼으로 접어 둔다. 좌표는 play area(가로 25~75%, 세로
                // 45~100%) 바깥의 우하단 모서리 — 포구 장면·양쪽 HUD 어느 것도
                // 침범하지 않는다. 주소는 탭하면 다이얼로그로 펼쳐진다.
                if (_monitorEndpoint != null || _broadcaster != null)
                  Positioned(
                    right: 8,
                    bottom: 8,
                    child: _MonitorAddressButton(
                      endpoint: _monitorEndpoint,
                      onTap: () => _showMonitorAddress(context),
                    ),
                  ),
              ],
            ),
          ),
          if (_resting)
            RestOverlay(
              sigma: _sigma,
              remainingSec: _rest.remainingSec(_game.feedNowSec) ?? 0,
              history: _history,
              nowSec: _game.feedNowSec,
              inning: _inning,
              onSkip: _finishRest,
            ),
          Positioned(
            top: 4,
            left: 4,
            child: SafeArea(
              child: IconButton(
                icon: const Icon(Icons.close, color: Color(0xFF8B949E)),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ),
          ),
          if (zone == FatigueZone.danger && !_resting)
            const IgnorePointer(child: _DangerVignette()),
        ],
      ),
    );
  }

  /// 관찰 주소 트리거를 탭했을 때 전체 카드를 다이얼로그로 펼친다.
  void _showMonitorAddress(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 24),
        // 다이얼로그는 GameScreen 과 별개의 라우트라 GameScreen 의 setState
        // 로는 재빌드되지 않는다 — ValueListenableBuilder 로 직접 구독해야
        // 다이얼로그가 열려 있는 동안 배경 전환이 일어나도(_monitorEndpoint
        // 가 null 로 바뀌어도) 죽은 주소를 계속 보여주지 않는다.
        //
        // ScaffoldMessenger + Scaffold 로 한 겹 더 감싼 것은 카드의 복사
        // 버튼 때문이다. MonitorAddressCard 는 ScaffoldMessenger.of(context)
        // 로 스낵바를 띄우는데, 감싸지 않으면 MaterialApp 최상위
        // ScaffoldMessenger 를 찾아가고, 그 스낵바는 등록된 Scaffold(=
        // GameScreen 자신의 Scaffold) 안에 그려져 이 다이얼로그의 모달
        // 배리어 **아래**에 있게 돼 사용자 눈에 보이지 않는다.
        //
        // ScaffoldMessenger 하나만 새로 두는 것으로는 부족하다 —
        // ScaffoldMessengerState.showSnackBar 는 등록된 Scaffold 후손이
        // 없으면 그냥 assert 로 죽는다("no descendant Scaffolds to present
        // to"). Material 로는 등록되지 않고 Scaffold 라야 등록된다. 그래서
        // 투명 배경 Scaffold 를 그 안에 둬 이 다이얼로그 자신의 스낵바
        // 표시 대상이 되게 한다 — 그 오버레이는 다이얼로그 콘텐츠 위에
        // 그려져 실제로 보인다.
        child: ScaffoldMessenger(
          child: Scaffold(
            backgroundColor: Colors.transparent,
            body: ValueListenableBuilder<MonitorEndpoint?>(
              valueListenable: _monitorEndpointNotifier,
              builder: (context, endpoint, _) =>
                  MonitorAddressCard(endpoint: endpoint),
            ),
          ),
        ),
      ),
    );
  }
}

/// 관찰 주소를 접어 두는 작은 원형 버튼. 탭하면 [MonitorAddressCard] 를
/// 다이얼로그로 띄운다 — HUD 를 절대 가리지 않으면서도 주소를 discoverable
/// 하게 유지한다 (Finding 1).
class _MonitorAddressButton extends StatelessWidget {
  const _MonitorAddressButton({required this.endpoint, required this.onTap});

  final MonitorEndpoint? endpoint;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final active = endpoint?.url != null;
    // 아이콘 하나가 "노트북에서 이 세션을 관찰하려면 여기를 눌러 주소를
    // 확인하라"는 것을 전달하는 유일한 단서다 — 툴팁이 최소한이다. 상태를
    // 20px 아이콘 색 차이 하나로만 표현하지 않도록 문구에도 활성/비활성을
    // 담는다.
    return Tooltip(
      message: active ? '관찰 화면 주소 보기' : '모니터 비활성 — 눌러서 확인',
      child: Material(
        color: const Color(0xFF161B22).withValues(alpha: 0.93),
        shape: const CircleBorder(side: BorderSide(color: Color(0xFF30363D))),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Icon(
              Icons.desktop_windows_outlined,
              size: 20,
              color:
                  active ? const Color(0xFF58A6FF) : const Color(0xFF8B949E),
            ),
          ),
        ),
      ),
    );
  }
}

/// 실측이 아님을 숨기지 않는다.
class _SimulationBanner extends StatelessWidget {
  const _SimulationBanner();

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        color: const Color(0xFFF39C12),
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
        child: const Text(
          '⚠ 실측 세션 재생 중 — 지금 측정하고 있는 값이 아닙니다',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Color(0xFF0D1117),
            fontSize: 12,
            fontWeight: FontWeight.w800,
          ),
        ),
      );
}

/// 위험 존에서 화면 가장자리가 붉게 맥동한다. 연출 전용.
class _DangerVignette extends StatelessWidget {
  const _DangerVignette();

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            radius: 1.0,
            colors: [
              Colors.transparent,
              const Color(0xFFE74C3C).withValues(alpha: 0.20),
            ],
            stops: const [0.62, 1.0],
          ),
        ),
      );
}
