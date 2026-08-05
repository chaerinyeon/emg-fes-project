import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/signal/constants.dart';
import 'package:flutter_app/signal/level_tracker.dart';

void main() {
  group('LevelTracker [H] — A_ref running peak', () {
    test('첫 버스트부터 A_ref가 나온다', () {
      final t = LevelTracker();
      t.add(500.0);
      expect(t.aRef, closeTo(500.0, 1e-9));
      expect(t.segmentIndex, 0);
    });

    test('A_ref는 상승만 한다 (running peak)', () {
      final t = LevelTracker();
      for (final v in [100.0, 300.0, 200.0, 500.0, 400.0]) {
        t.add(v);
      }
      expect(t.aRef, closeTo(500.0, 1e-9));
    });

    test('진폭이 떨어져도 A_ref는 내려가지 않는다', () {
      final t = LevelTracker();
      t.add(500.0);
      for (var i = 0; i < 20; i++) {
        t.add(400.0);
      }
      expect(t.aRef, closeTo(500.0, 1e-9));
    });

    test('전위증강 구간에서는 A_ref가 따라 올라간다 — 피로가 아니다', () {
      // 세션 초반 진폭이 오히려 커지는 현상. 피로로 세면 안 된다.
      final t = LevelTracker();
      var v = 300.0;
      for (var i = 0; i < 20; i++) {
        t.add(v);
        expect(t.aRef, closeTo(v, 1e-9),
            reason: '상승 중에는 A_ref == 현재값이어야 피로가 0으로 나온다');
        v += 10;
      }
    });
  });

  group('LevelTracker [H] — 레벨 시프트 감지', () {
    List<int> runSegments(List<double> series) {
      final t = LevelTracker();
      final out = <int>[];
      for (final v in series) {
        t.add(v);
        out.add(t.segmentIndex);
      }
      return out;
    }

    test('단일 레벨이면 구간은 하나다', () {
      final segs = runSegments(List<double>.filled(120, 500.0));
      expect(segs.last, 0);
    });

    test('가벼운 잡음만으로는 구간이 갈리지 않는다', () {
      final series = <double>[];
      for (var i = 0; i < 200; i++) {
        series.add(500.0 + (i % 7 - 3) * 8.0);
      }
      expect(runSegments(series).last, 0);
    });

    test('갑작스러운 계단 하강은 새 구간이다', () {
      final series = <double>[
        ...List.filled(60, 500.0),
        ...List.filled(60, 250.0), // −50%
      ];
      expect(runSegments(series).last, greaterThanOrEqualTo(1));
    });

    test('갑작스러운 계단 상승도 새 구간이다', () {
      final series = <double>[
        ...List.filled(60, 250.0),
        ...List.filled(60, 500.0),
      ];
      expect(runSegments(series).last, greaterThanOrEqualTo(1));
    });

    test('점진적 피로 하강은 새 구간이 아니다 — 핵심 회귀', () {
      // 300버스트에 걸쳐 −40%. 이걸 레벨 시프트로 처리하면
      // A_ref 가 계속 리셋되어 피로가 영원히 0으로 나온다.
      final series = <double>[];
      for (var i = 0; i < 300; i++) {
        series.add(500.0 * (1.0 - 0.40 * i / 299));
      }
      expect(runSegments(series).last, 0,
          reason: '완만한 피로를 접촉 변화로 오인하면 피로를 영영 못 잡는다');
    });

    test('계단이 여러 번이면 구간도 여러 개다', () {
      final series = <double>[
        ...List.filled(50, 500.0),
        ...List.filled(50, 250.0),
        ...List.filled(50, 480.0),
      ];
      expect(runSegments(series).last, greaterThanOrEqualTo(2));
    });

    test('새 구간에서 A_ref가 새 레벨로 리셋된다', () {
      final t = LevelTracker();
      for (var i = 0; i < 60; i++) {
        t.add(500.0);
      }
      for (var i = 0; i < 60; i++) {
        t.add(250.0);
      }
      expect(t.segmentIndex, greaterThanOrEqualTo(1));
      expect(t.aRef, lessThan(400.0),
          reason: '구간이 바뀌었는데 이전 레벨의 A_ref 를 물고 있으면 '
              '접촉 변화가 통째로 피로로 잡힌다');
    });

    test('시프트가 일어난 버스트를 보고한다', () {
      final t = LevelTracker();
      var shiftedAt = <int>[];
      for (var i = 0; i < 120; i++) {
        t.add(i < 60 ? 500.0 : 250.0);
        if (t.justShifted) shiftedAt.add(i);
      }
      expect(shiftedAt, isNotEmpty);
      expect(shiftedAt.first, greaterThan(60));
      expect(shiftedAt.first, lessThan(60 + 3 * kLevelShiftWindow));
    });
  });
}
