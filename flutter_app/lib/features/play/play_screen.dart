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
    final waiting = o.state == SessionState.readyToMeasure;

    // 게임이 돌지 못하는 상태인가.
    //
    // 게임 루프는 버스트에서만 위상을 받는다([CoreLoop.syncTo]). 주기가 안
    // 잡히면 [CoreLoop.advanceTo] 가 큐를 하나도 내주지 않고, 화면은 멀쩡히
    // 떠 있는데 **아무것도 움직이지 않는다.**
    //
    // 동기화 비상구로 여기 온 경우가 특히 그렇다 — 갇히지 않게 내보냈더니
    // 이번엔 이유 없이 멈춘 화면이 됐다. 그건 갇힌 것보다 나쁘다.
    final stalled = o.state == SessionState.playing && o.loop.periodMs == null;

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

          // 멈춰 있는 이유를 화면이 말한다. 가리지는 않는다 — 자극이 잡히기
          // 시작하면 그 순간부터 게임이 돌아야 하고, 그때 이 띠는 사라진다.
          if (stalled) const _StalledNotice(),

          // 측정 시작 전. 게임을 먼저 보여 준 뒤 그 위에 카드를 덮는다 —
          // 누르면 곧바로 이 화면이 살아나므로 어디를 봐야 할지 헤매지 않는다.
          if (waiting) _MeasureGate(onStart: o.startMeasurement),

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
                            // 수동일 때 앱이 하는 일은 기록뿐이다. 버튼이
                            // 세기를 줄여 주는 것처럼 말하면, 아프다고 누른
                            // 사람이 줄어들기를 기다리며 계속 참는다.
                            label: o.manualStim
                                ? '기기 다이얼을 낮춰 주세요'
                                : '자극 조금 줄이기',
                            filled: false,
                            onPressed: o.lowerIntensity,
                          ),
                        ),
                      // 상시 노출. 누르면 즉시 자극 OFF —
                      // 다만 수동일 때는 앱이 끄지 못한다. 아래 문구가 그걸 말한다.
                      RefitButton(
                        label: o.manualStim ? '기기를 끄고 마치기' : '오늘은 여기까지',
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

/// 측정 시작을 기다리는 카드.
///
/// ## 왜 게임 위에 덮는가
///
/// 이 순간에 환자가 하는 일은 **자세를 잡는 것**이다. 그 동안의 움직임이
/// 기준값(DC offset·잡음·A_ref)에 들어가면 그 위의 피로도 전부가 그만큼
/// 틀어진다. 그래서 "지금부터 잰다"를 사람이 선언하게 하고, 그 전까지는
/// 신호 엔진에 표본을 넣지 않는다.
///
/// 게임을 먼저 그려 두고 카드만 덮는 이유는, 누른 직후 바로 이 화면이
/// 살아나기 때문이다 — 화면이 한 번 더 바뀌면 어디를 봐야 할지 헤맨다.
class _MeasureGate extends StatelessWidget {
  const _MeasureGate({required this.onStart});

  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: RefitTheme.abyss.withValues(alpha: 0.62),
      child: Center(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 28),
          padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 24),
          decoration: BoxDecoration(
            color: RefitTheme.abyss.withValues(alpha: 0.88),
            borderRadius: BorderRadius.circular(26),
            border: Border.all(
              color: RefitTheme.glow.withValues(alpha: 0.28),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '편하게 자세를 잡으세요',
                style: RefitTheme.title,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 10),
              Text(
                '준비되면 아래를 눌러 주세요.\n그때부터 근육 반응을 읽기 시작합니다.',
                style: RefitTheme.body,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: RefitButton(label: '측정 시작', onPressed: onStart),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 자극을 못 찾아 게임이 돌지 못하고 있다.
///
/// 「곧 함께 시작합니다」와 달리 **덮지 않는다.** 이건 기다리면 되는 상태가
/// 아니라 사람이 뭔가 해야 하는 상태이고, 화면 가운데를 막아 두면 무엇을
/// 해야 하는지가 아니라 "고장났다"로 읽힌다.
class _StalledNotice extends StatelessWidget {
  const _StalledNotice();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: IgnorePointer(
          child: Container(
            margin: const EdgeInsets.fromLTRB(20, 64, 20, 0),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            decoration: BoxDecoration(
              color: RefitTheme.abyss.withValues(alpha: 0.86),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: RefitTheme.caution.withValues(alpha: 0.5),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.bolt_outlined,
                    size: 20, color: RefitTheme.caution),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    '자극을 찾지 못해 아직 멈춰 있어요.\n'
                    '기기 세기를 한두 단계 올려 주세요.',
                    style: RefitTheme.caption.copyWith(color: RefitTheme.ink),
                  ),
                ),
              ],
            ),
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
