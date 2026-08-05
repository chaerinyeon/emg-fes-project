import 'package:flutter/material.dart';

/// 상단 세션 바 — 이닝·포구 수·재생원.
///
/// 야구 게임의 스코어보드 문법을 빌리되, **점수는 없다.** 이 게임에 경쟁이나
/// 스킬 판정이 없기 때문이다. 숫자는 "몇 번 수축했는가" 하나뿐이다.
class SessionHud extends StatelessWidget {
  const SessionHud({
    super.key,
    required this.inning,
    required this.catchCount,
    required this.sourceLabel,
    this.isSimulated = false,
  });

  final int inning;
  final int catchCount;

  /// "실측" 또는 재생 중인 세션 이름.
  final String sourceLabel;

  final bool isSimulated;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: BoxDecoration(
        color: const Color(0xFF161B22).withValues(alpha: 0.93),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF30363D)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _Chip(label: '$inning회', accent: true),
              const SizedBox(width: 10),
              const Text('⚾', style: TextStyle(fontSize: 16)),
              const SizedBox(width: 4),
              Text(
                '$catchCount',
                style: const TextStyle(
                  color: Color(0xFFE6EDF3),
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                  height: 1,
                ),
              ),
              const SizedBox(width: 3),
              const Text('포구',
                  style: TextStyle(color: Color(0xFF8B949E), fontSize: 11)),
            ],
          ),
          const SizedBox(height: 3),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 150),
            child: Text(
              sourceLabel,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: isSimulated
                    ? const Color(0xFFF39C12)
                    : const Color(0xFF8B949E),
                fontSize: 10,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, this.accent = false});

  final String label;
  final bool accent;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
        decoration: BoxDecoration(
          color: accent ? const Color(0xFF238636) : const Color(0xFF21262D),
          borderRadius: BorderRadius.circular(7),
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: Color(0xFFE6EDF3),
            fontSize: 12,
            fontWeight: FontWeight.w800,
          ),
        ),
      );
}

/// 포구 성공 팝업 — 스케일 + 페이드.
///
/// 점수가 없으므로 성취감은 전적으로 이 연출이 만든다.
class CatchPopup extends StatefulWidget {
  const CatchPopup({super.key, required this.trigger});

  /// 값이 바뀔 때마다 팝업이 다시 튄다(포구 횟수를 넘기면 된다).
  final int trigger;

  @override
  State<CatchPopup> createState() => _CatchPopupState();
}

class _CatchPopupState extends State<CatchPopup>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );

  @override
  void didUpdateWidget(CatchPopup old) {
    super.didUpdateWidget(old);
    if (widget.trigger != old.trigger && widget.trigger > 0) {
      _c.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final t = _c.value;
        if (t == 0 || t == 1) return const SizedBox.shrink();
        final scale =
            0.6 + 0.6 * Curves.easeOutBack.transform((t * 2.6).clamp(0, 1));
        final opacity = t < 0.6 ? 1.0 : 1.0 - (t - 0.6) / 0.4;
        return Opacity(
          opacity: opacity.clamp(0.0, 1.0),
          child: Transform.scale(
            scale: scale,
            child: const Text(
              'CATCH!',
              style: TextStyle(
                color: Color(0xFFFFE082),
                fontSize: 46,
                fontWeight: FontWeight.w900,
                letterSpacing: 3,
                shadows: [
                  Shadow(blurRadius: 22, color: Colors.black87),
                  Shadow(blurRadius: 44, color: Color(0x88FFC107)),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
