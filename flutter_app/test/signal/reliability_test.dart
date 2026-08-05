import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/signal/constants.dart';
import 'package:flutter_app/signal/reliability.dart';

void main() {
  group('ReliabilityGate — 정상 판정', () {
    test('events/burst와 검출률이 모두 기준 이상이면 정상이다', () {
      final g = ReliabilityGate();
      for (var i = 0; i < 20; i++) {
        g.addBurst(eventsInBurst: 18, tSeconds: i * 1.618);
      }
      expect(g.status, ReliabilityStatus.ok);
      expect(g.fatigueTrusted, isTrue);
    });

    test('events/burst가 기준 미만이면 피로도 판정을 보류한다', () {
      final g = ReliabilityGate();
      for (var i = 0; i < 20; i++) {
        g.addBurst(eventsInBurst: kMinEventsPerBurst - 1, tSeconds: i * 1.618);
      }
      expect(g.status, ReliabilityStatus.degraded);
      expect(g.fatigueTrusted, isFalse,
          reason: '게이팅을 빼면 3분의 1은 틀린 값을 보여주게 된다');
    });

    test('검출률이 50% 미만이면 보류한다', () {
      final g = ReliabilityGate();
      // 기대 20발 중 9발 → 45%
      for (var i = 0; i < 20; i++) {
        g.addBurst(eventsInBurst: 9, tSeconds: i * 1.618);
      }
      expect(g.detectRate, lessThan(kMinDetectRate));
      expect(g.status, ReliabilityStatus.degraded);
    });

    test('검출률은 기대 펄스 수 대비 실제 검출 수다', () {
      final g = ReliabilityGate();
      for (var i = 0; i < 10; i++) {
        g.addBurst(eventsInBurst: 10, tSeconds: i * 1.618);
      }
      expect(g.detectRate,
          closeTo(10.0 / kExpectedPulsesPerBurst, 1e-9));
    });
  });

  group('ReliabilityGate — 신호 소실', () {
    test('검출 실패가 30초 지속되면 signal_lost다', () {
      final g = ReliabilityGate();
      g.addBurst(eventsInBurst: 18, tSeconds: 1.0);
      g.tick(1.0 + kSignalLostTimeoutS + 0.1);
      expect(g.status, ReliabilityStatus.lost);
    });

    test('30초 이내면 아직 소실이 아니다', () {
      final g = ReliabilityGate();
      g.addBurst(eventsInBurst: 18, tSeconds: 1.0);
      g.tick(1.0 + kSignalLostTimeoutS - 1.0);
      expect(g.status, isNot(ReliabilityStatus.lost));
    });

    test('버스트가 다시 들어오면 소실 타이머가 리셋된다', () {
      final g = ReliabilityGate();
      g.addBurst(eventsInBurst: 18, tSeconds: 1.0);
      g.tick(1.0 + kSignalLostTimeoutS - 1.0);
      g.addBurst(eventsInBurst: 18, tSeconds: 1.0 + kSignalLostTimeoutS - 0.5);
      g.tick(1.0 + kSignalLostTimeoutS + 0.5);
      expect(g.status, isNot(ReliabilityStatus.lost));
    });

    test('세션 시작 직후에는 소실로 보지 않는다', () {
      final g = ReliabilityGate();
      g.tick(1.0);
      expect(g.status, isNot(ReliabilityStatus.lost));
    });
  });

  group('ReliabilityGate — 등급', () {
    test('깨끗한 세션은 A다', () {
      final g = ReliabilityGate();
      for (var i = 0; i < 50; i++) {
        g.addBurst(eventsInBurst: 19, tSeconds: i * 1.618);
      }
      expect(g.grade, 'A');
    });

    test('기준은 넘지만 여유가 없으면 B다', () {
      final g = ReliabilityGate();
      for (var i = 0; i < 50; i++) {
        g.addBurst(eventsInBurst: 11, tSeconds: i * 1.618);
      }
      expect(g.grade, 'B');
    });

    test('기준 미달은 C다', () {
      final g = ReliabilityGate();
      for (var i = 0; i < 50; i++) {
        g.addBurst(eventsInBurst: 4, tSeconds: i * 1.618);
      }
      expect(g.grade, 'C');
    });
  });
}
