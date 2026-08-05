import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/ble/stim_controller.dart';
import 'package:flutter_app/signal/constants.dart';

void main() {
  group('자극 상한은 펌웨어 값에서 유도된다', () {
    test('로컬 상한은 언제나 펌웨어 타임아웃보다 짧다', () {
      // 로컬 자동 종료가 언제나 1차 안전장치여야 한다(하드 제약 8).
      // 펌웨어가 먼저 끊으면 앱은 자극이 왜 멎었는지 모른 채 게임을 돌린다.
      expect(kLocalMaxStimSeconds, lessThan(kFirmwareStimTimeoutSeconds));
    });

    test('현재 펌웨어(180초)에서는 170초로 잡힌다', () {
      expect(kFirmwareStimTimeoutSeconds, 180,
          reason: '펌웨어 STIM_TIMEOUT_MS = 180000');
      expect(
        effectiveStimCapSeconds(
          firmwareTimeoutS: 180,
          sessionMaxS: kSessionMaxMin * 60,
        ),
        170,
      );
    });

    test('펌웨어를 올리면 스펙 세션 상한까지 자동으로 늘어난다', () {
      // 펌웨어 STIM_TIMEOUT_MS 를 16분으로 올리면 15분 세션이 가능해진다.
      expect(
        effectiveStimCapSeconds(
          firmwareTimeoutS: 960,
          sessionMaxS: kSessionMaxMin * 60,
        ),
        kSessionMaxMin * 60,
      );
    });

    test('어떤 펌웨어 값에서도 여유를 남긴다', () {
      for (final fw in [60, 120, 180, 300, 900, 960, 1800]) {
        final cap = effectiveStimCapSeconds(
          firmwareTimeoutS: fw,
          sessionMaxS: kSessionMaxMin * 60,
        );
        expect(cap, lessThan(fw), reason: 'fw=$fw 에서 여유가 없다');
        expect(cap, greaterThan(0));
      }
    });

    test('세션 상한을 넘겨 자극하지 않는다', () {
      expect(
        effectiveStimCapSeconds(
          firmwareTimeoutS: 100000,
          sessionMaxS: kSessionMaxMin * 60,
        ),
        kSessionMaxMin * 60,
      );
    });
  });

  group('세션 상한은 자극 상한을 넘지 않는다', () {
    test('세션이 자극보다 오래 살아 있으면 안 된다', () {
      // 넘으면 자극이 조용히 꺼진 채 게임만 계속 돈다.
      // 화면의 손은 쥐어지는데 실제 수축은 없는 상태 — 훈련 효과가
      // 사라지고 아무도 모른다.
      expect(kEffectiveSessionMaxSeconds,
          lessThanOrEqualTo(kLocalMaxStimSeconds));
    });

    test('현 펌웨어에서 실질 세션 상한은 2.8분이다', () {
      expect(kEffectiveSessionMaxSeconds, 170);
      expect(kEffectiveSessionMaxSeconds, lessThan(kSessionMaxMin * 60),
          reason: '펌웨어를 올리기 전까지는 스펙의 15분을 쓸 수 없다');
    });
  });
}
