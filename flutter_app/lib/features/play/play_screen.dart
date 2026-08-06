import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../session/session_controller.dart';
import '../../signal/fatigue_engine.dart';
import '../refit_theme.dart';
import '../session/session_orchestrator.dart';
import '../widgets/hand_view.dart';

/// 훈련 화면.
///
/// **피로도 퍼센트를 띄우지 않는다.** 피로가 진행되면 수축 성공률이 떨어지고
/// 화면의 손이 잘 안 쥐어진다 — 피로는 게임 안에서 저절로 표현된다.
/// 숫자는 웹(치료사)에만 있다.
///
/// 중단 버튼은 상시 노출이고 화면 하단 ⅓ 안에 있다(한 손 조작).
class PlayScreen extends StatefulWidget {
  const PlayScreen({super.key, required this.orchestrator});

  final SessionOrchestrator orchestrator;

  @override
  State<PlayScreen> createState() => _PlayScreenState();
}

class _PlayScreenState extends State<PlayScreen> {
  int _lastPulse = 0;

  @override
  void initState() {
    super.initState();
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

  /// 손이 얼마나 펴져 있는가.
  double get _openness {
    final o = widget.orchestrator;
    return switch (o.hand) {
      HandState.open => o.cueActive ? 0.45 : 1.0,
      HandState.closed => 0.0,
      // 힘없이 멈춘다. 완전히 펴지지도, 쥐어지지도 않은 중간.
      HandState.failedContraction => 0.62,
    };
  }

  @override
  Widget build(BuildContext context) {
    final o = widget.orchestrator;
    final syncing = o.state == SessionState.syncing;

    return Scaffold(
      body: RefitBackdrop(
        child: SafeArea(
          // 조작부 높이를 화면의 ⅓ 으로 **고정하지 않는다**. 고정하면 작은
          // 기기에서 넘친다(600px 화면에서 65px 초과). 손이 남는 공간을
          // 흡수하고 조작부는 제 높이대로 바닥에 붙는다 — 결과적으로
          // 버튼은 언제나 하단 ⅓ 안에 들어온다.
          child: Column(
            children: [
              _TopBar(signal: o.signal, syncing: syncing),
              // 손 — 화면의 주인공.
              Expanded(
                child: HandView(
                  openness: _openness,
                  glowing: o.hand == HandState.closed,
                  successPulse: o.successPulse,
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _RepCounter(count: o.repCount, syncing: syncing),
                    const SizedBox(height: 22),
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
      ),
    );
  }
}

class _RepCounter extends StatelessWidget {
  const _RepCounter({required this.count, required this.syncing});

  final int count;
  final bool syncing;

  @override
  Widget build(BuildContext context) {
    if (syncing) {
      // 동기화 구간은 "대기 화면"이 아니라 튜토리얼 라운드로 보여야 한다.
      return Column(
        children: [
          Text('손이 움직이는 걸 지켜보세요', style: RefitTheme.title),
          const SizedBox(height: 8),
          Text('곧 함께 시작합니다', style: RefitTheme.body),
        ],
      );
    }
    return Column(
      children: [
        Text('$count', style: RefitTheme.counter),
        const SizedBox(height: 4),
        Text('번 쥐었어요', style: RefitTheme.body),
      ],
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.signal, required this.syncing});

  final SignalStatus signal;
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
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      child: Row(
        children: [
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          Text(text, style: RefitTheme.label.copyWith(color: color)),
        ],
      ),
    );
  }
}
