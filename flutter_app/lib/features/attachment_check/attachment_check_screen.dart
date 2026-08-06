import 'package:flutter/material.dart';

import '../../session/session_controller.dart';
import '../refit_theme.dart';
import '../session/session_orchestrator.dart';

/// 부착 체크 3항목.
///
/// 통과하지 않으면 게임에 들어갈 수 없다. 각 항목에는 **부착 위치 그림**이
/// 붙는다 — 텍스트만으로는 매번 실패한다. 지금은 도식 플레이스홀더이고
/// 실제 일러스트가 오면 [_AttachDiagram] 만 교체하면 된다.
class AttachmentCheckScreen extends StatefulWidget {
  const AttachmentCheckScreen({super.key, required this.orchestrator});

  final SessionOrchestrator orchestrator;

  @override
  State<AttachmentCheckScreen> createState() => _AttachmentCheckScreenState();
}

class _AttachmentCheckScreenState extends State<AttachmentCheckScreen> {
  AttachmentCheck? _result;
  bool _checking = false;

  Future<void> _run() async {
    setState(() => _checking = true);
    // 자동 판정: 무자극 baseline / 테스트 펄스 / 기기 상태.
    // 실제 판정은 신호 엔진과 StimController 가 하고, 여기서는 결과만 받는다.
    await Future<void>.delayed(const Duration(milliseconds: 900));
    final r = widget.orchestrator.runAttachmentCheck();
    if (!mounted) return;
    setState(() {
      _result = r;
      _checking = false;
    });
    widget.orchestrator.submitAttachmentCheck(r);
  }

  @override
  Widget build(BuildContext context) {
    final r = _result;
    return Scaffold(
      body: RefitBackdrop(
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, box) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('준비', style: RefitTheme.label),
                      const SizedBox(height: 10),
                      Text('붙인 자리를\n확인할게요', style: RefitTheme.display),
                    ],
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(24, 28, 24, 12),
                    child: Column(
                      children: [
                        _CheckRow(
                          title: 'EMG 전극',
                          hint: '팔 안쪽, 손목에서 손가락 세 마디 위',
                          diagram: _AttachDiagram.emg,
                          state: _stateOf(r?.emgElectrodeOk),
                        ),
                        const SizedBox(height: 18),
                        _CheckRow(
                          title: '자극 패드',
                          hint: '전극 아래쪽, 두 장이 닿지 않게',
                          diagram: _AttachDiagram.pad,
                          state: _stateOf(r?.stimPadOk),
                        ),
                        const SizedBox(height: 18),
                        _CheckRow(
                          title: '기기',
                          hint: '배터리와 연결 상태',
                          diagram: _AttachDiagram.device,
                          state: _stateOf(r?.deviceOk),
                        ),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (r != null && !r.passed)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 14),
                          child: Text(
                            '다시 붙이고 한 번 더 눌러 주세요',
                            style: RefitTheme.body,
                            textAlign: TextAlign.center,
                          ),
                        ),
                      RefitButton(
                        label: _checking
                            ? '확인하는 중…'
                            : (r == null ? '확인 시작' : '다시 확인'),
                        onPressed: _checking ? null : _run,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  _RowState _stateOf(bool? ok) => switch (ok) {
    null => _RowState.pending,
    true => _RowState.ok,
    false => _RowState.retry,
  };
}

enum _RowState { pending, ok, retry }

enum _AttachDiagram { emg, pad, device }

class _CheckRow extends StatelessWidget {
  const _CheckRow({
    required this.title,
    required this.hint,
    required this.diagram,
    required this.state,
  });

  final String title;
  final String hint;
  final _AttachDiagram diagram;
  final _RowState state;

  @override
  Widget build(BuildContext context) {
    final (icon, tint) = switch (state) {
      _RowState.pending => (null, RefitTheme.inkFaint),
      _RowState.ok => (Icons.check_rounded, RefitTheme.glow),
      _RowState.retry => (Icons.refresh_rounded, RefitTheme.alert),
    };

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0x14F2F6F5),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: tint.withValues(alpha: 0.30)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 72,
            height: 72,
            child: CustomPaint(painter: _DiagramPainter(diagram, tint)),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: RefitTheme.body.copyWith(
                    color: RefitTheme.ink,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(hint, style: RefitTheme.body.copyWith(fontSize: 15)),
              ],
            ),
          ),
          if (icon != null) Icon(icon, color: tint, size: 28),
        ],
      ),
    );
  }
}

/// 부착 위치 도식 (플레이스홀더).
/// 실제 일러스트 에셋이 준비되면 이 페인터를 이미지로 바꾼다.
class _DiagramPainter extends CustomPainter {
  _DiagramPainter(this.kind, this.tint);

  final _AttachDiagram kind;
  final Color tint;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..color = RefitTheme.inkSoft;
    final fill = Paint()..color = tint.withValues(alpha: 0.85);

    switch (kind) {
      case _AttachDiagram.emg:
      case _AttachDiagram.pad:
        // 팔뚝 실루엣
        final arm = RRect.fromRectAndRadius(
          Rect.fromLTWH(
            size.width * 0.30,
            size.height * 0.10,
            size.width * 0.40,
            size.height * 0.80,
          ),
          Radius.circular(size.width * 0.20),
        );
        canvas.drawRRect(arm, stroke);
        final y = kind == _AttachDiagram.emg ? 0.34 : 0.62;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(
              size.width * 0.36,
              size.height * y,
              size.width * 0.28,
              size.height * 0.13,
            ),
            const Radius.circular(4),
          ),
          fill,
        );
      case _AttachDiagram.device:
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(
              size.width * 0.22,
              size.height * 0.28,
              size.width * 0.56,
              size.height * 0.44,
            ),
            const Radius.circular(8),
          ),
          stroke,
        );
        canvas.drawCircle(Offset(size.width * 0.5, size.height * 0.5), 6, fill);
    }
  }

  @override
  bool shouldRepaint(_DiagramPainter old) =>
      old.kind != kind || old.tint != tint;
}
