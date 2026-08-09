/// 관찰용 스펙트럼 지표 — RMS · MDF.
///
/// **피로 판정에 쓰지 않는다.** 완전마비 환자의 EMG 에는 자발 성분이 없어
/// 이 신호의 RMS·MDF 는 근육 상태가 아니라 자극 하모닉(32Hz 근방)의 크기와
/// 분포를 재는 값이다. 피로 판정의 근거는 M-wave 진폭 하나뿐이다
/// (`fatigue_engine.dart`).
///
/// 그럼에도 계산해 두는 이유는 두 가지다.
///   1. 불완전마비 환자는 잔존 자발 EMG 가 있어 보조 지표가 된다.
///   2. 치료사·보호자가 보는 곳(치료사 보기·홈의 기록)에서 신호가 세션 내내
///      같은 성질을 유지했는지 눈으로 확인할 수 있어야 한다.
///
/// 이 파일은 **순수 Dart** 다. `constants.dart` 와 같은 이유로 flutter 를
/// import 하지 않는다.
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// 제곱평균제곱근.
double rmsOf(List<double> xs) {
  if (xs.isEmpty) return 0;
  var acc = 0.0;
  for (final x in xs) {
    acc += x * x;
  }
  return math.sqrt(acc / xs.length);
}

/// 중앙주파수(Hz) — 파워 스펙트럼의 누적이 절반이 되는 지점.
///
/// [fs] 는 샘플레이트. 표본이 [minSamples] 보다 적으면 추정이 서지 않으므로
/// null 을 돌려준다 — 0을 돌려주면 "0Hz" 라는 없는 값이 그래프에 찍힌다.
double? medianFrequencyHz(
  List<double> xs, {
  double fs = 1000.0,
  int minSamples = 64,
}) {
  if (xs.length < minSamples) return null;

  // 2의 거듭제곱으로 맞춘다. 남는 뒤쪽은 버린다 — 0으로 채우면 스펙트럼이
  // 저주파 쪽으로 번져 MDF 가 실제보다 낮게 나온다.
  var n = 1;
  while (n * 2 <= xs.length) {
    n *= 2;
  }

  final re = Float64List(n);
  final im = Float64List(n);
  // 평균 제거 후 Hann 창. DC 성분이 남으면 중앙주파수가 0Hz 쪽으로 끌린다.
  var mean = 0.0;
  for (var i = 0; i < n; i++) {
    mean += xs[i];
  }
  mean /= n;
  for (var i = 0; i < n; i++) {
    final w = 0.5 - 0.5 * math.cos(2 * math.pi * i / (n - 1));
    re[i] = (xs[i] - mean) * w;
  }

  _fft(re, im);

  // 단측 파워 스펙트럼. DC(0) 와 나이퀴스트는 뺀다.
  final half = n ~/ 2;
  final power = Float64List(half);
  var total = 0.0;
  for (var k = 1; k < half; k++) {
    final p = re[k] * re[k] + im[k] * im[k];
    power[k] = p;
    total += p;
  }
  if (total <= 0) return null;

  var acc = 0.0;
  for (var k = 1; k < half; k++) {
    acc += power[k];
    if (acc >= total / 2) return k * fs / n;
  }
  return (half - 1) * fs / n;
}

/// 제자리 radix-2 FFT. [re]·[im] 의 길이는 2의 거듭제곱이어야 한다.
void _fft(Float64List re, Float64List im) {
  final n = re.length;
  if (n <= 1) return;

  // 비트 역순 재배열.
  for (var i = 1, j = 0; i < n; i++) {
    var bit = n >> 1;
    for (; j & bit != 0; bit >>= 1) {
      j ^= bit;
    }
    j ^= bit;
    if (i < j) {
      final tr = re[i];
      re[i] = re[j];
      re[j] = tr;
      final ti = im[i];
      im[i] = im[j];
      im[j] = ti;
    }
  }

  for (var len = 2; len <= n; len <<= 1) {
    final ang = -2 * math.pi / len;
    final wr = math.cos(ang);
    final wi = math.sin(ang);
    for (var i = 0; i < n; i += len) {
      var cr = 1.0;
      var ci = 0.0;
      for (var k = 0; k < len ~/ 2; k++) {
        final ar = re[i + k];
        final ai = im[i + k];
        final br = re[i + k + len ~/ 2] * cr - im[i + k + len ~/ 2] * ci;
        final bi = re[i + k + len ~/ 2] * ci + im[i + k + len ~/ 2] * cr;
        re[i + k] = ar + br;
        im[i + k] = ai + bi;
        re[i + k + len ~/ 2] = ar - br;
        im[i + k + len ~/ 2] = ai - bi;
        final nr = cr * wr - ci * wi;
        ci = cr * wi + ci * wr;
        cr = nr;
      }
    }
  }
}
