import 'dart:math' as math;
import 'stats.dart';

import 'constants.dart';

/// [A] DC offset 자동 캘리브.
///
/// 세션 시작 직후 구간에서 DC offset 과 잡음 크기를 함께 잡는다.
/// **하드코딩 금지** — 기존 펌웨어의 `DC_OFFSET = 1862` 하드코딩이 오류
/// 원인이었다. 기기·세션마다 baseline 이 1800~1900대에서 제각각이다.
///
/// 추정은 **중앙값·MAD** 로 한다. 공통 컨텍스트는 "무자극 1–2초 구간의
/// 평균값"이라고 적고 있지만, 실측 raw CSV 에는 무자극 도입부가 없다
/// (raw_20260717_144215.csv 는 첫 1500샘플이 min=880 max=2559 로 이미
/// 자극 중이다). 평균·RMS 로 잡으면 아티팩트가 추정치를 부풀려
/// 검출 임계가 아티팩트보다 높아지고 버스트를 통째로 놓친다.
/// 조용한 창에서는 중앙값 ≈ 평균이므로 공통 컨텍스트의 의도와 어긋나지 않는다.
class DcCalibrator {
  /// [clock] 은 [kDcCalibWindowMs] 를 표본 수로 바꾸는 데만 쓴다.
  ///
  /// 예전에는 창 길이를 `_window.length >= kDcCalibWindowMs` 로 **표본 개수**와
  /// 비교했다. fs 가 1000 이던 시절에는 그게 곧 1500ms 였지만, 4kHz 에서는
  /// 375ms 다. 표본 수는 1500 그대로라 중앙값·MAD 는 멀쩡해 보이는데,
  /// **관측한 시간**만 4분의 1로 줄어든다.
  ///
  /// 그게 왜 문제인가: 자극은 주기 1618ms(ON 591 / OFF 1027)로 돈다. 375ms
  /// 창은 쉼 구간 안에 통째로 들어갈 수 있어서, 자극이 돌고 있는데도
  /// [looksQuiet] 이 true 를 답한다. 부착 확인이 "이 구간에 자극이 섞였는가"를
  /// 묻는 근거가 조용히 사라지는 것이다.
  DcCalibrator({SampleClock clock = const SampleClock(kSampleRateHz)})
      : _need = math.max(clock.samples(kDcCalibWindowMs), kDcCalibMinSamples);

  /// 캘리브를 확정하기까지 모아야 할 표본 수.
  ///
  /// 시간으로는 [kDcCalibWindowMs] 지만, fs 가 아주 낮아도 중앙값·MAD 를 낼
  /// 만큼은 모으도록 [kDcCalibMinSamples] 를 하한으로 둔다.
  final int _need;

  final List<double> _window = <double>[];

  double? _offset;
  double _noiseSigma = 0.0;
  bool _looksQuiet = false;

  /// 캘리브 완료 여부.
  bool get isCalibrated => _offset != null;

  /// 추정된 DC offset (ADC LSB). 미완료면 null.
  double? get offset => _offset;

  /// 잡음 크기 추정 (MAD × 1.4826). 자극 검출 임계의 기준이 된다.
  ///
  /// 정규분포 가정에서 표준편차와 같은 스케일이지만, 아티팩트 같은
  /// 이상치에 끌려가지 않는다.
  double get noiseSigma => _noiseSigma;

  /// 캘리브 구간이 실제로 무자극이었는지.
  ///
  /// false 면 이 구간에 자극이 섞여 있었다는 뜻이다. 추정 자체는
  /// 중앙값·MAD 라 견디지만, 부착 체크에서는 이 값을 확인해야 한다.
  bool get looksQuiet => _looksQuiet;

  /// 지금까지 받은 샘플 수 (캘리브 구간 한정).
  int get sampleCount => _window.length;

  void add(int adc) {
    if (isCalibrated) return;
    _window.add(adc.toDouble());
    if (_window.length >= _need) _finalize();
  }

  void reset() {
    _window.clear();
    _offset = null;
    _noiseSigma = 0.0;
    _looksQuiet = false;
  }

  void _finalize() {
    final n = _window.length;
    final med = median(_window);

    var peak = 0.0;
    final dev = List<double>.filled(n, 0.0);
    for (var i = 0; i < n; i++) {
      final d = (_window[i] - med).abs();
      dev[i] = d;
      if (d > peak) peak = d;
    }

    final mad = median(dev);
    _noiseSigma = mad * kMadToSigma;

    final quietLimit = math.max(
      math.max(_noiseSigma, 1.0) * kStimThresholdNoiseMult,
      kStimThresholdFloorAdc,
    );
    _looksQuiet = peak <= quietLimit;

    _offset = med;
  }

}
