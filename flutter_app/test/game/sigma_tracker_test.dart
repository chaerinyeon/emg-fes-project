import 'dart:convert';
import 'dart:io';

import 'package:flutter_app/game/engine/sigma_tracker.dart';
import 'package:flutter_app/game/model/zone.dart';
import 'package:flutter_test/flutter_test.dart';

/// `SigmaTracker` 가 오프라인 기준 구현과 같은 값을 내는지 검증한다.
///
/// 기준벡터 `spc_reference.json` 은 `~/emgfes-data/fes_fatigue_spc.py` 의
/// `hampel()`·`analyze()` 를 **직접 import 해서** 실측 세션 3개에 돌린 결과다.
/// 재구현본끼리 비교하는 게 아니라 원본 출력과 대조하는 것이라, 통과하면
/// "파이썬과 같다"가 실제로 보장된다.
///
/// 3세션은 서로 다른 경로를 덮는다:
///   141940  피로 도달(3σ), base_cv 0.226 (변동 큼)
///   002130  급격한 피로(maxz 7.8), base_cv 0.065 (변동 작음)
///   202248  3σ 미도달 → t3 == null 경로
void main() {
  final refs = (jsonDecode(File('test/game/spc_reference.json').readAsStringSync())
          as List)
      .cast<Map<String, dynamic>>();

  List<double> nums(Map<String, dynamic> m, String k) =>
      (m[k] as List).cast<num>().map((e) => e.toDouble()).toList();

  group('오프라인 기준 구현과 일치', () {
    for (final r in refs) {
      final session = r['session'] as String;
      final rawAmp = nums(r, 'raw_amp');
      final amp = nums(r, 'amp');
      final t = nums(r, 't');
      final zsig = nums(r, 'zsig');

      test('$session (n=${rawAmp.length})', () {
        final tracker = SigmaTracker();
        for (var i = 0; i < rawAmp.length; i++) {
          tracker.addBurst(t[i], rawAmp[i]);
        }
        tracker.flush();

        expect(tracker.length, rawAmp.length, reason: '표본 수');

        // ① Hampel 이식
        final filtered = tracker.filteredAmplitudes;
        for (var i = 0; i < amp.length; i++) {
          expect(filtered[i], closeTo(amp[i], 1e-6), reason: 'hampel[$i]');
        }

        // ② 견고 baseline
        expect(tracker.isBaselineEstablished, isTrue);
        expect(tracker.mu0, closeTo(r['mu0'] as double, 1e-6), reason: 'mu0');
        expect(tracker.sd0, closeTo(r['sd0'] as double, 1e-6), reason: 'sd0');
        expect(tracker.baseCv, closeTo(r['cv'] as double, 1e-9), reason: 'base_cv');

        // ③ EWMA → σ 계열 전체
        final got = tracker.history;
        for (var i = 0; i < zsig.length; i++) {
          expect(got[i].z, closeTo(zsig[i], 1e-6),
              reason: 'zsig[$i] (t=${t[i]}s)');
        }

        // ④ 5연속 지속 존 도달 시각 (null 경로 포함)
        for (final (name, expected, actual) in [
          ('t1', r['t1'], tracker.t1),
          ('t2', r['t2'], tracker.t2),
          ('t3', r['t3'], tracker.t3),
        ]) {
          if (expected == null) {
            expect(actual, isNull, reason: '$name 은 도달하지 않아야 한다');
          } else {
            expect(actual, closeTo((expected as num).toDouble(), 1e-6),
                reason: name);
          }
        }
      });
    }
  });

  group('실시간 동작', () {
    /// 결정론적 잡음 — 실제 EMG처럼 값이 흔들려야 MAD가 0이 되지 않는다.
    /// (정확히 교대하는 2준위 신호는 창 중앙값 편차가 전부 0이라 Hampel이
    ///  전부를 이상치로 만든다. 실측에는 없는 병리적 입력이다.)
    double noise(int i) {
      final x = (i * 1103515245 + 12345) & 0x7fffffff;
      return (x % 1000) / 1000.0 - 0.5;
    }

    SigmaTracker feed({
      required int baselineBursts,
      required int monitorBursts,
      required double baseAmp,
      required double monitorAmp,
      double Function(int i)? override,
    }) {
      final tr = SigmaTracker();
      var t = 0.0;
      for (var i = 0; i < baselineBursts + monitorBursts; i++, t += 1.6) {
        final base = i < baselineBursts ? baseAmp : monitorAmp;
        tr.addBurst(t, override?.call(i) ?? base + 40 * noise(i));
      }
      tr.flush();
      return tr;
    }

    test('90초 전에는 baseline이 없다 — σ도 존도 null', () {
      final tr = SigmaTracker();
      for (var i = 0; i < 40; i++) {
        tr.addBurst(i * 1.6, 500.0 + 40 * noise(i)); // 64초까지
      }
      expect(tr.isBaselineEstablished, isFalse);
      expect(tr.currentSigma, isNull);
      expect(tr.currentZone, isNull, reason: '모르는 것을 정상으로 단정하면 안 된다');
      expect(tr.t3, isNull);
    });

    test('Hampel 창 때문에 σ 확정이 3버스트 늦다', () {
      final tr = SigmaTracker();
      for (var i = 0; i < 10; i++) {
        tr.addBurst(i * 1.6, 500.0 + 40 * noise(i));
      }
      expect(tr.length, 10 - 3, reason: '마지막 3개는 미래 표본 대기 중');
      tr.flush();
      expect(tr.length, 10, reason: 'flush 후 꼬리까지 확정');
    });

    test('진폭이 떨어지면 σ가 오르고 위험까지 간다', () {
      final tr = feed(
        baselineBursts: 70,
        monitorBursts: 60,
        baseAmp: 500,
        monitorAmp: 300,
      );
      expect(tr.isBaselineEstablished, isTrue);
      expect(tr.currentSigma, greaterThan(3.0));
      expect(tr.currentZone, FatigueZone.danger);
      expect(tr.t1, isNotNull);
      expect(tr.t3, isNotNull);
      expect(tr.t1!, lessThanOrEqualTo(tr.t3!),
          reason: '3σ가 1σ보다 먼저 올 수는 없다');
      expect(tr.t1!, greaterThanOrEqualTo(SigmaTracker.baseT1),
          reason: 'baseline 구간에서는 도달을 세지 않는다');
    });

    test('진폭이 유지되면 어느 존에도 도달하지 않는다', () {
      final tr = feed(
        baselineBursts: 70,
        monitorBursts: 60,
        baseAmp: 500,
        monitorAmp: 500,
      );
      expect(tr.isBaselineEstablished, isTrue);
      expect(tr.t1, isNull);
      expect(tr.currentZone, FatigueZone.normal);
    });

    test('단발 글리치는 Hampel이 제거한다', () {
      final clean = feed(
        baselineBursts: 70, monitorBursts: 30, baseAmp: 500, monitorAmp: 500);
      final spiked = feed(
        baselineBursts: 70, monitorBursts: 30, baseAmp: 500, monitorAmp: 500,
        override: (i) => i == 85 ? 50000.0 : 500.0 + 40 * noise(i));
      expect(spiked.t3, isNull, reason: '전극 글리치 한 점이 위험 경보를 울리면 안 된다');
      expect(spiked.mu0, closeTo(clean.mu0!, 1e-9));
    });

    test('죽은 신호(평평한 baseline)는 위험이 아니라 "측정 중"이다', () {
      // MAD=0 → sd0≈1e-9 → 보호장치가 없으면 z가 수십억으로 튀어 즉시 3σ.
      final tr = feed(
        baselineBursts: 70, monitorBursts: 30, baseAmp: 500, monitorAmp: 400,
        override: (i) => 500.0);
      expect(tr.isBaselineEstablished, isFalse,
          reason: '상수 신호로는 baseline을 세울 수 없다');
      expect(tr.currentSigma, isNull);
      expect(tr.currentZone, isNull);
      expect(tr.t3, isNull, reason: '죽은 신호가 3σ 경보를 울리면 안 된다');
    });

    test('reset 후 상태가 비워진다', () {
      final tr = feed(
        baselineBursts: 70, monitorBursts: 30, baseAmp: 500, monitorAmp: 300);
      expect(tr.isBaselineEstablished, isTrue);
      tr.reset();
      expect(tr.length, 0);
      expect(tr.isBaselineEstablished, isFalse);
      expect(tr.currentSigma, isNull);
      expect(tr.history, isEmpty);
    });
  });

  group('존 경계', () {
    test('Western Electric 규칙대로 갈린다', () {
      expect(zoneOf(0.99), FatigueZone.normal);
      expect(zoneOf(1.0), FatigueZone.caution);
      expect(zoneOf(1.99), FatigueZone.caution);
      expect(zoneOf(2.0), FatigueZone.warning);
      expect(zoneOf(2.99), FatigueZone.warning);
      expect(zoneOf(3.0), FatigueZone.danger);
      expect(zoneOf(-0.5), FatigueZone.normal, reason: '증강(음수 z)은 정상');
    });

    test('스태미나는 0~100%로 잘린다', () {
      expect(staminaPercent(0), 100);
      expect(staminaPercent(2), 50);
      expect(staminaPercent(4), 0);
      expect(staminaPercent(9), 0, reason: '4σ를 넘어도 음수가 되면 안 된다');
      expect(staminaPercent(-1), 100);
    });
  });
}
