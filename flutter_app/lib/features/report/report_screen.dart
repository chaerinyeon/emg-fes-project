import 'package:flutter/material.dart';

import '../../session/end_conditions.dart';
import '../refit_theme.dart';
import '../session/session_orchestrator.dart';

/// 종료 화면.
///
/// **3줄뿐이다.** 그래프도 퍼센트도 없다.
///
/// 피로 임계 도달은 **실패가 아니라 "오늘 목표 달성"**이다. 문구·색·연출
/// 전부 이 프레임을 지킨다. 장비 문제로 멈춘 경우에만 담담하게 사실을
/// 알린다 — 그것도 환자 탓으로 들리지 않게.
class ReportScreen extends StatelessWidget {
  const ReportScreen({
    super.key,
    required this.repCount,
    required this.durationS,
    required this.endReason,
    this.onDone,
  });

  ReportScreen.of(SessionOrchestrator o, {super.key, this.onDone})
    : repCount = o.repCount,
      durationS = o.elapsedS.round(),
      endReason = o.endReason ?? SessionEndReason.error;

  final int repCount;
  final int durationS;
  final SessionEndReason endReason;
  final VoidCallback? onDone;

  /// 환자가 읽는 언어. 종료 코드를 그대로 보여주지 않는다.
  String get _closing => switch (endReason) {
    SessionEndReason.fatigueThreshold ||
    SessionEndReason.successRateDrop => '오늘 몫을 다 했어요.\n내일도 같은 시간에 만나요',
    SessionEndReason.gameComplete => '오늘 목표를 채웠어요.\n내일도 같은 시간에 만나요',
    SessionEndReason.timeout => '오늘도 끝까지 했어요.\n내일도 같은 시간에 만나요',
    SessionEndReason.userStop => '오늘도 수고했어요.\n내일 다시 만나요',
    SessionEndReason.remoteStop => '치료사가 오늘 훈련을 마무리했어요',
    SessionEndReason.signalLost ||
    SessionEndReason.deviceDisconnect => '기기 연결이 끊겨 여기서 멈췄어요.\n다음에 이어서 해요',
    SessionEndReason.error => '여기서 멈췄어요.\n다음에 이어서 해요',
  };

  String get _duration {
    final m = durationS ~/ 60;
    final s = durationS % 60;
    if (m == 0) return '$s초 함께했어요';
    return '$m분 $s초 함께했어요';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: RefitBackdrop(
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, box) => Column(
              children: [
                Expanded(
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          // 1줄 — 오늘 몇 번 쥐었나
                          Text('$repCount', style: RefitTheme.counter),
                          const SizedBox(height: 6),
                          Text(
                            '번 쥐었어요',
                            style: RefitTheme.title.copyWith(
                              fontWeight: FontWeight.w300,
                            ),
                          ),
                          const SizedBox(height: 36),
                          // 2줄 — 얼마나 함께했나
                          Text(
                            _duration,
                            style: RefitTheme.body,
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 14),
                          // 3줄 — 내일로 잇는 말
                          Text(
                            _closing,
                            style: RefitTheme.body,
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [RefitButton(label: '마치기', onPressed: onDone)],
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
