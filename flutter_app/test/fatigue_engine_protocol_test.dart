import 'package:flutter_app/core/subject_category.dart';
import 'package:flutter_app/services/fatigue_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  FatigueResult update(
    FatigueEngine engine, {
    required double elapsed,
    double? rms,
    double? mdf,
    double? mwAmp,
    double? mwArea,
    double? mwLatency,
  }) {
    return engine.update(
      rmsSlope: 0,
      mdfSlope: 0,
      historyCount: elapsed.floor(),
      rms: rms,
      mdf: mdf,
      isStimulating: true,
      isFullTick: true,
      sessionElapsedSeconds: elapsed,
      mwAmp: mwAmp,
      mwArea: mwArea,
      mwLatency: mwLatency,
    );
  }

  test('baseline ignores samples before 30 seconds', () {
    final engine = FatigueEngine(category: SubjectCategory.healthy);

    for (var second = 0; second < 30; second++) {
      update(engine, elapsed: second.toDouble(), rms: 500, mdf: 10);
    }

    expect(engine.rmsChart.sampleCount, 0);
    expect(engine.mdfChart.sampleCount, 0);

    for (var second = 30; second < 38; second++) {
      update(
        engine,
        elapsed: second.toDouble(),
        rms: 100 + (second.isEven ? 2 : -2),
        mdf: 80 + (second.isEven ? 1 : -1),
      );
    }

    expect(engine.rmsChart.isEstablished, isTrue);
    expect(engine.mdfChart.isEstablished, isTrue);
  });

  test('complete paralysis protocol ignores RMS and MDF decisions', () {
    final engine = FatigueEngine(category: SubjectCategory.complete);
    FatigueResult? result;

    for (var second = 30; second < 50; second++) {
      result = update(
        engine,
        elapsed: second.toDouble(),
        rms: second < 38 ? 100 : 1000,
        mdf: second < 38 ? 80 : 5,
      );
    }

    expect(engine.rmsChart.sampleCount, 0);
    expect(engine.mdfChart.sampleCount, 0);
    expect(result!.detected, isFalse);
  });

  test('M-wave decision does not depend on latency', () {
    final engine = FatigueEngine(category: SubjectCategory.complete);
    const baselineAmp = [100.0, 102.0, 98.0, 101.0, 99.0, 100.0];
    const baselineArea = [1000.0, 1020.0, 980.0, 1010.0, 990.0, 1000.0];

    for (var i = 0; i < baselineAmp.length; i++) {
      update(
        engine,
        elapsed: 30.0 + i,
        mwAmp: baselineAmp[i],
        mwArea: baselineArea[i],
      );
    }

    FatigueResult? result;
    for (var i = 0; i < 5; i++) {
      result = update(engine, elapsed: 40.0 + i, mwAmp: 60, mwArea: 600);
    }

    expect(engine.mwLatChart.sampleCount, 0);
    expect(result!.detected, isTrue);
    expect(result.reasons, contains('M-wave 진폭 < LCL'));
    expect(result.reasons, isNot(contains('M-wave 잠복기 > UCL')));
  });
}
