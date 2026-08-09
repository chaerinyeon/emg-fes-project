import 'package:flame/game.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../game/data/session_fatigue_feed.dart';
import '../../game/flame/baseball_game.dart';
import '../../session/session_controller.dart';
import '../refit_theme.dart';
import '../session/session_orchestrator.dart';
import 'therapist_panel.dart';

/// 훈련 화면 — **게임이 화면 자체다.**
///
/// 자기 근육이 수축했다는 사실이 공을 잡는 장면으로 되돌아오는 것,
/// 그것이 이 화면의 존재 이유다(신경가소성 되먹임). 그래서 게임이 곁들이가
/// 아니라 화면 전체를 차지하고, 나머지는 그 위에 얹힌 얇은 층이다.
///
/// **피로도 퍼센트를 띄우지 않는다.** 피로가 진행되면 수축 성공률이 떨어지고
/// 잡히는 공이 줄어든다 — 피로는 게임 안에서 저절로 표현된다. 숫자는
/// 웹(치료사)에만 있다.
///
/// 중단 버튼은 상시 노출이고 화면 하단 ⅓ 안에 있다(한 손 조작).
class PlayScreen extends StatefulWidget {
  const PlayScreen({
    super.key,
    required this.orchestrator,
    this.monitorUrl,
  });

  final SessionOrchestrator orchestrator;

  /// 치료사 노트북에서 열 관찰 화면 주소. 서버가 못 떴으면 null.
  /// **환자 화면에는 나오지 않는다** — 치료사 보기 안에만 있다.
  final String? monitorUrl;

  @override
  State<PlayScreen> createState() => _PlayScreenState();
}

class _PlayScreenState extends State<PlayScreen> {
  int _lastPulse = 0;
  late final BaseballGame _game;

  /// 치료사 보기. **기본은 닫힘** — 환자 화면에 임상 지표를 두지 않는다.
  bool _therapistView = false;

  @override
  void initState() {
    super.initState();
    // 게임은 **한 번만** 만든다. build 마다 새로 만들면 세션 중에 화면이
    // 통째로 리셋된다.
    _game = BaseballGame(
      feed: SessionFatigueFeed(
        cues: widget.orchestrator.cues,
        loop: widget.orchestrator.loop,
        clockMs: widget.orchestrator.nowMs,
      ),
    );
    widget.orchestrator.addListener(_onChange);
  }

  @override
  void dispose() {
    widget.orchestrator.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    final o = widget.orchestrator;
    // 소리·햅틱을 시각과 동등하게. 화면을 계속 응시하기 어려운 사용자가 있다.
    if (o.successPulse != _lastPulse) {
      _lastPulse = o.successPulse;
      HapticFeedback.mediumImpact();
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final o = widget.orchestrator;
    final syncing = o.state == SessionState.syncing;

    return Scaffold(
      backgroundColor: RefitTheme.abyss,
      body: Stack(
        fit: StackFit.expand,
        children: [
          GameWidget<BaseballGame>(game: _game),

          // 그림 위에 글씨를 얹으려면 바탕이 필요하다. 게임을 가리지 않을
          // 만큼만 어둡게 깐다.
          const _EdgeScrim(),

          // 동기화 구간은 "대기 화면"이 아니라 튜토리얼 라운드다. 게임은
          // 그대로 돌아가고, 그 위에 한 마디만 얹는다.
          if (syncing) const _SyncingVeil(),

          SafeArea(
            child: Column(
              children: [
                _TopBar(
                  signal: o.signal,
                  repCount: o.repCount,
                  syncing: syncing,
                ),
                const Spacer(),

                // 치료사 보기 — 하단에서 올라온다. 열려도 중단 버튼은 계속
                // 화면 하단 ⅓ 안에 남는다(패널이 조작부 **위**에 선다).
                if (_therapistView)
                  // Flexible 이라 남는 공간을 넘지 않는다 — 작은 화면에서
                  // 패널이 중단 버튼을 밀어내면 안 된다.
                  Flexible(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: MediaQuery.of(context).size.height * 0.46,
                      ),
                      child: TherapistPanel(
                        orchestrator: o,
                        monitorUrl: widget.monitorUrl,
                      ),
                    ),
                  ),

                // 조작부에는 **자기 바탕**이 있어야 한다.
                //
                // 포구 이펙트가 터지는 자리가 하필 화면 아래쪽이라, 바탕
                // 없이 두면 밝은 빛이 지나갈 때마다 얇은 테두리 버튼이
                // 통째로 씻겨 사라진다 — 중단 버튼이 그렇게 되면 안 된다.
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
                  decoration: BoxDecoration(
                    color: RefitTheme.abyss.withValues(alpha: 0.82),
                    borderRadius: BorderRadius.circular(28),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 이 토글은 세션 요약에 남는다 — 누가 언제 열었는지.
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton.icon(
                          onPressed: () {
                            setState(() => _therapistView = !_therapistView);
                            if (_therapistView) o.noteTherapistViewOpened();
                          },
                          style: TextButton.styleFrom(
                            foregroundColor: RefitTheme.inkFaint,
                          ),
                          icon: Icon(
                            _therapistView
                                ? Icons.expand_more_rounded
                                : Icons.expand_less_rounded,
                            size: 20,
                          ),
                          label: const Text('치료사 보기'),
                        ),
                      ),
                      if (o.intensityLevel > 1)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: RefitButton(
                            label: '자극 조금 줄이기',
                            filled: false,
                            onPressed: o.lowerIntensity,
                          ),
                        ),
                      // 상시 노출. 누르면 즉시 자극 OFF.
                      RefitButton(
                        label: '오늘은 여기까지',
                        filled: false,
                        tone: RefitTheme.inkSoft,
                        onPressed: () => o.stopByUser(),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 위아래 가장자리만 어둡게. 가운데(게임이 일어나는 곳)는 건드리지 않는다.
class _EdgeScrim extends StatelessWidget {
  const _EdgeScrim();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              RefitTheme.abyss.withValues(alpha: 0.72),
              RefitTheme.abyss.withValues(alpha: 0.0),
              RefitTheme.abyss.withValues(alpha: 0.0),
              RefitTheme.abyss.withValues(alpha: 0.88),
            ],
            stops: const [0.0, 0.20, 0.66, 1.0],
          ),
        ),
      ),
    );
  }
}

class _SyncingVeil extends StatelessWidget {
  const _SyncingVeil();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ColoredBox(
        color: RefitTheme.abyss.withValues(alpha: 0.38),
        child: Center(
          // 그림 위에 글씨만 얹으면 낚싯대·타자와 겹쳐 읽히지 않는다.
          // 글씨가 앉을 자리를 만들어 준다.
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 28),
            padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 22),
            decoration: BoxDecoration(
              color: RefitTheme.abyss.withValues(alpha: 0.78),
              borderRadius: BorderRadius.circular(26),
              border: Border.all(
                color: RefitTheme.glow.withValues(alpha: 0.22),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '손이 움직이는 걸 지켜보세요',
                  style: RefitTheme.title,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 10),
                Text('곧 함께 시작합니다', style: RefitTheme.body),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.signal,
    required this.repCount,
    required this.syncing,
  });

  final SignalStatus signal;
  final int repCount;
  final bool syncing;

  @override
  Widget build(BuildContext context) {
    // 숫자 대신 상태. 신호가 나쁘면 "확인해 주세요"지 "62%"가 아니다.
    final (text, color) = switch (signal) {
      SignalStatus.good => ('연결 좋음', RefitTheme.glow),
      SignalStatus.checkSensor => ('센서를 확인해 주세요', RefitTheme.alert),
      SignalStatus.lost => ('신호가 끊겼어요', RefitTheme.alert),
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 9,
            height: 9,
            margin: const EdgeInsets.only(top: 7),
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text, style: RefitTheme.label.copyWith(color: color)),
          ),
          // 이 화면에 허용된 유일한 숫자 — 오늘 쥔 횟수.
          if (!syncing) _RepPill(count: repCount),
        ],
      ),
    );
  }
}

class _RepPill extends StatelessWidget {
  const _RepPill({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: RefitTheme.abyss.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: RefitTheme.glow.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(
            '$count',
            style: RefitTheme.title.copyWith(
              color: RefitTheme.ink,
              fontWeight: FontWeight.w600,
              height: 1.0,
            ),
          ),
          const SizedBox(width: 6),
          Text('번 쥐었어요', style: RefitTheme.body.copyWith(fontSize: 15)),
        ],
      ),
    );
  }
}
