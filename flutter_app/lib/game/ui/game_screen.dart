import 'package:flame/game.dart';
import 'package:flutter/material.dart';

import '../../services/session_controller.dart';
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

class _GameScreenState extends State<GameScreen> {
  late final FatigueFeed _feed;
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

    _game = BaseballGame(feed: _feed)..onCatch = _onCatch;
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

  @override
  void dispose() {
    _game.onRemove();
    super.dispose();
  }

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
