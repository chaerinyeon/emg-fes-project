import 'package:flutter_app/game/engine/rest_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('강판 발동', () {
    test('3σ에 닿으면 걸린다', () {
      final p = RestPolicy();
      expect(p.shouldTriggerRest(100, 2.9), isFalse);
      expect(p.shouldTriggerRest(101, 3.0), isTrue);
      expect(p.isResting, isTrue);
    });

    test('σ를 모르면 걸지 않는다', () {
      final p = RestPolicy();
      expect(p.shouldTriggerRest(100, null), isFalse,
          reason: 'baseline 전이나 신호 불량을 위험으로 단정하면 안 된다');
      expect(p.isResting, isFalse);
    });

    test('휴식 중에는 다시 걸리지 않는다', () {
      final p = RestPolicy();
      p.shouldTriggerRest(100, 3.5);
      expect(p.shouldTriggerRest(101, 4.0), isFalse);
    });
  });

  group('★ 히스테리시스 — 오버레이가 반복되지 않는다', () {
    test('3σ에 머물러도 재발동하지 않는다', () {
      final p = RestPolicy();
      p.shouldTriggerRest(100, 3.5);
      p.finishRest(2.5); // 재개하되 무장 보류
      expect(p.isArmed, isFalse);

      // z가 계속 3σ 위에 있어도 다시 걸리면 안 된다
      for (var t = 130.0; t < 300; t += 1.6) {
        expect(p.shouldTriggerRest(t, 3.8), isFalse,
            reason: 't=$t 에서 재발동하면 무한 반복이다');
      }
    });

    test('2σ 아래로 내려갔다 와야 다시 걸린다', () {
      final p = RestPolicy();
      p.shouldTriggerRest(100, 3.5);
      p.finishRest(2.5);
      expect(p.isArmed, isFalse);

      p.shouldTriggerRest(140, 1.5); // 회복 → 재무장
      expect(p.isArmed, isTrue);
      expect(p.shouldTriggerRest(200, 3.2), isTrue, reason: '다시 악화되면 걸린다');
    });
  });

  group('휴식 종료 분기', () {
    test('회복(z<2σ)이면 재개 + 재무장', () {
      final p = RestPolicy();
      p.shouldTriggerRest(100, 3.5);
      expect(p.finishRest(1.2), RestDecision.resume);
      expect(p.isArmed, isTrue);
    });

    test('어중간(2~3σ)이면 재개하되 무장 보류', () {
      final p = RestPolicy();
      p.shouldTriggerRest(100, 3.5);
      expect(p.finishRest(2.4), RestDecision.resumeDisarmed);
      expect(p.isArmed, isFalse);
    });

    test('회복 안 됨(z≥3σ)이면 세션 종료를 권한다', () {
      final p = RestPolicy();
      p.shouldTriggerRest(100, 3.5);
      expect(p.finishRest(3.6), RestDecision.endSession,
          reason: '쉬어도 회복 안 된 사람을 다시 돌려보내면 안 된다');
    });

    test('σ를 모르면 재개로 본다', () {
      final p = RestPolicy();
      p.shouldTriggerRest(100, 3.5);
      expect(p.finishRest(null), RestDecision.resume);
    });
  });

  group('쿨다운', () {
    test('남은 시간이 줄어들고 0에서 멈춘다', () {
      final p = RestPolicy(cooldownSec: 20);
      p.shouldTriggerRest(100, 3.5);
      expect(p.remainingSec(100), closeTo(20, 1e-9));
      expect(p.remainingSec(110), closeTo(10, 1e-9));
      expect(p.remainingSec(125), 0, reason: '음수가 되면 안 된다');
    });

    test('쿨다운 경과 판정', () {
      final p = RestPolicy(cooldownSec: 20);
      p.shouldTriggerRest(100, 3.5);
      expect(p.isCooldownOver(119), isFalse);
      expect(p.isCooldownOver(120), isTrue);
    });

    test('휴식 중이 아니면 남은 시간이 null', () {
      expect(RestPolicy().remainingSec(0), isNull);
    });
  });

  test('reset이 무장 상태를 되돌린다', () {
    final p = RestPolicy();
    p.shouldTriggerRest(100, 3.5);
    p.reset();
    expect(p.isArmed, isTrue);
    expect(p.isResting, isFalse);
  });
}
