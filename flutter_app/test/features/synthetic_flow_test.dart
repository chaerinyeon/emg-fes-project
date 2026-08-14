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
  // 파이프라인은 **링크와 같은 fs** 로 만든다. 기본값에 맡기면 링크가 4kHz 인데
  // 파이프라인은 1kHz 가 되어, 실기기에서 났던 것과 똑같이 시간축이 어긋난다.
  final pipeline = SignalPipeline(fs: link.clock.fs);
  final sub = rawSamples(link.rawPackets).listen((s) {
    pipeline.addSample(s.$1, s.$2);
  });
  await link.connect();
  // 시계를 손으로 민다 — 테스트가 실시간을 기다리지 않게.
  link.emitFor(untilMs);
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
        link.emitFor(ms);
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
      expect(o.state, SessionState.readyToMeasure,
          reason: '강도를 확정해도 "측정 시작"을 눌러야 진행된다');

      // ── 측정 시작 ── 여기서부터가 세션의 t=0 이다.
      o.startMeasurement();
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
      expect(o.runSignalAttachmentCheck().passed, isFalse);

      final pending = o.awaitAttachmentCheck(
        timeout: const Duration(seconds: 5),
        poll: const Duration(milliseconds: 1),
      );
      // 기다리는 동안 신호가 도착한다.
      link.emitFor(9000);

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
      // 지금은 링크만 보므로(kTrustLinkForAttachment) 신호가 없어도 통과한다.
      // 이 테스트가 지키는 것은 "영원히 기다리지 않는다" 쪽이다.
      expect(r, isNotNull);
      // 신호 기반 판정은 여전히 "표본이 없으면 실패"여야 한다.
      expect(o.runSignalAttachmentCheck().passed, isFalse);
    });
  });

  group('측정 시작이 세션의 t=0 이다', () {
    Future<SessionOrchestrator> upToReady(SyntheticFesLink link) async {
      final o = SessionOrchestrator(
        link: link,
        store: InMemorySessionStore(),
        sessionId: 's',
        patientId: 'p',
        deviceId: 'synthetic',
      );
      await link.connect();
      await o.begin();
      link.emitFor(9000);
      await pumpEventQueue();
      o.submitAttachmentCheck(o.runAttachmentCheck());
      // 측정 창이 열려 있는 **동안** 표본을 밀어야 한다. 먼저 await 하면
      // 아무 표본도 없이 창이 닫혀 events/burst 가 0 으로 나오고, 강도가
      // 확정되지 않아 readyToMeasure 까지 못 간다.
      final measuring =
          o.measureIntensity(3, window: const Duration(milliseconds: 20));
      link.emitFor(6000);
      await pumpEventQueue();
      o.submitIntensity(level: 3, eventsPerBurst: await measuring);
      return o;
    }

    test('준비 구간에서 잡힌 기준값을 세션으로 물려주지 않는다', () async {
      final link = SyntheticFesLink(autoTick: false);
      addTearDown(link.dispose);
      final o = await upToReady(link);
      addTearDown(() async {
        await o.stim.stop(reason: StimStopReason.sessionEnd);
        o.dispose();
      });

      // 준비 구간을 지나오며 영점은 이미 잡혀 있다.
      expect(o.pipeline.dcOffset, isNotNull);

      o.startMeasurement();

      // 여기서부터 다시 잰다 — 자세를 잡는 동안의 움직임이 기준값에
      // 섞여 있으면 그 위의 피로도 전부가 그만큼 틀어진다.
      expect(o.pipeline.dcOffset, isNull,
          reason: '측정 시작에서 기준값이 새로 잡혀야 한다');
      expect(o.elapsedS, 0);
      expect(o.lastBurst, isNull);
    });

    test('첫 버스트가 t=0 근처에서 시작한다', () async {
      final link = SyntheticFesLink(autoTick: false);
      addTearDown(link.dispose);
      final o = await upToReady(link);
      addTearDown(() async {
        await o.stim.stop(reason: StimStopReason.sessionEnd);
        o.dispose();
      });

      o.startMeasurement();
      link.emitFor(12000);
      await pumpEventQueue();

      // 원점을 안 옮기면 준비 구간 15초가 그대로 더해져 첫 버스트가
      // t=15초 이후로 들어온다. 그러면 워밍업 30초가 이미 지난 것으로
      // 읽혀 A_ref 없이 곧바로 playing 이 된다.
      expect(o.lastBurst, isNotNull);
      expect(o.lastBurst!.tSeconds, lessThan(12.0),
          reason: '시간축이 측정 시작으로 옮겨져야 한다');
    });
  });

  // 사용자 지시(2026-08-11)로 부착 확인을 BLE 연결만으로 통과시키고 있다.
  // 그 선택을 눈에 보이게 고정해 둔다 — 나중에 되돌릴 때 여기가 신호가 된다.
  group('부착 확인을 링크만으로 통과시킨다 (임시)', () {
    test('연결돼 있으면 신호가 없어도 3항목이 모두 선다', () async {
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

      // 표본을 한 개도 안 흘렸다.
      final r = o.runAttachmentCheck();
      expect(r.emgElectrodeOk, isTrue);
      expect(r.stimPadOk, isTrue);
      expect(r.passed, isTrue);

      // 진짜 판정은 같은 상황에서 실패한다 — 지식이 지워진 게 아니다.
      expect(o.runSignalAttachmentCheck().passed, isFalse);
    });

    test('연결이 끊겨 있으면 통과하지 않는다', () async {
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

      // connect() 를 부르지 않았다.
      final r = o.runAttachmentCheck();
      expect(r.passed, isFalse, reason: '링크가 유일한 근거인데 그것도 없다');
    });

    test('확인 중에 자극을 쏘지 않는다', () async {
      final link = SyntheticFesLink(autoTick: false);
      addTearDown(link.dispose);

      final o = SessionOrchestrator(
        link: link,
        store: InMemorySessionStore(),
        sessionId: 's',
        patientId: 'p',
        deviceId: 'synthetic',
      );
      addTearDown(() async {
        await o.stim.stop(reason: StimStopReason.sessionEnd);
        o.dispose();
      });

      await link.connect();
      await o.begin();

      await o.runAttachmentCheckWithTestPulse();
      // 이 자극의 존재 이유는 stimPadOk 하나뿐이었다. 그 판정이 링크로
      // 대체된 이상, 자극을 쏘면 아무것도 판정하지 않으면서 전류만 나간다.
      expect(o.stim.isStimulating, isFalse);
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
        link.emitFor(500);
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

      link.emitFor(500);
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
