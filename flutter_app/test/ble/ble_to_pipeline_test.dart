import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/ble/device_connection.dart';
import 'package:flutter_app/signal/constants.dart';
import 'package:flutter_app/signal/signal_pipeline.dart';

/// BLE RAW 패킷 → 신호 엔진 배선 검증.
///
/// 오프라인 CSV 와 BLE 스트림이 **같은 경로**를 타야 회귀 테스트가 의미를
/// 갖는다. 여기서 갈라지면 CSV 로 검증한 것이 실기기에서 보장되지 않는다.

const int _dc = 1862;

List<int> _packet(int firstMs, List<int> samples) {
  final b = ByteData(6 + 2 * samples.length);
  b.setUint32(0, firstMs, Endian.little);
  b.setUint16(4, samples.length, Endian.little);
  for (var i = 0; i < samples.length; i++) {
    b.setInt16(6 + 2 * i, samples[i], Endian.little);
  }
  return b.buffer.asUint8List();
}

/// 펌웨어처럼 100표본씩 끊어 보낸다.
Stream<List<int>> _synthetic({
  int nBursts = 40,
  double amplitude = 600,
  int startMs = 2000,
}) async* {
  final onsets = <int>{};
  for (var b = 0; b < nBursts; b++) {
    for (var p = 0; p * 31 < kStimOnMs; p++) {
      onsets.add(startMs + b * kStimPeriodMs + p * 31);
    }
  }
  final end = startMs + nBursts * kStimPeriodMs + kStimOnMs + 200;

  final buf = <int>[];
  var first = 0;
  for (var t = 0; t <= end; t++) {
    var v = _dc;
    for (var d = 0; d <= 12; d++) {
      if (!onsets.contains(t - d)) continue;
      if (d == 0) v = _dc + 900;
      if (d == 8) v = _dc + (amplitude / 2).round();
      if (d == 12) v = _dc - (amplitude / 2).round();
    }
    if (buf.isEmpty) first = t;
    buf.add(v);
    if (buf.length == 100) {
      yield _packet(first, List<int>.of(buf));
      buf.clear();
    }
  }
  if (buf.isNotEmpty) yield _packet(first, buf);
}

void main() {
  test('BLE 패킷이 신호 엔진까지 흘러 버스트 결과가 나온다', () async {
    final pipeline = SignalPipeline();
    final results = <BurstResult>[];

    await for (final (t, adc) in rawSamples(_synthetic(nBursts: 40))) {
      final r = pipeline.addSample(t, adc);
      if (r != null) results.add(r);
    }
    results.addAll(pipeline.flush());

    expect(results.length, 40);
    expect(pipeline.periodMs, isNotNull);
    expect(pipeline.periodMs!, closeTo(kStimPeriodMs.toDouble(), 2.0));
    expect(results.last.p2p, closeTo(600.0, 2.0));
    expect(results.last.reliable, isTrue);
  });

  test('패킷이 통째로 유실돼도 남은 버스트는 정상 처리된다', () async {
    final pipeline = SignalPipeline();
    final results = <BurstResult>[];

    var i = 0;
    await for (final bytes in _synthetic(nBursts: 40)) {
      // 중간에 패킷 몇 개를 버린다 (BLE 끊김 구간)
      if (++i >= 200 && i < 210) continue;
      final p = rawSamples(Stream.value(bytes));
      await for (final (t, adc) in p) {
        final r = pipeline.addSample(t, adc);
        if (r != null) results.add(r);
      }
    }
    results.addAll(pipeline.flush());

    expect(results.length, greaterThan(30),
        reason: '유실 구간 몇 버스트만 잃고 나머지는 살아야 한다');
    for (var k = 1; k < results.length; k++) {
      expect(results[k].stimOnsetMs, greaterThan(results[k - 1].stimOnsetMs));
    }
  });

  test('표본 시각은 패킷 헤더를 따르고 앱이 만들어내지 않는다', () async {
    // 위상 고정이 헤더 시각에 걸려 있다. 앱이 도착 순서로 시각을 붙이면
    // 유실 구간에서 위상이 조용히 밀린다.
    final out = await rawSamples(Stream.fromIterable([
      _packet(0, [1, 2]),
      _packet(5000, [3, 4]),
    ])).toList();

    expect(out.map((e) => e.$1).toList(), [0, 1, 5000, 5001]);
  });
}
