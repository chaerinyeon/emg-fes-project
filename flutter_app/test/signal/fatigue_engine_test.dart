import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/signal/constants.dart';
import 'package:flutter_app/signal/fatigue_engine.dart';

const double _aRef = 500.0;

/// 워밍업이 끝난 시각부터 버스트를 흘린다.
FatigueSample _run(
  FatigueEngine e,
  List<double> p2ps, {
  double aRef = _aRef,
  double startS = kSyncWindowS + 1.0,
}) {
  late FatigueSample last;
  var t = startS;
  for (final v in p2ps) {
    last = e.add(p2p: v, aRef: aRef, tSeconds: t);
    t += kStimPeriodMs / 1000.0;
  }
  return last;
}

void main() {
  group('FatigueEngine [I] — 피로도%', () {
    test('워밍업 구간에서는 0이다', () {
      final e = FatigueEngine();
      final s = e.add(p2p: 100.0, aRef: _aRef, tSeconds: 5.0);
      expect(s.inWarmup, isTrue);
      expect(s.fatiguePct, 0.0);
    });

    test('A_ref와 같은 진폭이면 0%다', () {
      final e = FatigueEngine();
      final s = _run(e, List<double>.filled(60, _aRef));
      expect(s.fatiguePct, closeTo(0.0, 0.5));
    });

    test('A_ref의 절반이면 50%로 수렴한다', () {
      final e = FatigueEngine();
      final s = _run(e, List<double>.filled(120, _aRef / 2));
      expect(s.fatiguePct, closeTo(50.0, 1.0));
    });

    test('0~100으로 클램프된다', () {
      final e = FatigueEngine();
      expect(_run(e, List<double>.filled(120, 0.0)).fatiguePct,
          closeTo(100.0, 0.5));

      final e2 = FatigueEngine();
      // A_ref 를 넘는 진폭 → 음수가 되면 안 된다
      expect(_run(e2, List<double>.filled(60, _aRef * 2)).fatiguePct, 0.0);
    });

    test('진폭이 오르는 동안(전위증강)은 피로가 아니다', () {
      // A_ref 가 running peak 이므로 상승 중엔 p2p == aRef 다.
      final e = FatigueEngine();
      var t = kSyncWindowS + 1.0;
      var v = 300.0;
      for (var i = 0; i < 30; i++) {
        final s = e.add(p2p: v, aRef: v, tSeconds: t);
        expect(s.fatiguePct, closeTo(0.0, 1e-9));
        v += 10;
        t += kStimPeriodMs / 1000.0;
      }
    });

    test('EMA가 단발 요동을 눌러 준다', () {
      final e = FatigueEngine();
      final steady = List<double>.filled(40, _aRef);
      _run(e, steady);
      final jolt = e.add(
          p2p: 0.0, aRef: _aRef, tSeconds: kSyncWindowS + 200.0);
      expect(jolt.fatiguePct, lessThan(100.0 * kFatigueEmaAlpha + 5.0),
          reason: '한 버스트 튀었다고 피로가 만점이 되면 안 된다');
    });

    test('A_ref가 0이면 판정을 보류한다', () {
      final e = FatigueEngine();
      final s = e.add(p2p: 0.0, aRef: 0.0, tSeconds: 100.0);
      expect(s.valid, isFalse);
      expect(s.fatiguePct, 0.0);
    });
  });

  group('FatigueEngine [J] — 수축 성공 판정', () {
    test('A_ref × K 이상이면 성공이다', () {
      final e = FatigueEngine();
      final s = e.add(
          p2p: _aRef * kContractionK + 1, aRef: _aRef, tSeconds: 100.0);
      expect(s.contractionOk, isTrue);
    });

    test('A_ref × K 미만이면 실패다', () {
      final e = FatigueEngine();
      final s = e.add(
          p2p: _aRef * kContractionK - 1, aRef: _aRef, tSeconds: 100.0);
      expect(s.contractionOk, isFalse);
    });

    test('수축 판정은 EMA가 아니라 이번 버스트 값으로 한다', () {
      // 게임 피드백은 stimOnset+15ms 에 나가야 한다. 평활값을 기다릴 수 없다.
      final e = FatigueEngine();
      _run(e, List<double>.filled(40, _aRef));
      final s = e.add(p2p: 10.0, aRef: _aRef, tSeconds: kSyncWindowS + 200.0);
      expect(s.contractionOk, isFalse,
          reason: 'EMA 를 썼다면 아직 성공으로 남아 있었을 것');
    });

    test('워밍업 중에도 수축 판정은 나온다', () {
      final e = FatigueEngine();
      final s = e.add(p2p: _aRef, aRef: _aRef, tSeconds: 3.0);
      expect(s.inWarmup, isTrue);
      expect(s.contractionOk, isTrue);
    });
  });

  group('FatigueEngine [J] — 손 상태', () {
    test('자극 ON + 수축 성공 = 쥠', () {
      expect(handStateFor(stimOn: true, contractionOk: true), HandState.closed);
    });

    test('자극 ON + 수축 실패 = 실패 (전극 접촉 불량 또는 강도 부족)', () {
      expect(handStateFor(stimOn: true, contractionOk: false),
          HandState.failedContraction);
    });

    test('자극 OFF = 폄', () {
      expect(handStateFor(stimOn: false, contractionOk: true), HandState.open);
      expect(handStateFor(stimOn: false, contractionOk: false), HandState.open);
    });
  });

  group('FatigueEngine — 급등은 피로가 아니다 (하드 제약 5)', () {
    test('32초 내 30%p 급등은 센서 점검으로 분기한다', () {
      final e = FatigueEngine();
      _run(e, List<double>.filled(60, _aRef));

      var t = kSyncWindowS + 200.0;
      late FatigueSample s;
      // 진폭이 갑자기 뚝 떨어진다 (전극·자세 변화)
      for (var i = 0; i < 12; i++) {
        s = e.add(p2p: _aRef * 0.2, aRef: _aRef, tSeconds: t);
        t += kStimPeriodMs / 1000.0;
      }
      expect(s.fatiguePct, greaterThan(kFatigueSpikePct));
      expect(s.spikeSuspected, isTrue);
      expect(s.advice, FatigueAdvice.checkSensor);
    });

    test('완만한 상승은 급등으로 보지 않는다', () {
      final e = FatigueEngine();
      var t = kSyncWindowS + 1.0;
      late FatigueSample s;
      // 400버스트(약 11분)에 걸쳐 서서히 −40%
      for (var i = 0; i < 400; i++) {
        s = e.add(
            p2p: _aRef * (1.0 - 0.40 * i / 399), aRef: _aRef, tSeconds: t);
        t += kStimPeriodMs / 1000.0;
      }
      expect(s.fatiguePct, greaterThan(30.0));
      expect(s.spikeSuspected, isFalse,
          reason: '진짜 피로를 센서 문제로 돌리면 안 된다');
      expect(s.advice, FatigueAdvice.normal);
    });
  });
}
