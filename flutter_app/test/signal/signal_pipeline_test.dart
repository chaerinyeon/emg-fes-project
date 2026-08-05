import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/signal/constants.dart';
import 'package:flutter_app/signal/signal_pipeline.dart';

/// 합성 세션 생성기.
///
/// [amplitudeAt] 은 버스트 번호 → M-wave p2p 진폭.
class SyntheticSession {
  SyntheticSession({
    this.dc = 1862,
    this.nBursts = 60,
    this.period = kStimPeriodMs,
    this.startMs = 2000,
    this.artifact = 900,
    required this.amplitudeAt,
  });

  final int dc;
  final int nBursts;
  final int period;
  final int startMs;
  final int artifact;
  final double Function(int burstIndex) amplitudeAt;

  /// (timeMs, adc) 샘플을 순서대로 낸다.
  Iterable<(int, int)> samples() sync* {
    final end = startMs + nBursts * period + kStimOnMs + 200;
    // onset → 진폭
    final onsetAmp = <int, double>{};
    for (var b = 0; b < nBursts; b++) {
      for (var p = 0; p * 31 < kStimOnMs; p++) {
        onsetAmp[startMs + b * period + p * 31] = amplitudeAt(b);
      }
    }
    for (var t = 0; t <= end; t++) {
      var v = dc;
      for (var d = 0; d <= 12; d++) {
        final amp = onsetAmp[t - d];
        if (amp == null) continue;
        if (d == 0) v = dc + artifact;
        if (d == 8) v = dc + (amp / 2).round();
        if (d == 12) v = dc - (amp / 2).round();
      }
      yield (t, v);
    }
  }
}

List<BurstResult> runAll(SignalPipeline p, SyntheticSession s) {
  final out = <BurstResult>[];
  for (final (t, adc) in s.samples()) {
    final r = p.addSample(t, adc);
    if (r != null) out.add(r);
  }
  out.addAll(p.flush());
  return out;
}

void main() {
  group('SignalPipeline — 기본 동작', () {
    test('버스트마다 결과가 하나씩 나온다', () {
      final s = SyntheticSession(nBursts: 40, amplitudeAt: (_) => 600.0);
      final results = runAll(SignalPipeline(), s);
      expect(results.length, 40);
      expect(results.map((r) => r.index).toList(),
          List<int>.generate(40, (i) => i));
    });

    test('stimOnsetMs가 실제 자극 시점과 일치한다', () {
      final s = SyntheticSession(nBursts: 10, amplitudeAt: (_) => 600.0);
      final results = runAll(SignalPipeline(), s);
      for (var i = 0; i < results.length; i++) {
        expect(results[i].stimOnsetMs, s.startMs + i * s.period);
      }
    });

    test('버스트당 이벤트 수를 센다', () {
      final s = SyntheticSession(nBursts: 10, amplitudeAt: (_) => 600.0);
      final results = runAll(SignalPipeline(), s);
      // 591ms ON / 31ms → 20발
      for (final r in results) {
        expect(r.eventsInBurst, 20);
      }
    });

    test('p2p가 심어 둔 진폭을 되살린다', () {
      final s = SyntheticSession(nBursts: 30, amplitudeAt: (_) => 600.0);
      final results = runAll(SignalPipeline(), s);
      expect(results.last.p2p, closeTo(600.0, 2.0));
    });

    test('DC를 하드코딩하지 않는다 — baseline이 달라도 같은 p2p', () {
      for (final dc in [1723, 1862, 1954]) {
        final s = SyntheticSession(
            dc: dc, nBursts: 30, amplitudeAt: (_) => 600.0);
        final results = runAll(SignalPipeline(), s);
        expect(results.last.p2p, closeTo(600.0, 2.0),
            reason: 'DC=$dc 에서 실패');
      }
    });

    test('주기를 추정한다', () {
      final s = SyntheticSession(nBursts: 30, amplitudeAt: (_) => 600.0);
      final p = SignalPipeline();
      runAll(p, s);
      expect(p.periodMs, isNotNull);
      expect(p.periodMs!, closeTo(kStimPeriodMs.toDouble(), 2.0));
    });

    test('flush가 마지막 버스트를 흘리지 않고 내보낸다', () {
      final s = SyntheticSession(nBursts: 5, amplitudeAt: (_) => 600.0);
      final results = runAll(SignalPipeline(), s);
      expect(results.length, 5);
    });
  });

  group('SignalPipeline — 피로', () {
    test('워밍업 구간에서는 피로도가 0이다', () {
      final s = SyntheticSession(nBursts: 60, amplitudeAt: (_) => 600.0);
      final results = runAll(SignalPipeline(), s);
      final warm = results.where((r) => r.tSeconds < kSyncWindowS);
      expect(warm, isNotEmpty);
      expect(warm.every((r) => r.fatiguePct == 0.0), isTrue);
    });

    test('진폭이 꾸준히 떨어지면 피로도가 오른다', () {
      final s = SyntheticSession(
        nBursts: 300,
        amplitudeAt: (b) => 600.0 * (1.0 - 0.45 * b / 299),
      );
      final results = runAll(SignalPipeline(), s);
      expect(results.last.fatiguePct, greaterThan(30.0));
      expect(results.last.levelSegmentIndex, 0,
          reason: '완만한 피로는 레벨 시프트가 아니다');
    });

    test('진폭이 일정하면 피로도가 오르지 않는다', () {
      final s = SyntheticSession(nBursts: 200, amplitudeAt: (_) => 600.0);
      final results = runAll(SignalPipeline(), s);
      expect(results.last.fatiguePct, lessThan(5.0));
    });

    test('세션 초반 전위증강을 피로로 세지 않는다', () {
      final s = SyntheticSession(
        nBursts: 120,
        // 앞 40버스트 상승 후 평탄
        amplitudeAt: (b) => b < 40 ? 400.0 + b * 5.0 : 600.0,
      );
      final results = runAll(SignalPipeline(), s);
      expect(results.last.fatiguePct, lessThan(5.0));
    });
  });

  group('SignalPipeline — 글리치와 레벨', () {
    test('단발 글리치가 피로도를 끌어올리지 않는다', () {
      final clean = SyntheticSession(nBursts: 120, amplitudeAt: (_) => 600.0);
      final glitchy = SyntheticSession(
        nBursts: 120,
        amplitudeAt: (b) => b == 80 ? 150.0 : 600.0,
      );
      final a = runAll(SignalPipeline(), clean);
      final b = runAll(SignalPipeline(), glitchy);

      double maxFatigue(List<BurstResult> rs) =>
          rs.map((r) => r.fatiguePct).reduce((x, y) => x > y ? x : y);

      expect(maxFatigue(b), closeTo(maxFatigue(a), 5.0),
          reason: 'Hampel 을 빼면 글리치가 피로도로 둔갑한다');
    });

    test('계단식 레벨 변화는 새 구간으로 잡는다', () {
      final s = SyntheticSession(
        nBursts: 160,
        amplitudeAt: (b) => b < 80 ? 600.0 : 300.0,
      );
      final results = runAll(SignalPipeline(), s);
      expect(results.last.levelSegmentIndex, greaterThanOrEqualTo(1));
    });
  });

  group('SignalPipeline — 신뢰도', () {
    test('정상 세션은 reliable이다', () {
      final s = SyntheticSession(nBursts: 40, amplitudeAt: (_) => 600.0);
      final results = runAll(SignalPipeline(), s);
      expect(results.last.reliable, isTrue);
    });
  });

  group('SignalPipeline — 스트림 API', () {
    test('Stream 입력을 Stream 출력으로 바꾼다', () async {
      final s = SyntheticSession(nBursts: 20, amplitudeAt: (_) => 600.0);
      final p = SignalPipeline();
      final results =
          await p.process(Stream<(int, int)>.fromIterable(s.samples()))
              .toList();
      expect(results.length, 20);
    });
  });
}
