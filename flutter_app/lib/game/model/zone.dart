/// SPC 존 정의 — Western Electric 규칙의 1σ/2σ/3σ 경계.
///
/// 순수 Dart다(Flutter 의존 없음). 색은 ARGB 정수로 두고 UI에서 Color()로 감싼다.
/// 그래야 엔진·트래커가 위젯 테스트 없이 단위테스트된다.
///
/// 색 팔레트는 `docs/` 의 fatigue_gauge.html 과 동일하다. 같은 σ를 두 화면이
/// 다른 색으로 보여주면 안 된다.
library;

enum FatigueZone {
  /// z < 1σ
  normal(0xFF39D353, '정상', '✅', '정상'),

  /// 1σ ≤ z < 2σ
  caution(0xFFF4D03F, '주의', '👀', '주의 — 피로 누적 시작 감지'),

  /// 2σ ≤ z < 3σ
  warning(0xFFF39C12, '경고', '⚠', '경고 — 곧 위험 구간, 선제 대응 권장'),

  /// z ≥ 3σ
  danger(0xFFE74C3C, '위험', '🛑', '위험! 관리이탈 — 자극 강도 낮추거나 휴식');

  const FatigueZone(this.argb, this.label, this.icon, this.banner);

  /// ARGB 색상값. UI에서 `Color(zone.argb)`.
  final int argb;

  /// 짧은 이름 — HUD 라벨용.
  final String label;

  /// 이모지 아이콘. 색만으로 의미를 나르지 않기 위한 이중 인코딩이다
  /// (경고↔위험 주황-빨강은 색각이상에서 구분이 어렵다).
  final String icon;

  /// 상태 배너 문구.
  final String banner;

  /// 이 존이 시작되는 σ 값.
  double get lowerSigma => switch (this) {
        FatigueZone.normal => 0,
        FatigueZone.caution => 1,
        FatigueZone.warning => 2,
        FatigueZone.danger => 3,
      };
}

/// 게이지 상한. 오프라인 게이지(fatigue_gauge.html)의 ZMAX 와 같다.
const double kSigmaMax = 4.0;

/// σ 값을 존으로. 음수(=초기보다 오히려 증강)는 정상으로 본다.
FatigueZone zoneOf(double z) {
  if (z >= 3) return FatigueZone.danger;
  if (z >= 2) return FatigueZone.warning;
  if (z >= 1) return FatigueZone.caution;
  return FatigueZone.normal;
}

/// 스태미나 % — 게이지 하단 막대. 0σ에서 100%, kSigmaMax에서 0%.
///
/// "100%"는 언제나 그 사람 자신의 초기 상태이지 집단 평균이 아니다.
double staminaPercent(double z) {
  final p = 100.0 - (z / kSigmaMax) * 100.0;
  return p.clamp(0.0, 100.0);
}
