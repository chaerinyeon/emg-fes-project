/// 다음 수축 시각 예측 — 실시간 동기의 핵심.
///
/// ## 왜 예측이 필요한가
///
/// 공은 원경에서 날아오는 데 ≈0.95초가 걸린다. 그런데 실시간에서는 **다음 수축이
/// 언제 올지 미리 알 수 없다** — M-wave 는 자극이 이미 일어난 뒤에야 도착한다.
/// 그래서 공을 제때 던지려면 다음 수축 시각을 예측해야 한다.
///
/// ## 예측이 가능한 이유
///
/// FES 주기가 극도로 안정적이다. 실측 379버스트에서 min 1.615 / 중앙 1.618 /
/// max 1.622초 — 지터가 ±3.5ms다. 비행시간 950ms 대비 **0.37%** 오차라, 직전
/// 수축에 관측 주기를 더하는 것만으로 충분하다.
///
/// ## 빗나가면
///
/// 예측이 어긋나도 벌점은 없다. 실제 수축이 온 순간에 포구가 일어나고 공은 그
/// 자리에서 잡힌다. 예측은 "공을 언제 출발시킬까"에만 쓰이지 판정에 쓰이지 않는다
/// — 애초에 이 게임에 판정이 없다.
class ContractionPredictor {
  ContractionPredictor({
    this.missedPeriodsBeforeGiveUp = 3,
  });

  /// 이만큼 연속으로 수축이 안 오면 자극이 멈춘 것으로 본다.
  ///
  /// 3주기 ≈ 4.9초. 이보다 짧게 잡으면 검출을 한두 번 놓친 것만으로 "자극 꺼짐"
  /// 으로 오판하고, 길게 잡으면 실제로 꺼진 뒤에도 헛공을 계속 던진다.
  final int missedPeriodsBeforeGiveUp;

  /// 다음 수축 예상 시각(초). 아직 모르거나 자극이 멈췄으면 null.
  ///
  /// [lastContractionSec] 이 null 이면(첫 수축 전) 예측할 근거가 없다 —
  /// 화면은 "자극 대기 중"으로 간다.
  ///
  /// 예측이 이미 지나갔다면 검출을 놓쳤다는 뜻이므로 **주기 단위로 밀어** 다음
  /// 박자를 가리키게 한다. 그러지 않으면 한 번 놓칠 때마다 리듬이 멈춰버린다.
  double? predict({
    required double nowSec,
    required double? lastContractionSec,
    required double periodSec,
  }) {
    if (lastContractionSec == null) return null;
    if (periodSec <= 0) return null;

    var eta = lastContractionSec + periodSec;
    var missed = 0;
    while (eta < nowSec) {
      eta += periodSec;
      if (++missed > missedPeriodsBeforeGiveUp) return null;
    }
    return eta;
  }
}
