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

  /// 배경 전환 시 시작된 [MonitorBroadcaster.stop]. resumed 에서 재바인딩하기
  /// 전에 이걸 먼저 기다려야 포트(예: 8080)가 OS 에 반환돼 같은 포트를 다시
  /// 잡을 수 있다.
  Future<void>? _stopping;

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
    setState(() {
      _resting = false;
      _game.setResting(false);
      if (decision != RestDecision.endSession) _inning++;
    });
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
    final session = widget.session;
    final feed = _feed;
    if (session == null || feed is! LiveFatigueFeed) return; // 목 피드는 방송하지 않는다
    if (_broadcaster?.endpoint != null) return; // 이미 떠 있다
    if (_monitorStarting) return; // start() 의 await 구간에 겹쳐 불리는 것 방지
    _monitorStarting = true;

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
        // 위젯이 이미 죽었거나, 바인딩 도중 앱이 배경으로 갔다. 후자의 경우
        // 방금 띄운 방송기를 살려두면 화면엔 안 보이는 채로 OS 소켓만 열려
        // 있다가 (Finding 4의 두 번째 버그) 재개 시 죽은 소켓 주소를 광고하게
        // 된다. resumed 가 오면 _monitorPaused 가 풀리며 _startMonitor 가
        // 다시 불려 새로 뜬다.
        await broadcaster.stop();
        return;
      }
      setState(() {
        _broadcaster = broadcaster;
        _monitorEndpoint = ep;
      });
    } catch (_) {
      // 모니터 실패가 게임·자극 경로로 절대 전파되지 않는다는 보장을 이 경계
      // 스스로도 갖는다 — 콜백들의 자체 삼킴에만 기대지 않는다.
    } finally {
      _monitorStarting = false;
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
    _monitorSource?.stop();
    _broadcaster?.stop();
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
        child: MonitorAddressCard(endpoint: _monitorEndpoint),
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
    return Material(
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
            color: active ? const Color(0xFF58A6FF) : const Color(0xFF8B949E),
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
