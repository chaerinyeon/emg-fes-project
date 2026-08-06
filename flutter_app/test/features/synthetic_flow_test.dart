import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_app/ble/device_connection.dart';
import 'package:flutter_app/ble/stim_controller.dart';
import 'package:flutter_app/data/local/session_store.dart';
import 'package:flutter_app/features/dev/synthetic_link.dart';
import 'package:flutter_app/features/session/session_orchestrator.dart';
import 'package:flutter_app/session/session_controller.dart';
import 'package:flutter_app/signal/constants.dart';
import 'package:flutter_app/signal/dc_calibrator.dart';
import 'package:flutter_app/signal/signal_pipeline.dart';

/// 합성 링크가 낸 표본을 실기기와 **같은 경로**로 흘린다.
Future<SignalPipeline> feed(SyntheticFesLink link, {required int untilMs}) async {
  final pipeline = SignalPipeline();
  final sub = rawSamples(link.rawPackets).listen((s) {
    pipeline.addSample(s.$1, s.$2);
  });
  await link.connect();
  // 시계를 손으로 민다 — 테스트가 실시간을 기다리지 않게.
  for (var t = 0; t < untilMs; t += 100) {
    link.emitNextPacket();
  }
  await pumpEventQueue();
  await sub.cancel();
  return pipeline;
}

void main() {
  group('블루투스 없이도 부착 체크를 통과할 수 있어야 한다', () {
    test('무자극 도입부에 잡음이 있어 EMG 전극 판정이 선다', () async {
      final link = SyntheticFesLink(autoTick: false);
      addTearDown(link.dispose);

      final pipeline = await feed(link, untilMs: 2000);

      expect(pipeline.dcOffset, isNotNull, reason: 'DC 캘리브가 끝나야 한다');
      expect(pipeline.noiseSigma, greaterThan(0),
          reason: '완전히 평평한 신호는 전극이 붙은 팔에서 나오지 않는다 — '
              '잡음이 0이면 부착 체크가 영원히 실패한다');
      expect(pipeline.dcWindowLooksQuiet, isTrue,
          reason: '도입부는 자극 없는 구간이어야 한다');
    });

    test('잡음이 부착 임계보다 한참 낮다 — 정상 부착으로 읽혀야 한다', () async {
      final link = SyntheticFesLink(autoTick: false);
      addTearDown(link.dispose);

      final pipeline = await feed(link, untilMs: 2000);
      expect(pipeline.noiseSigma, lessThan(30));
    });

    test('자극 패드 판정이 서려면 버스트가 잡혀야 한다', () async {
      final link = SyntheticFesLink(autoTick: false);
      addTearDown(link.dispose);

      final pipeline = await feed(link, untilMs: 12000);
      expect(pipeline.reliability.burstCount, greaterThan(0));
    });
  });

  group('합성 신호가 실기기 신호처럼 읽힌다', () {
    test('버스트당 이벤트 수가 신뢰 게이트를 넘는다', () async {
      final link = SyntheticFesLink(autoTick: false);
      addTearDown(link.dispose);

      final pipeline = await feed(link, untilMs: 20000);
      final gate = pipeline.reliability;
      expect(gate.eventsPerBurst, greaterThanOrEqualTo(10.0));
      expect(gate.eventsPerBurst, lessThanOrEqualTo(20.0),
          reason: '자극 591ms / 주기 31ms = 물리적으로 20발이 상한이다');
    });
  });

  group('부착 확인 → 강도 확인 → 게임 시작', () {
    test('블루투스 없이 전 구간이 지나간다', () async {
      final link = SyntheticFesLink(autoTick: false);
      addTearDown(link.dispose);

      final o = SessionOrchestrator(
        link: link,
        store: InMemorySessionStore(),
        sessionId: 's-sim',
        patientId: 'p-sim',
        deviceId: 'synthetic',
      );
      addTearDown(() async {
        await o.stim.stop(reason: StimStopReason.sessionEnd);
        o.dispose();
      });

      void pump(int ms) {
        for (var t = 0; t < ms; t += 100) {
          link.emitNextPacket();
        }
      }

      await link.connect();
      await o.begin();
      expect(o.state, SessionState.attachmentCheck);

      // ── 붙인 자리 확인 ──
      pump(9000);
      await pumpEventQueue();

      final check = o.runAttachmentCheck();
      expect(check.emgElectrodeOk, isTrue, reason: 'EMG 전극 판정이 서야 한다');
      expect(check.stimPadOk, isTrue, reason: '자극 패드 판정이 서야 한다');
      expect(check.deviceOk, isTrue);
      expect(check.passed, isTrue);

      o.submitAttachmentCheck(check);
      expect(o.state, SessionState.intensityWizard,
          reason: '부착 체크를 통과하면 세기 맞추기로 넘어간다');

      // ── 세기 맞추기 ──
      final measuring =
          o.measureIntensity(3, window: const Duration(milliseconds: 20));
      pump(6000); // 자극 창 동안 표본이 들어온다
      await pumpEventQueue();
      final epb = await measuring;

      expect(epb, greaterThanOrEqualTo(kMinEventsPerBurst.toDouble()),
          reason: '신호가 잡혀야 "적당함"을 누를 수 있다');

      o.submitIntensity(level: 3, eventsPerBurst: epb);
      expect(o.state, SessionState.syncing);

      // ── 동기화 → 게임 ──
      pump(kSyncWindowS * 1000 + 6000);
      await pumpEventQueue();

      expect(o.state, SessionState.playing,
          reason: '이것저것 확인이 끝나면 게임으로 들어가야 한다');

      // 세션 중에는 하향만 가능하다. 아무도 안 눌렀는데 단계가 내려가면
      // "자극 조금 줄이기"가 화면에서 사라지고 되돌릴 방법도 없다.
      expect(o.intensityLevel, 3,
          reason: '마법사에서 정한 단계가 게임까지 그대로 와야 한다');

      pump(60000);
      await pumpEventQueue();
      expect(o.intensityLevel, 3, reason: '시간이 지나도 저절로 내려가지 않는다');
    });
  });

  group('"아직 안 왔다"를 "다시 붙이세요"로 말하지 않는다', () {
    test('신호가 도착할 때까지 기다렸다가 판정한다', () async {
      final link = SyntheticFesLink(autoTick: false);
      addTearDown(link.dispose);

      final o = SessionOrchestrator(
        link: link,
        store: InMemorySessionStore(),
        sessionId: 's',
        patientId: 'p',
        deviceId: 'synthetic',
      );
      addTearDown(o.dispose);

      await link.connect();
      await o.begin();

      // 누르는 순간에는 아직 아무 데이터도 없다. 여기서 곧바로 판정하면
      // 멀쩡히 붙인 사람에게 "다시 붙이세요"가 뜬다.
      expect(o.runAttachmentCheck().passed, isFalse);

      final pending = o.awaitAttachmentCheck(
        timeout: const Duration(seconds: 5),
        poll: const Duration(milliseconds: 1),
      );
      // 기다리는 동안 신호가 도착한다.
      for (var t = 0; t < 9000; t += 100) {
        link.emitNextPacket();
      }

      expect((await pending).passed, isTrue);
    });

    test('끝내 신호가 없으면 실패로 돌려준다 — 영원히 기다리지 않는다', () async {
      final link = SyntheticFesLink(autoTick: false);
      addTearDown(link.dispose);

      final o = SessionOrchestrator(
        link: link,
        store: InMemorySessionStore(),
        sessionId: 's',
        patientId: 'p',
        deviceId: 'synthetic',
      );
      addTearDown(o.dispose);

      await link.connect();
      await o.begin();

      final r = await o.awaitAttachmentCheck(
        timeout: const Duration(milliseconds: 40),
        poll: const Duration(milliseconds: 5),
      );
      expect(r.passed, isFalse);
    });
  });

  group('자극이 세션 중간에 조용히 꺼지지 않는다', () {
    test('표본이 계속 들어오면 동기화 구간에서도 워치독이 굶지 않는다', () async {
      // 데이터 워치독은 "표본이 끊겼는가"를 본다. 그런데 되감기가
      // playing 에서만 일어나면, 동기화 구간(30초)을 버티지 못하고
      // 한가운데서 자극이 꺼진다 — 그리고 아무도 다시 켜지 않는다.
      // 실기기에서는 환자가 자극 없이 세션 전체를 보내게 된다.
      final link = SyntheticFesLink(autoTick: false);
      addTearDown(link.dispose);

      final o = SessionOrchestrator(
        link: link,
        store: InMemorySessionStore(),
        sessionId: 's',
        patientId: 'p',
        deviceId: 'synthetic',
        stimDataTimeout: const Duration(milliseconds: 120),
      );
      addTearDown(() async {
        await o.stim.stop(reason: StimStopReason.sessionEnd);
        o.dispose();
      });

      await link.connect();
      await o.begin();

      await o.stim.start();
      expect(o.stim.isStimulating, isTrue);

      // 표본이 꾸준히 들어오는 상황을 워치독 시한보다 길게 이어 간다.
      for (var round = 0; round < 6; round++) {
        for (var t = 0; t < 500; t += 100) {
          link.emitNextPacket();
        }
        await pumpEventQueue();
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }

      expect(o.stim.isStimulating, isTrue,
          reason: '표본이 들어오는 동안 자극이 꺼지면 안 된다');
    });

    test('표본이 끊기면 자극이 멈춘다 — 워치독은 살아 있어야 한다', () async {
      final link = SyntheticFesLink(autoTick: false);
      addTearDown(link.dispose);

      final o = SessionOrchestrator(
        link: link,
        store: InMemorySessionStore(),
        sessionId: 's',
        patientId: 'p',
        deviceId: 'synthetic',
        stimDataTimeout: const Duration(milliseconds: 80),
      );
      addTearDown(o.dispose);

      await link.connect();
      await o.begin();
      await o.stim.start();

      for (var t = 0; t < 500; t += 100) {
        link.emitNextPacket();
      }
      await pumpEventQueue();

      // 여기서부터 표본이 오지 않는다.
      await Future<void>.delayed(const Duration(milliseconds: 250));

      expect(o.stim.isStimulating, isFalse);
      expect(o.stim.lastStopReason, StimStopReason.signalLost);
    });
  });

  group('DC 캘리브가 잡음을 실제로 잰다', () {
    test('평평한 신호에서는 잡음이 0이다 — 이 경우 부착 판정이 설 수 없다', () {
      final dc = DcCalibrator();
      for (var i = 0; i < 1500; i++) {
        dc.add(1862);
      }
      expect(dc.noiseSigma, 0);
    });
  });
}
