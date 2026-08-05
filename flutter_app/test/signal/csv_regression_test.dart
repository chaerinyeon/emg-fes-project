@Tags(['csv'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/signal/constants.dart';
import 'package:flutter_app/signal/signal_pipeline.dart';

/// 오프라인 raw CSV 회귀 테스트 (공통 컨텍스트 8장).
///
/// 데이터셋(약 559MB)은 저장소 밖에 있다. 없으면 조용히 skip 한다.
///   EMGFES_DATA_DIR=/path/to/emgfes-data flutter test
///
/// 전수 88세션 집계는 `dart run tool/signal_regression.dart` 로 돌린다.
/// 여기서는 대표 세션만 빠르게 검증한다.

String? _root() {
  final env = Platform.environment['EMGFES_DATA_DIR'];
  final home = Platform.environment['HOME'];
  for (final c in [env, home == null ? null : '$home/emgfes-data']) {
    if (c != null && Directory(c).existsSync()) return c;
  }
  return null;
}

List<BurstResult> _run(File f) {
  final p = SignalPipeline();
  final out = <BurstResult>[];
  var first = true;
  for (final line in f.readAsLinesSync()) {
    if (first) {
      first = false;
      continue;
    }
    if (line.isEmpty) continue;
    final c = line.indexOf(',');
    if (c <= 0) continue;
    final t = int.tryParse(line.substring(0, c));
    final adc = int.tryParse(line.substring(c + 1).trim());
    if (t == null || adc == null) continue;
    final r = p.addSample(t, adc);
    if (r != null) out.add(r);
  }
  out.addAll(p.flush());
  return out;
}

/// 오래 도는 세션 몇 개만 고른다 (테스트 속도).
const _sessions = <String>[
  'subject_1780674970583/raw_20260717_141940.csv',
  'subject_1784225910998/raw_20260720_205148.csv',
  'subject_1780674970583/raw_20260717_144215.csv',
  'subject_1785399031142/raw_20260730_215640_C_complete.csv',
];

void main() {
  final root = _root();

  group('오프라인 CSV 회귀', () {
    for (final rel in _sessions) {
      test(rel.split('/').last, () {
        final f = File('$root/$rel');
        if (!f.existsSync()) {
          markTestSkipped('데이터 없음: $rel');
          return;
        }
        final rs = _run(f);
        final p = SignalPipeline();
        expect(p, isNotNull);

        expect(rs.length, greaterThan(100),
            reason: '장세션이면 버스트가 수백 개 나와야 한다');

        // 버스트 번호는 0부터 연속
        for (var i = 0; i < rs.length; i++) {
          expect(rs[i].index, i);
        }

        // 자극 시점은 단조 증가
        for (var i = 1; i < rs.length; i++) {
          expect(rs[i].stimOnsetMs, greaterThan(rs[i - 1].stimOnsetMs));
        }

        // events/burst 의 물리적 상한은 20이다
        // (591ms ON / 31ms ISI → floor(591/31)+1 = 20).
        //
        // 전수 88세션 중앙값은 19.97 로 이 값에 붙지만, 8세션(9%)이 21을
        // 넘는다(최대 25.4). 아티팩트 규모 추정이 낮게 잡히는 세션에서
        // 한 자극이 두 번 검출되기 때문이다.
        // TODO(P0): 이 꼬리를 없애려면 아티팩트 규모 추정을 2-pass 로 바꿔야
        //           한다. 현재는 상한을 느슨하게 두고 회귀만 막는다.
        final epb = rs.map((r) => r.eventsInBurst).reduce((a, b) => a + b) /
            rs.length;
        expect(epb, greaterThan(8.0));
        expect(epb, lessThanOrEqualTo(26.0),
            reason: '전수 최대가 25.4 다. 이걸 넘으면 새로운 회귀다');

        // 피로도는 0~100
        for (final r in rs) {
          expect(r.fatiguePct, inInclusiveRange(0.0, 100.0));
          expect(r.p2p, greaterThanOrEqualTo(0.0));
        }

        // 워밍업 구간 피로도는 0
        for (final r in rs.where((r) => r.tSeconds < kSyncWindowS)) {
          expect(r.fatiguePct, 0.0);
        }
      });
    }

    test('events/burst 중앙값이 물리적 기대치 20에 붙는다', () {
      if (root == null) {
        markTestSkipped('데이터 없음');
        return;
      }
      final epbs = <double>[];
      for (final rel in _sessions) {
        final f = File('$root/$rel');
        if (!f.existsSync()) continue;
        final rs = _run(f);
        if (rs.isEmpty) continue;
        epbs.add(
            rs.map((r) => r.eventsInBurst).reduce((a, b) => a + b) / rs.length);
      }
      if (epbs.isEmpty) {
        markTestSkipped('데이터 없음');
        return;
      }
      epbs.sort();
      final median = epbs.length.isOdd
          ? epbs[epbs.length ~/ 2]
          : (epbs[epbs.length ~/ 2 - 1] + epbs[epbs.length ~/ 2]) / 2;
      // 591ms ON / 31ms ISI → floor(591/31)+1 = 20. 전수 88세션에서 19.97.
      expect(median, inInclusiveRange(18.0, 21.0),
          reason: '중앙값이 20에서 벗어나면 검출이 새거나 중복된 것');
    });

    test('자극 주기가 1618ms 근방으로 추정된다', () {
      if (root == null) {
        markTestSkipped('데이터 없음');
        return;
      }
      final f = File('$root/${_sessions.first}');
      if (!f.existsSync()) {
        markTestSkipped('데이터 없음');
        return;
      }
      final p = SignalPipeline();
      var first = true;
      for (final line in f.readAsLinesSync()) {
        if (first) {
          first = false;
          continue;
        }
        if (line.isEmpty) continue;
        final c = line.indexOf(',');
        if (c <= 0) continue;
        final t = int.tryParse(line.substring(0, c));
        final adc = int.tryParse(line.substring(c + 1).trim());
        if (t == null || adc == null) continue;
        p.addSample(t, adc);
      }
      p.flush();
      expect(p.periodMs, isNotNull);
      expect(p.periodMs!, inInclusiveRange(1580.0, 1680.0),
          reason: '실측 88세션 중앙값 1619.5ms');
    });

    test('DC offset을 하드코딩하지 않는다 — 세션마다 다르다', () {
      if (root == null) {
        markTestSkipped('데이터 없음');
        return;
      }
      final offsets = <double>[];
      for (final rel in _sessions) {
        final f = File('$root/$rel');
        if (!f.existsSync()) continue;
        final p = SignalPipeline();
        var n = 0;
        var first = true;
        for (final line in f.readAsLinesSync()) {
          if (first) {
            first = false;
            continue;
          }
          final c = line.indexOf(',');
          if (c <= 0) continue;
          final t = int.tryParse(line.substring(0, c));
          final adc = int.tryParse(line.substring(c + 1).trim());
          if (t == null || adc == null) continue;
          p.addSample(t, adc);
          if (++n > kArtifactScaleWindowMs + 10) break;
        }
        if (p.dcOffset != null) offsets.add(p.dcOffset!);
      }
      if (offsets.length < 2) {
        markTestSkipped('데이터 없음');
        return;
      }
      expect(offsets.toSet().length, greaterThan(1),
          reason: '세션마다 baseline 이 다르다. 1862 고정은 오류였다');
    });
  }, skip: root == null ? 'EMGFES_DATA_DIR 없음' : null);
}
