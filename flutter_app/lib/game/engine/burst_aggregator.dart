/// 실측 FES 버스트 주기(초). RAW 분석에서 1621.9ms 로 잠겨 있었다.
const double kNominalBurstPeriodSec = 1.6219;

/// 펄스 스트림 → 버스트 표본. 게임의 **박자이자 수축 강도**의 단일 출처다.
///
/// ## 박자가 왜 여기서 나오는가
///
/// 처음에는 `st.isStimulating` 의 상승 엣지를 박자로 삼았는데 틀렸다. 그 값은
/// "FES 가 지금 켜져 있다"는 **지속 상태**라 세션당 상승 엣지가 사실상 한 번뿐이다.
/// 실제 자극은 그 안에서 1.6초마다 버스트로 나가고, 그 사실이 신호에 드러나는
/// 곳은 M-wave 도착뿐이다. 그래서 버스트 = 박자 = 수축 1회로 통일했다.
///
/// 왜 묶어야 하는가: 펌웨어는 **자극 펄스마다** M-wave 진폭(`mwa`)을 올려보낸다
/// (실측 펄스 간격 ≈31ms). 그런데 오프라인 기준 구현
/// `~/emgfes-data/fes_fatigue_spc.py` 는 **버스트의 첫 펄스 하나만** 쓴다:
///
/// ```python
/// pulse = ab[np.diff(ab) > 20]        # 20ms 넘게 떨어지면 다른 펄스
/// burst = pulse[np.diff(pulse) > 800] # 800ms 넘게 떨어지면 다른 버스트
/// for o in burst:                     # ← 버스트 시작점만 순회
///     w = s[o+5:o+15]; amp.append(w.max() - w.min())
/// ```
///
/// 펄스를 전부 흘려넣으면 표본이 ≈52배로 늘어 baseline 창(20~90초)의 표본 수와
/// EWMA 시정수가 완전히 달라진다 — 같은 방법이 아니게 된다. 그래서 여기서
/// 버스트 첫 펄스만 통과시켜 오프라인과 같은 계열을 만든다.
class BurstAggregator {
  BurstAggregator({this.burstGapMs = 800, this.pulseGapMs = 20});

  /// 이만큼 벌어지면 새 버스트로 본다. 오프라인의 `np.diff(pulse) > 800`.
  /// 실측 버스트 주기는 ≈1621.9ms 라 800ms 는 넉넉한 중간값이다.
  final double burstGapMs;

  /// 이만큼 벌어져야 별개 펄스로 본다. 오프라인의 `np.diff(ab) > 20`.
  /// 실측 펄스 간격 ≈31ms 보다 작아야 하고, 한 펄스의 폭보다는 커야 한다.
  final double pulseGapMs;

  /// 주기 추정 평활 계수. 자극 주기는 매우 안정적(실측 std 2.9ms)이라 새 관측을
  /// 조금씩만 반영해도 충분하고, 튀는 간격에 흔들리지 않는다.
  static const double periodLambda = 0.2;

  /// 이 범위 밖의 간격은 주기 추정에 넣지 않는다 — 자극이 끊겼다 재개되면
  /// 간격이 수십 초가 되는데, 그걸 주기로 배우면 공이 영영 안 날아온다.
  static const double minPlausiblePeriodSec = 0.5;
  static const double maxPlausiblePeriodSec = 5.0;

  double? _lastPulseMs;
  double? _lastBurstMs;
  double? _period;
  int _count = 0;

  /// 마지막으로 방출한 버스트 시각(초). 없으면 null.
  double? get lastBurstSec =>
      _lastBurstMs == null ? null : _lastBurstMs! / 1000.0;

  /// 관측된 버스트 주기(초) = 공의 비행 시간. 아직 모르면 실측 공칭값.
  double get periodSec => _period ?? kNominalBurstPeriodSec;

  /// 지금까지 방출한 버스트 수.
  int get burstCount => _count;

  /// 펄스 1개 도착. 이 펄스가 **버스트의 시작**이면 `(t초, 진폭)`을, 아니면 null.
  ///
  /// [tMs] 는 세션 시작 기준 ms, [amp] 는 그 펄스의 M-wave peak-to-peak.
  ({double tSec, double amp})? addPulse(double tMs, double amp) {
    final prevPulse = _lastPulseMs;

    // 같은 펄스의 중복 보고(20ms 이내)는 버린다.
    if (prevPulse != null && (tMs - prevPulse) <= pulseGapMs) return null;
    _lastPulseMs = tMs;

    final prevBurst = _lastBurstMs;
    final isBurstStart = prevPulse == null || (tMs - prevPulse) > burstGapMs;
    if (!isBurstStart) return null;

    // 첫 펄스는 항상 버스트 시작 (오프라인도 pulse[0]을 무조건 포함한다).
    if (prevBurst != null && (tMs - prevBurst) <= burstGapMs) return null;

    // 버스트 간격을 관측해 주기를 학습한다 — 이 값이 공의 비행 시간이 된다.
    if (prevBurst != null) {
      final gap = (tMs - prevBurst) / 1000.0;
      if (gap >= minPlausiblePeriodSec && gap <= maxPlausiblePeriodSec) {
        _period = _period == null
            ? gap
            : periodLambda * gap + (1 - periodLambda) * _period!;
      }
    }
    _lastBurstMs = tMs;
    _count++;
    return (tSec: tMs / 1000.0, amp: amp);
  }

  void reset() {
    _lastPulseMs = null;
    _lastBurstMs = null;
    _period = null;
    _count = 0;
  }
}
