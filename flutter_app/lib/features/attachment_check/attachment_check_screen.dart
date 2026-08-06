import 'package:flutter/material.dart';

import '../../session/session_controller.dart';
import '../refit_theme.dart';
import '../session/session_orchestrator.dart';

/// 부착 체크 3항목. 통과하지 않으면 게임에 들어갈 수 없다.
///
/// 각 항목에 **부착 위치 그림**이 붙는다 — 텍스트만으로는 매번 실패한다.
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
    // 판정은 신호 엔진이 한다. 신호가 아직 안 왔을 뿐인 상태를
    // "안 붙었다"로 말하지 않게, 판정이 설 때까지 기다린다.
    final r = await widget.orchestrator.awaitAttachmentCheck();
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
          child: Column(
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
                child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(24, 28, 24, 12),
                  itemCount: _items.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 18),
                  itemBuilder: (_, i) {
                    final it = _items[i];
                    return _CheckRow(
                      title: it.$1,
                      hint: it.$2,
                      diagram: it.$3,
                      state: _stateOf(it.$4(r)),
                    );
                  },
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
    );
  }

  _RowState _stateOf(bool? ok) => switch (ok) {
    null => _RowState.pending,
    true => _RowState.ok,
    false => _RowState.retry,
  };
}

/// 제목 · 안내 · 도식 · 판정 뽑는 법.
const _items = <(String, String, _AttachDiagram, bool? Function(AttachmentCheck?))>[
  ('EMG 전극', '팔 안쪽, 손목에서 손가락 세 마디 위', _AttachDiagram.emg, _emg),
  ('자극 패드', '전극 아래쪽, 두 장이 닿지 않게', _AttachDiagram.pad, _pad),
  ('기기', '배터리와 연결 상태', _AttachDiagram.device, _dev),
];

bool? _emg(AttachmentCheck? r) => r?.emgElectrodeOk;
bool? _pad(AttachmentCheck? r) => r?.stimPadOk;
bool? _dev(AttachmentCheck? r) => r?.deviceOk;

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
    final w = size.width, h = size.height;
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..color = RefitTheme.inkSoft;
    final fill = Paint()..color = tint.withValues(alpha: 0.85);

    if (kind == _AttachDiagram.device) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(w * 0.22, h * 0.28, w * 0.56, h * 0.44),
          const Radius.circular(8),
        ),
        stroke,
      );
      canvas.drawCircle(Offset(w * 0.5, h * 0.5), 6, fill);
      return;
    }

    // 팔뚝 실루엣 + 붙이는 자리. 전극은 위, 패드는 아래.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * 0.30, h * 0.10, w * 0.40, h * 0.80),
        Radius.circular(w * 0.20),
      ),
      stroke,
    );
    final y = kind == _AttachDiagram.emg ? 0.34 : 0.62;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * 0.36, h * y, w * 0.28, h * 0.13),
        const Radius.circular(4),
      ),
      fill,
    );
  }

  @override
  bool shouldRepaint(_DiagramPainter old) =>
      old.kind != kind || old.tint != tint;
}
