import 'package:flutter/material.dart';

import '../../model/zone.dart';
import 'sigma_gauge.dart';
import 'stamina_bar.dart';

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

/// 피로 패널 — 게이지 + 예측 + 스태미나 + 배너.
///
/// 항상 표시한다. 이 화면의 임상적 알맹이가 여기 있고, 게임 연출은 그걸 계속
/// 보게 만들기 위한 장치다.
///
/// ## 좁은 화면에서는 가로로 눕힌다
///
/// 세로로 쌓으면 높이가 130px 을 넘어 하단 중앙을 덮는데, 거기가 바로 글러브가
/// 공을 잡는 자리다. **포구 순간을 가리면 이 화면의 목적이 무너진다** — 점수가
/// 없는 게임이라 성취감이 전적으로 그 장면에서 나오기 때문이다.
/// 그래서 좁을 때는 상단에 슬림한 가로 스트립으로 눕힌다.
class FatiguePanel extends StatelessWidget {
  const FatiguePanel({
    super.key,
    required this.sigma,
    required this.predicted,
    required this.horizonSec,
    this.compact = false,
  });

  final double? sigma;
  final double? predicted;
  final double horizonSec;

  /// true 면 코너 박스(작은 화면용), false 면 큰 세로 패널.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final z = sigma;
    final zone = z == null ? null : zoneOf(z);
    // 예측이 현재보다 위험한 존으로 넘어가면 미리 경고 문구를 바꾼다.
    final predZone = predicted == null ? null : zoneOf(predicted!);
    final warnAhead =
        zone != null && predZone != null && predZone.index > zone.index;

    final banner = warnAhead
        ? '⏳ 곧 ${predZone.label} 예상 — 선제 대응 권장'
        : (zone?.banner ?? '초기 기준을 재는 중입니다');
    final bannerColor =
        warnAhead ? Color(predZone.argb) : Color(zone?.argb ?? 0xFF8B949E);

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 12 : 16,
        vertical: compact ? 8 : 16,
      ),
      decoration: BoxDecoration(
        color: const Color(0xFF161B22).withValues(alpha: 0.93),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF30363D)),
      ),
      child: compact
          ? _corner(z, zone, banner, bannerColor)
          : _vertical(z, banner, bannerColor),
    );
  }

  /// 코너 박스 — 폭 ~176px, 높이 ~110px.
  ///
  /// 중앙과 하단은 게임에 온전히 내주고, 임상 지표는 구석에서 항상 보이게 한다.
  Widget _corner(
    double? z,
    FatigueZone? zone,
    String banner,
    Color bannerColor,
  ) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SigmaDial(
              sigma: z,
              predicted: predicted,
              size: const Size(62, 37),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(
                        z == null ? '—' : z.clamp(0, 99).toStringAsFixed(1),
                        style: TextStyle(
                          color: Color(zone?.argb ?? 0xFF8B949E),
                          fontSize: 22,
                          fontWeight: FontWeight.w900,
                          height: 1,
                        ),
                      ),
                      const Text(' σ',
                          style: TextStyle(
                              color: Color(0xFF8B949E), fontSize: 10)),
                    ],
                  ),
                  const SizedBox(height: 1),
                  Text(
                    zone == null ? '측정 중' : '${zone.icon} ${zone.label}',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Color(zone?.argb ?? 0xFF8B949E),
                      fontSize: 10.5,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 7),
        StaminaBar(sigma: z, height: 11),
        const SizedBox(height: 5),
        Text(
          banner,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: bannerColor,
            fontSize: 9.5,
            fontWeight: FontWeight.w700,
            height: 1.25,
          ),
        ),
      ],
    );
  }

  /// 넓은 화면용 세로 패널.
  Widget _vertical(double? z, String banner, Color bannerColor) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SigmaGauge(
          sigma: z,
          predicted: predicted,
          predictionHorizonSec: horizonSec,
          calibrationHint: '기준 측정 중',
        ),
        const SizedBox(height: 14),
        StaminaBar(sigma: z),
        const SizedBox(height: 12),
        Text(
          banner,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: bannerColor,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
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
