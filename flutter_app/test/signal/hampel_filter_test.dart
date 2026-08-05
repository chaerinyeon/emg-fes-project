import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/signal/constants.dart';
import 'package:flutter_app/signal/hampel_filter.dart';

void main() {
  group('HampelFilter [G] — 중심창 (오프라인 파이프라인 대조용)', () {
    test('상수열은 그대로 둔다', () {
      final x = List<double>.filled(20, 42.0);
      expect(HampelFilter.applyCentered(x), equals(x));
    });

    test('단발 글리치를 국소 중앙값으로 바꾼다', () {
      final x = List<double>.filled(20, 10.0);
      x[7] = 1000.0;
      final y = HampelFilter.applyCentered(x);
      expect(y[7], closeTo(10.0, 1e-9));
    });

    test('원본 리스트를 변형하지 않는다', () {
      final x = List<double>.filled(20, 10.0);
      x[7] = 1000.0;
      HampelFilter.applyCentered(x);
      expect(x[7], 1000.0);
    });

    test('가장자리도 잘린 창으로 처리한다', () {
      final x = List<double>.filled(20, 10.0);
      x[0] = 1000.0;
      x[19] = 1000.0;
      final y = HampelFilter.applyCentered(x);
      expect(y[0], closeTo(10.0, 1e-9));
      expect(y[19], closeTo(10.0, 1e-9));
    });

    test('지속되는 레벨 시프트는 뭉개지 않는다', () {
      // [H] 가 레벨 구간을 잡아야 하므로 계단이 살아 있어야 한다.
      final x = <double>[...List.filled(10, 100.0), ...List.filled(10, 300.0)];
      final y = HampelFilter.applyCentered(x);
      expect(y.sublist(0, 10), everyElement(closeTo(100.0, 1e-9)));
      expect(y.sublist(10), everyElement(closeTo(300.0, 1e-9)));
    });

    test('글리치 세션의 최대 피로도를 낮춘다 — 실측 회귀', () {
      // 실측: Hampel 하나로 최대 피로도가 52%(글리치)에서 27.4%(실제)로 정정.
      // 진폭 급락 글리치가 있으면 A_ref 대비 낙폭이 과대평가된다.
      final amp = List<double>.filled(60, 500.0);
      amp[30] = 240.0; // 전극 순간 접촉 불량
      final filtered = HampelFilter.applyCentered(amp);

      double maxFatigue(List<double> a) {
        final ref = a.reduce((p, q) => p > q ? p : q);
        var worst = 0.0;
        for (final v in a) {
          final f = (1 - v / ref) * 100;
          if (f > worst) worst = f;
        }
        return worst;
      }

      expect(maxFatigue(amp), greaterThan(50.0));
      expect(maxFatigue(filtered), lessThan(1.0));
    });

    test('빈 입력과 창보다 짧은 입력을 견딘다', () {
      expect(HampelFilter.applyCentered(const []), isEmpty);
      expect(HampelFilter.applyCentered(const [5.0]), equals([5.0]));
    });

    test('k와 sigma는 상수 테이블에서 온다', () {
      expect(kHampelK, 7);
      expect(kHampelSigma, 3.0);
    });
  });

  group('OnlineHampel [G] — 인과 (실시간용)', () {
    test('상수열은 그대로 통과한다', () {
      final h = OnlineHampel();
      for (var i = 0; i < 20; i++) {
        expect(h.add(42.0), closeTo(42.0, 1e-9));
      }
    });

    test('글리치를 즉시 눌러 준다 — 지연 없음', () {
      final h = OnlineHampel();
      for (var i = 0; i < 10; i++) {
        h.add(500.0);
      }
      expect(h.add(50.0), closeTo(500.0, 1e-9));
    });

    test('워밍업 구간에서는 통과시킨다', () {
      final h = OnlineHampel();
      expect(h.add(500.0), closeTo(500.0, 1e-9));
      expect(h.add(700.0), closeTo(700.0, 1e-9));
    });

    test('지속되는 새 레벨은 결국 받아들인다', () {
      final h = OnlineHampel();
      for (var i = 0; i < 20; i++) {
        h.add(500.0);
      }
      final out = <double>[];
      for (var i = 0; i < 12; i++) {
        out.add(h.add(200.0));
      }
      // 처음 몇 개는 글리치로 눌리지만, 창이 새 레벨로 채워지면 통과한다.
      expect(out.first, closeTo(500.0, 1e-9));
      expect(out.last, closeTo(200.0, 1e-9));
    });

    test('reset하면 워밍업부터 다시 시작한다', () {
      final h = OnlineHampel();
      for (var i = 0; i < 10; i++) {
        h.add(500.0);
      }
      h.reset();
      expect(h.add(50.0), closeTo(50.0, 1e-9));
    });
  });
}
