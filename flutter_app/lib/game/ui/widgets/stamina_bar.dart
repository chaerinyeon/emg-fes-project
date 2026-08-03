import 'package:flutter/material.dart';

import '../../model/zone.dart';

/// 근육 스태미나 바 — `fatigue_gauge.html` 의 `.stamina` 이식.
///
/// 폭 = `100 − z/4×100` %. "100%"는 언제나 그 사람 **자신의 초기 상태**이지
/// 집단 평균이 아니다(SPC 자기기준 원칙).
class StaminaBar extends StatelessWidget {
  const StaminaBar({super.key, required this.sigma, this.height = 22});

  final double? sigma;
  final double height;

  @override
  Widget build(BuildContext context) {
    final z = sigma;
    final zone = z == null ? null : zoneOf(z);
    final pct = z == null ? 100.0 : staminaPercent(z);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('근육 스태미나',
                style: TextStyle(color: Color(0xFF8B949E), fontSize: 12)),
            Text(
              z == null ? '—' : '${pct.round()}%',
              style: TextStyle(
                color: Color(zone?.argb ?? 0xFF8B949E),
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(height / 2),
          child: Container(
            height: height,
            decoration: BoxDecoration(
              color: const Color(0xFF21262D),
              border: Border.all(color: const Color(0xFF30363D)),
              borderRadius: BorderRadius.circular(height / 2),
            ),
            child: FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: (pct / 100).clamp(0.0, 1.0),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                decoration: BoxDecoration(
                  // σ를 모를 땐 회색 — 꽉 찬 초록으로 그리면 안전하다고 오해한다.
                  color: Color(zone?.argb ?? 0xFF8B949E),
                  borderRadius: BorderRadius.circular(height / 2),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
