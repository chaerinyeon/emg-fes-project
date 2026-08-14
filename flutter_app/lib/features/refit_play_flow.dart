import 'package:flutter/material.dart';

import '../session/session_controller.dart';
import 'monitor_service.dart';
import 'attachment_check/attachment_check_screen.dart';
import 'intensity_wizard/intensity_wizard_screen.dart';
import 'play/play_screen.dart';
import 'refit_theme.dart';
import 'report/report_screen.dart';
import 'session/session_orchestrator.dart';

/// 세션 상태에 따라 화면을 바꾼다.
///
/// 라우팅을 상태머신에 묶어 두면 "부착 체크를 건너뛰고 게임으로" 같은 경로가
/// 애초에 생기지 않는다 — 화면 전환이 [SessionMachine] 의 전이와 1:1이다.
///
/// 일반 흐름에서는 `connecting`~`intensityWizard` 를 운동 탭의 사전 세팅
/// (`features/setup/setup_screen.dart`)이 먼저 소화하고, 이 화면은
/// `syncing` 부터 열린다. 그럼에도 앞 단계 분기를 남겨 두는 이유는 라우팅이
/// **상태의 함수**여야 하기 때문이다 — 분기를 지우면 상태가 뒤로 갈 때
/// (기기 끊김 등) 화면이 무엇을 그릴지 정의되지 않는다.
///
/// ## 관찰 화면(웹)에 세션을 붙였다 뗀다
///
/// 서버 자체는 [MonitorService] 가 앱 수명으로 들고 있다(설정에서 켠다).
/// 여기서는 **실시간 프레임을 흘리는 구간만** 붙인다 — 훈련이 끝나면
/// 떼어내야 치료사 화면이 멈춘 값을 "지금"으로 그리지 않는다.
class RefitPlayFlow extends StatefulWidget {
  const RefitPlayFlow({
    super.key,
    required this.orchestrator,
    this.onFinished,
  });

  final SessionOrchestrator orchestrator;
  final VoidCallback? onFinished;

  @override
  State<RefitPlayFlow> createState() => _RefitPlayFlowState();
}

class _RefitPlayFlowState extends State<RefitPlayFlow> {
  @override
  void initState() {
    super.initState();
    widget.orchestrator.addListener(_rebuild);
    // 서버가 꺼져 있으면 아무 일도 하지 않는다. 관찰은 선택이고, 훈련이
    // 관찰 때문에 달라져서는 안 된다.
    gMonitor.attachSession(widget.orchestrator);

    // 「측정 시작」을 사람이 한 번 더 누르게 두지 않는다.
    //
    // 그 버튼에는 **결정이 없었다.** 준비 화면에서 이미 시작을 눌렀는데 게임
    // 화면에서 또 누르라고 하면, 확인이 아니라 관문이 하나 더 있는 것으로
    // 읽힌다. 이 화면이 떴다는 것 자체가 "시작한다"는 뜻이다.
    //
    // 시작 지점을 [PlayScreen] 이 아니라 여기 둔 이유: 화면은 상태를 그리는
    // 뷰여야 한다. 뷰가 마운트되면서 세션을 움직이면 그 화면을 위젯 테스트에
    // 올릴 때마다 진짜 세션이 돌아간다.
    //
    // 대신 잃는 것: 환자가 자세를 잡는 동안의 움직임이 기준값 창에 섞일 수
    // 있다. 무자극 구간이라 중앙값·MAD 가 어느 정도 견디지만, 크게 뒤척이면
    // 임계가 밀린다 — 그때는 치료사 보기의 「자극 검출 다시 맞추기」로 되돌린다.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.orchestrator.startMeasurement();
    });
  }

  @override
  void dispose() {
    widget.orchestrator.removeListener(_rebuild);
    gMonitor.detachSession();
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final o = widget.orchestrator;

    final screen = switch (o.state) {
      SessionState.idle ||
      SessionState.connecting =>
        const _Waiting(message: '기기를 찾고 있어요'),
      SessionState.attachmentCheck =>
        AttachmentCheckScreen(orchestrator: o),
      SessionState.intensityWizard =>
        IntensityWizardScreen(orchestrator: o),
      // 동기화는 대기 화면이 아니라 튜토리얼 라운드로 보여야 한다.
      // PlayScreen 이 syncing 상태를 알아서 다르게 그린다.
      //
      // readyToMeasure 도 같은 화면이다 — 별도 대기 화면을 만들면 전환이
      // 한 번 더 생기고, 환자는 "측정 시작"을 누른 뒤 게임이 어디서 나오는지
      // 다시 찾아야 한다. 게임을 먼저 보여 주고 그 위에 카드만 덮는다.
      SessionState.readyToMeasure ||
      SessionState.syncing ||
      SessionState.playing =>
        PlayScreen(orchestrator: o, monitorUrl: gMonitor.url),
      SessionState.ending =>
        const _Waiting(message: '마무리하는 중이에요'),
      SessionState.report =>
        ReportScreen.of(o, onDone: widget.onFinished),
    };

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 260),
      child: KeyedSubtree(key: ValueKey(o.state), child: screen),
    );
  }
}

class _Waiting extends StatelessWidget {
  const _Waiting({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: RefitBackdrop(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 34,
                height: 34,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: RefitTheme.glow,
                ),
              ),
              const SizedBox(height: 24),
              Text(message, style: RefitTheme.body),
            ],
          ),
        ),
      ),
    );
  }
}
