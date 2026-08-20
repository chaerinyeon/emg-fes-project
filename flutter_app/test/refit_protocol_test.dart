// RE:FIT 프로토콜 v0.2 코덱 테스트.
//
// 여기 박힌 바이트열은 손으로 지어낸 게 아니라, 펌웨어 sendEpoch()/sendStatus()/
// sendEvent() 의 패킹 코드를 그대로 재현해 만든 뒤 scripts/refit_ble_bench.py 의
// 파이썬 디코더로 교차 확인한 값이다. 즉 이 테스트는 Dart 구현이 펌웨어·파이썬
// 벤치와 같은 계약을 말하는지 본다 — 세 구현이 어긋나면 여기서 깨진다.
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/core/refit_protocol.dart';

void main() {
  group('CRC8 (poly 0x07)', () {
    test('펌웨어 crc8() 과 동일한 값', () {
      // SESSION_CONTROL(start) 의 본문 7바이트 → 0x84
      expect(refitCrc8([0x02, 0x14, 0x00, 0x00, 0x00, 0x00, 0x01]), 0x84);
    });
  });

  group('EPOCH 디코드', () {
    // stim#7 @5217ms s#217 spike=900 p2p=350 valid n=14
    final bytes = <int>[
      0x02, 0x01, 0x2a, 0x00, 0x03, 0x00, // 헤더: ver·type·seq42·sess3
      0x07, 0x00, 0x00, 0x00, // stim_index = 7
      0x61, 0x14, 0x00, 0x00, // t_ms = 5217
      0xd9, 0x00, 0x00, 0x00, // sample_index = 217
      0x84, 0x03, // spike = 900
      0x5e, 0x01, // p2p = 350
      0x01, 0x0e, // flags=valid, n=14
      0x64, 0x00, 0x38, 0xff, 0x2c, 0x01, 0x6a, 0xff, 0x50, 0x00, 0xc4, 0xff,
      0x28, 0x00, 0xe2, 0xff, 0x14, 0x00, 0xf6, 0xff, 0x05, 0x00, 0xfb, 0xff,
      0x03, 0x00, 0xfd, 0xff,
      0x2c, // crc8
    ];

    test('길이는 24 + 2n + 1', () {
      expect(bytes.length, 24 + 2 * 14 + 1);
      expect(bytes.length, 53);
    });

    test('모든 필드가 복원된다', () {
      final m = decodeRefit(bytes);
      expect(m, isA<EpochMsg>());
      final ep = m as EpochMsg;
      expect(ep.seq, 42);
      expect(ep.sessionId, 3);
      expect(ep.stimIndex, 7);
      expect(ep.tMs, 5217);
      expect(ep.sampleIndex, 217);
      expect(ep.spike, 900);
      expect(ep.p2p, 350);
      expect(ep.valid, isTrue);
      expect(ep.samples.length, 14);
      // 음수 표본이 부호 있는 int16 으로 읽혀야 한다 — 여기서 틀리면 면적이 폭주한다
      expect(ep.samples.take(4).toList(), [100, -200, 300, -150]);
    });

    test('면적과 R', () {
      final ep = decodeRefit(bytes) as EpochMsg;
      expect(ep.area, 1006); // Σ|표본|
      expect(ep.r, closeTo(1006 / 900, 1e-9));
    });

    test('CRC 가 틀리면 폐기', () {
      final bad = List<int>.from(bytes)..last = 0x00;
      expect(decodeRefit(bad), isNull);
    });

    test('버전이 다르면 폐기 — v0.1 펌웨어와 조용히 섞이지 않는다', () {
      final old = List<int>.from(bytes);
      old[0] = 0x01;
      expect(decodeRefit(old), isNull);
    });

    test('표본이 잘린 패킷은 폐기', () {
      expect(decodeRefit(bytes.sublist(0, 30)), isNull);
    });

    test('포화 플래그가 안 서면 추세에 쓸 수 있다', () {
      final ep = decodeRefit(bytes) as EpochMsg;
      expect(ep.windowSaturated, isFalse);
      expect(ep.spikeSaturated, isFalse);
      expect(ep.saturated, isFalse);
      expect(ep.usableForTrend, isTrue);
    });

    test('bit1 = 창 포화 → 면적을 못 믿으므로 추세에서 뺀다', () {
      final b = List<int>.from(bytes);
      b[22] = 0x01 | 0x02;
      b[b.length - 1] = refitCrc8(b, b.length - 1);
      final ep = decodeRefit(b) as EpochMsg;
      expect(ep.valid, isTrue); // valid 는 여전히 참 —
      expect(ep.windowSaturated, isTrue);
      expect(ep.spikeSaturated, isFalse);
      expect(ep.usableForTrend, isFalse); // — 그래도 추세엔 못 쓴다
    });

    test('bit2 = 스파이크 포화 → R 분모가 상수라 추세에서 뺀다', () {
      final b = List<int>.from(bytes);
      b[22] = 0x01 | 0x04;
      b[b.length - 1] = refitCrc8(b, b.length - 1);
      final ep = decodeRefit(b) as EpochMsg;
      expect(ep.spikeSaturated, isTrue);
      expect(ep.windowSaturated, isFalse);
      expect(ep.usableForTrend, isFalse);
    });

    test('spike 가 0이면 R 은 0 (0으로 나누지 않는다)', () {
      final z = List<int>.from(bytes);
      z[18] = 0;
      z[19] = 0;
      z[z.length - 1] = refitCrc8(z, z.length - 1);
      expect((decodeRefit(z) as EpochMsg).r, 0);
    });
  });

  group('STATUS 디코드', () {
    final bytes = <int>[
      0x02, 0x02, 0x02, 0x00, 0x03, 0x00,
      0x88, 0x13, 0x00, 0x00, // t_ms = 5000
      0x02, // state = RUNNING
      0x04, // level = 4
      0x01, // stim_on
      0x00, // health
      0x09, 0x00, // ack = 9
      0xe8, 0x03, // fs = 1000
      0x02, 0x0f, // win +2 ~ +15ms
      0x0a, // max_level = 10
      0x60, // crc8
    ];

    test('22바이트, 필드 복원', () {
      expect(bytes.length, 22);
      final s = decodeRefit(bytes) as StatusMsg;
      expect(s.tMs, 5000);
      expect(s.stateName, 'RUNNING');
      expect(s.level, 4);
      expect(s.stimOn, isTrue);
      expect(s.lastCmdSeqAck, 9);
      expect(s.sampleRate, 1000);
      expect(s.winStartMs, 2);
      expect(s.winEndMs, 15);
      expect(s.maxLevel, 10);
      expect(s.healthFlags, isEmpty);
    });

    test('health 비트가 이름으로 풀린다', () {
      final b = List<int>.from(bytes);
      b[13] = 0x03; // watchdog + hardlimit
      b[21] = refitCrc8(b, 21);
      expect((decodeRefit(b) as StatusMsg).healthFlags, [
        'WATCHDOG',
        'HARDLIMIT',
      ]);
    });
  });

  group('EVENT 디코드', () {
    test('SESSION_START — 이 t_ms 가 세션 t0', () {
      final e =
          decodeRefit([
                0x02, 0x03, 0x01, 0x00, 0x03, 0x00, //
                0x88, 0x13, 0x00, 0x00, 0x01, 0x00, 0xe4,
              ])
              as EventMsg;
      expect(e.tMs, 5000);
      expect(e.eventId, kEvSessionStart);
      expect(e.name, 'SESSION_START');
    });
  });

  group('다운링크 인코드 — 펌웨어 길이 게이트를 통과해야 한다', () {
    test('SESSION_CONTROL 은 8바이트 (펌웨어 최소 8)', () {
      final p = buildSessionControl(kScRequestStart);
      expect(p.length, 8);
      expect(p, [0x02, 0x14, 0x00, 0x00, 0x00, 0x00, 0x01, 0x84]);
    });

    test('JUDGMENT 는 19바이트 (펌웨어 최소 19 — v0.1 은 21을 요구해 전량 폐기됐다)', () {
      final p = buildJudgment(action: kActDecrease, targetLevel: 2);
      expect(p.length, 19);
      expect(p, [
        0x02, 0x11, 0x00, 0x00, 0x00, 0x00, //
        0x00, 0x00, 0x00, 0x00, // t_ref_ms
        0x00, 0x00, 0x00, 0x00, // stim_index_ref
        0x00, // stage
        0x01, // action = DECREASE
        0x02, // target_level
        0x00, // reliability = HIGH
        0xfb, // crc8
      ]);
    });

    test('HEARTBEAT 는 11바이트 (펌웨어 최소 7)', () {
      expect(buildHeartbeat(phoneMs: 0).length, 11);
    });

    test('만든 패킷의 CRC 는 자기 자신과 맞는다', () {
      for (final p in [
        buildSessionControl(kScStimEnable, seq: 5, sessionId: 3),
        buildJudgment(action: kActIncrease, targetLevel: 7, seq: 6),
        buildHeartbeat(seq: 7, sessionId: 3, phoneMs: 123456),
      ]) {
        expect(refitCrc8(p, p.length - 1), p.last);
      }
    });
  });
}
