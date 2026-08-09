import 'package:flutter/material.dart';

import '../session/session_controller.dart';
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
  }

  @override
  void dispose() {
    widget.orchestrator.removeListener(_rebuild);
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
      SessionState.syncing || SessionState.playing =>
        PlayScreen(orchestrator: o),
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
