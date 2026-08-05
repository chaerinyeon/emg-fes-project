import 'package:flutter/material.dart';

import 'stamina_bar.dart';

/// 환자가 보는 유일한 상태 표시 — 근육 스태미나 하나.
///
/// σ 숫자도, 존 명칭도, 예측 문구도 여기 없다. 그건 치료사의 관찰 웹이 맡는다
/// (`docs/superpowers/specs/2026-08-05-screen-role-split-design.md`).
///
/// ## 왜 스태미나만인가
///
/// "정지는 사용자 STOP만"이 이 시스템의 원칙이라, 환자가 STOP 을 누르려면 근거가
/// 하나는 있어야 한다. 스태미나는 그 근거로 유일하게 적합하다 — `100 − z/4×100` %
/// 이고 100% 가 언제나 그 사람 **자신의 초기 상태**이지 집단 평균이 아니다(SPC
/// 자기기준 원칙). "내 여력이 줄고 있다"는 환자가 읽고 행동할 수 있는 문장이지만,
/// "2.4σ, 경고 존"은 아니다 — 수축을 만드는 것은 FES 고 환자가 더 세게 쥘 방법이
/// 없다.
///
/// ## 여기에 σ 를 다시 얹지 말 것
///
/// 예전에는 이 자리에 `FatiguePanel`(σ 다이얼 + 숫자 + 존 + 예측 배너)이 있었고
/// "임상 알맹이는 항상 보인다"고 못박혀 있었다. 관찰 웹이 없던 시절의 결정이다.
/// 되돌리고 싶어지면 설계 문서 §8 의 복구책(숫자 없이 색·문구만 있는 배너)을
/// 먼저 보라.
class PatientStatusCard extends StatelessWidget {
  const PatientStatusCard({super.key, required this.sigma});

  /// 스태미나 계산에만 쓴다 — 화면에 숫자로 나가지 않는다.
  final double? sigma;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF161B22).withValues(alpha: 0.93),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF30363D)),
      ),
      child: StaminaBar(sigma: sigma, height: 13),
    );
  }
}
