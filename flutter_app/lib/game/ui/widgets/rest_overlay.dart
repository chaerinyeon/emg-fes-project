import 'package:flutter/material.dart';

import 'stamina_bar.dart';

/// 휴식 오버레이 — 피로가 임계에 닿으면 뜬다.
///
/// ★ 점수 페널티가 없다. 이 이벤트는 벌이 아니라 안전장치다. 피로가 점수를
/// 깎으면 사용자가 무리해서 계속하려 든다 — 그러지 않도록 설계를 나눴다.
///
/// ## 환자 언어로만 말한다
///
/// 예전에는 여기서 풀 σ 게이지와 존 타임라인을 펼쳐, "게임 중엔 못 보던 자기
/// 피로 곡선을 어차피 멈춘 김에 제대로 보게" 했다. 관찰 웹이 없던 시절의
/// 결정이다. 지금 그 자리는 치료사의 웹이고, 이 화면은 환자에게 "쉬어야 한다"
/// 하나만 전한다 — σ·존·도달시각·리드타임은 전부 웹으로 갔다
/// (`docs/superpowers/specs/2026-08-05-screen-role-split-design.md`).
///
/// 그래서 문구도 "관리이탈 구간입니다"(SPC 용어)가 아니라 환자가 그대로 읽고
/// 행동할 수 있는 말을 쓴다.
class RestOverlay extends StatelessWidget {
  const RestOverlay({
    super.key,
    required this.sigma,
    required this.remainingSec,
    required this.inning,
    this.onSkip,
  });

  /// 스태미나 막대 계산에만 쓴다 — 숫자로 나가지 않는다.
  final double? sigma;

  final double remainingSec;
  final int inning;
  final VoidCallback? onSkip;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFF0D1117).withValues(alpha: 0.93),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '잠시 쉬어요',
                style: TextStyle(
                  color: Color(0xFFE74C3C),
                  fontSize: 26,
                  fontWeight: FontWeight.w900,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 6),
              const Text(
                '근육이 지쳤습니다. 점수는 깎이지 않아요 — 쉬었다 가세요.',
                style: TextStyle(color: Color(0xFF8B949E), fontSize: 13),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              Text(
                remainingSec.ceil().toString(),
                style: const TextStyle(
                  color: Color(0xFFE6EDF3),
                  fontSize: 64,
                  fontWeight: FontWeight.w900,
                  height: 1,
                ),
              ),
              const Text(
                '초 후 다음 이닝',
                style: TextStyle(color: Color(0xFF8B949E), fontSize: 13),
              ),
              const SizedBox(height: 24),
              _Card(child: StaminaBar(sigma: sigma)),
              const SizedBox(height: 12),
              _Card(child: _Stat(label: '이닝', value: '$inning')),
              if (onSkip != null) ...[
                const SizedBox(height: 18),
                TextButton(
                  onPressed: onSkip,
                  child: const Text(
                    '휴식 건너뛰기',
                    style: TextStyle(color: Color(0xFF8B949E)),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: const Color(0xFF161B22),
      border: Border.all(color: const Color(0xFF21262D)),
      borderRadius: BorderRadius.circular(16),
    ),
    child: child,
  );
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: const TextStyle(color: Color(0xFF8B949E), fontSize: 11),
      ),
      Text(
        value,
        style: const TextStyle(
          color: Color(0xFFE6EDF3),
          fontSize: 18,
          fontWeight: FontWeight.w700,
        ),
      ),
    ],
  );
}
