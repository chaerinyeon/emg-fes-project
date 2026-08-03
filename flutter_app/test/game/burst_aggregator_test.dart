import 'dart:convert';
import 'dart:io';

import 'package:flutter_app/game/engine/burst_aggregator.dart';
import 'package:flutter_test/flutter_test.dart';

/// `BurstAggregator` 가 오프라인과 같은 지점을 버스트 시작으로 고르는지 검증한다.
///
/// 기준벡터는 실측 세션 `raw_20260717_141940` 의 RAW 파형에서
/// `fes_fatigue_spc.py` 와 같은 규칙(`diff>20` → 펄스, `diff>800` → 버스트)으로
/// 뽑은 펄스·버스트 온셋이다. 같은 펄스 열을 흘려넣어 같은 버스트가 나와야 한다.
void main() {
  final ref = jsonDecode(File('test/game/burst_reference.json').readAsStringSync())
      as Map<String, dynamic>;
  final pulseMs = (ref['pulse_ms'] as List).cast<int>();
  final burstMs = (ref['burst_ms'] as List).cast<int>();

  test('실측 펄스열에서 오프라인과 같은 버스트를 고른다 '
      '(펄스 ${pulseMs.length} → 버스트 ${burstMs.length})', () {
    final agg = BurstAggregator();
    final got = <int>[];
    for (final ms in pulseMs) {
      final b = agg.addPulse(ms.toDouble(), 100.0);
      if (b != null) got.add((b.tSec * 1000).round());
    }
    expect(got, burstMs);
  });

  group('규칙', () {
    test('첫 펄스는 언제나 버스트 시작이다', () {
      final agg = BurstAggregator();
      expect(agg.addPulse(9, 500)?.tSec, closeTo(0.009, 1e-9));
    });

    test('버스트 안의 후속 펄스(31ms 간격)는 방출하지 않는다', () {
      final agg = BurstAggregator();
      agg.addPulse(0, 500);
      final inBurst = [
        for (var t = 31.0; t < 500; t += 31) agg.addPulse(t, 500),
      ];
      expect(inBurst.every((e) => e == null), isTrue);
    });

    test('800ms 넘게 벌어지면 새 버스트', () {
      final agg = BurstAggregator();
      agg.addPulse(0, 500);
      expect(agg.addPulse(800, 500), isNull, reason: '경계값 800은 같은 버스트');
      expect(agg.addPulse(1622, 700)?.amp, 700, reason: '실측 버스트 주기');
    });

    test('20ms 이내 중복 보고는 무시한다', () {
      final agg = BurstAggregator();
      agg.addPulse(0, 500);
      expect(agg.addPulse(5, 999), isNull);
      expect(agg.addPulse(15, 999), isNull);
    });

    test('버스트 첫 펄스의 진폭을 그대로 전달한다', () {
      final agg = BurstAggregator();
      expect(agg.addPulse(0, 461.8)?.amp, 461.8);
      agg.addPulse(31, 999);
      expect(agg.addPulse(1622, 300.5)?.amp, 300.5);
    });

    test('reset 후 다음 펄스가 다시 첫 버스트가 된다', () {
      final agg = BurstAggregator();
      agg.addPulse(0, 500);
      agg.reset();
      expect(agg.lastBurstSec, isNull);
      expect(agg.addPulse(10, 500), isNotNull);
    });
  });
}
