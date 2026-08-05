import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/ble/device_connection.dart';
import 'package:flutter_app/ble/stim_controller.dart';
import 'package:flutter_app/session/end_conditions.dart';
import 'package:flutter_app/session/session_controller.dart';
import 'package:flutter_app/signal/constants.dart';

class FakeLink implements DeviceLink {
  final _state = StreamController<LinkState>.broadcast();
  final _packets = StreamController<List<int>>.broadcast();
  LinkState _current = LinkState.connected;
  final sent = <Map<String, dynamic>>[];

  @override
  LinkState get state => _current;
  @override
  Stream<LinkState> get stateStream => _state.stream;
  @override
  Stream<List<int>> get rawPackets => _packets.stream;
  @override
  Future<void> send(Map<String, dynamic> cmd) async => sent.add(cmd);
  @override
  Future<void> connect() async => drop(LinkState.connected);
  @override
  Future<void> disconnect() async => drop(LinkState.disconnected);

  void drop(LinkState s) {
    _current = s;
    _state.add(s);
  }

  Future<void> dispose() async {
    await _state.close();
    await _packets.close();
  }
}

const _goodCheck = AttachmentCheck(
  emgElectrodeOk: true,
  stimPadOk: true,
  deviceOk: true,
);

/// playing 까지 정상 경로로 데려간다.
Future<SessionMachine> reachPlaying(FakeLink link) async {
  final m = SessionMachine(StimController(link));
  await m.begin();
  m.onLinkConnected();
  m.submitAttachmentCheck(_goodCheck);
  m.submitIntensity(level: 3, eventsPerBurst: 18);
  m.onSyncProgress(kSyncWindowS + 1.0);
  return m;
}

void main() {
  late FakeLink link;
  setUp(() => link = FakeLink());
  tearDown(() async => link.dispose());

  group('상태 전이', () {
    test('idle에서 시작한다', () {
      final m = SessionMachine(StimController(link));
      expect(m.state, SessionState.idle);
    });

    test('정상 경로: connecting → attachmentCheck → intensityWizard → syncing → playing',
        () async {
      final m = SessionMachine(StimController(link));
      final seen = <SessionState>[];
      final sub = m.states.listen(seen.add);

      await m.begin();
      expect(m.state, SessionState.connecting);

      m.onLinkConnected();
      expect(m.state, SessionState.attachmentCheck);

      m.submitAttachmentCheck(_goodCheck);
      expect(m.state, SessionState.intensityWizard);

      m.submitIntensity(level: 3, eventsPerBurst: 18);
      expect(m.state, SessionState.syncing);

      m.onSyncProgress(kSyncWindowS + 1.0);
      expect(m.state, SessionState.playing);

      await Future<void>.delayed(Duration.zero);
      expect(seen, [
        SessionState.connecting,
        SessionState.attachmentCheck,
        SessionState.intensityWizard,
        SessionState.syncing,
        SessionState.playing,
      ]);
      await sub.cancel();
      await m.dispose();
    });
  });

  group('게이트 — 통과하지 않으면 게임에 못 들어간다', () {
    test('부착 체크가 실패하면 다음 단계로 못 간다', () async {
      final m = SessionMachine(StimController(link));
      await m.begin();
      m.onLinkConnected();

      m.submitAttachmentCheck(const AttachmentCheck(
        emgElectrodeOk: false,
        stimPadOk: true,
        deviceOk: true,
      ));
      expect(m.state, SessionState.attachmentCheck,
          reason: '재부착 안내를 띄우고 그 자리에 머문다');
      expect(m.lastAttachmentCheck!.passed, isFalse);
      await m.dispose();
    });

    test('부착 체크를 건너뛰고 강도로 갈 수 없다', () async {
      final m = SessionMachine(StimController(link));
      await m.begin();
      m.onLinkConnected();

      m.submitIntensity(level: 3, eventsPerBurst: 18);
      expect(m.state, SessionState.attachmentCheck);
      await m.dispose();
    });

    test('events/burst 기준을 못 넘는 강도는 통과시키지 않는다', () async {
      final m = SessionMachine(StimController(link));
      await m.begin();
      m.onLinkConnected();
      m.submitAttachmentCheck(_goodCheck);

      m.submitIntensity(level: 1, eventsPerBurst: kMinEventsPerBurst - 1);
      expect(m.state, SessionState.intensityWizard,
          reason: '강도가 모자라면 다음 단계로 올린다');
      await m.dispose();
    });

    test('동기화가 끝나기 전에는 playing이 아니다', () async {
      final m = SessionMachine(StimController(link));
      await m.begin();
      m.onLinkConnected();
      m.submitAttachmentCheck(_goodCheck);
      m.submitIntensity(level: 3, eventsPerBurst: 18);

      m.onSyncProgress(kSyncWindowS - 1.0);
      expect(m.state, SessionState.syncing);
      await m.dispose();
    });
  });

  group('강도 — 세션 중 하향만 가능', () {
    test('세션 중 강도를 낮출 수 있다', () async {
      final m = await reachPlaying(link);
      expect(m.lowerIntensity(), isTrue);
      expect(m.intensityLevel, 2);
      await m.dispose();
    });

    test('세션 중 강도를 올릴 수 없다', () async {
      final m = await reachPlaying(link);
      expect(m.raiseIntensityBlocked, isTrue);
      expect(m.intensityLevel, 3);
      await m.dispose();
    });

    test('최저 강도 아래로는 못 내린다', () async {
      final m = await reachPlaying(link);
      m.lowerIntensity();
      m.lowerIntensity();
      expect(m.lowerIntensity(), isFalse);
      expect(m.intensityLevel, 1);
      await m.dispose();
    });
  });

  group('중단 — 어느 단계에서든 즉시', () {
    for (final at in <String>[
      'connecting',
      'attachmentCheck',
      'intensityWizard',
      'syncing',
      'playing',
    ]) {
      test('$at 에서 중단하면 report로 간다', () async {
        final m = SessionMachine(StimController(link));
        await m.begin();
        if (at != 'connecting') m.onLinkConnected();
        if (at != 'connecting' && at != 'attachmentCheck') {
          m.submitAttachmentCheck(_goodCheck);
        }
        if (at == 'syncing' || at == 'playing') {
          m.submitIntensity(level: 3, eventsPerBurst: 18);
        }
        if (at == 'playing') m.onSyncProgress(kSyncWindowS + 1.0);

        await m.stop(SessionEndReason.userStop);
        expect(m.state, SessionState.report);
        expect(m.endReason, SessionEndReason.userStop);
        await m.dispose();
      });
    }

    test('중단하면 자극이 꺼진다', () async {
      final m = await reachPlaying(link);
      await m.stim.start();
      expect(m.stim.isStimulating, isTrue);

      await m.stop(SessionEndReason.userStop);
      expect(m.stim.isStimulating, isFalse);
      expect(link.sent.last, {'cmd': 'trigger_stim', 'on': false});
      await m.dispose();
    });

    test('중단은 여러 번 눌러도 첫 사유가 남는다', () async {
      final m = await reachPlaying(link);
      await m.stop(SessionEndReason.userStop);
      await m.stop(SessionEndReason.remoteStop);
      expect(m.endReason, SessionEndReason.userStop);
      await m.dispose();
    });
  });

  group('종료 조건 연결', () {
    test('playing 중 종료 조건이 걸리면 report로 간다', () async {
      final m = await reachPlaying(link);
      await m.stim.start();

      // 성공률 하락 백업 조건.
      // 실질 세션 상한(kEffectiveSessionMaxSeconds) 안에서 끝나야
      // timeout 이 아니라 successRateDrop 으로 걸린다.
      for (var i = 0; i < kSuccessRateWindow; i++) {
        await m.onBurst(
            fatiguePct: 0, contractionOk: true, reliable: true, tSeconds: 1 + i * 1.6);
      }
      for (var i = 0; i < kSuccessRateWindow; i++) {
        await m.onBurst(
            fatiguePct: 0, contractionOk: false, reliable: true, tSeconds: 82 + i * 1.6);
      }

      expect(m.state, SessionState.report);
      expect(m.endReason, SessionEndReason.successRateDrop);
      expect(m.stim.isStimulating, isFalse, reason: '종료하면 자극도 꺼져야 한다');
      await m.dispose();
    });

    test('BLE가 끊기면 device_disconnect로 끝난다', () async {
      final m = await reachPlaying(link);
      await m.stim.start();

      link.drop(LinkState.disconnected);
      await Future<void>.delayed(Duration.zero);

      expect(m.endReason, SessionEndReason.deviceDisconnect);
      expect(m.stim.isStimulating, isFalse);
      await m.dispose();
    });

    test('반복 횟수와 성공 횟수를 센다', () async {
      final m = await reachPlaying(link);
      for (var i = 0; i < 10; i++) {
        await m.onBurst(
            fatiguePct: 0, contractionOk: i < 7, reliable: true, tSeconds: 60 + i * 1.618);
      }
      expect(m.repCount, 10);
      expect(m.successCount, 7);
      await m.dispose();
    });
  });

  group('완료 기준', () {
    test('부착 체크·강도 마법사를 통과해야만 playing이다', () async {
      final m = SessionMachine(StimController(link));
      await m.begin();
      m.onLinkConnected();
      m.onSyncProgress(kSyncWindowS + 1.0);
      expect(m.state, isNot(SessionState.playing));
      await m.dispose();
    });
  });
}
