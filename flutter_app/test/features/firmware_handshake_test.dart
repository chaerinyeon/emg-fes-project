import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_app/data/local/session_store.dart';
import 'package:flutter_app/ble/stim_controller.dart';
import 'package:flutter_app/features/session/session_orchestrator.dart';

import '../support/fake_link.dart';

/// 앱과 펌웨어의 악수(handshake).
///
/// ## 왜 이 테스트가 있는가
///
/// 펌웨어는 RAW 표본 전송을 `systemRunning` 뒤에 두고 있다:
/// ```c
/// if (systemRunning && rawQueueCount < RAW_QUEUE_DEPTH) { ...큐에 넣는다... }
/// ```
/// 그리고 `systemRunning = true` 는 **오직 `cmd:"start"`** 에서만 된다.
/// `trigger_stim` 은 마사지기 전원만 누르고 이 값을 건드리지 않는다.
///
/// 새 세션 경로가 `start` 를 빠뜨리면 표본이 **한 개도 오지 않는다.** 그런데
/// 화면에는 「연결 좋음」이 그대로 떠 있고(신호 상태는 버스트가 와야 갱신된다),
/// 부착 확인도 통과하며(연결만으로 판정), 강도 측정만 0 을 낸다. 즉 증상이
/// **훈련 시작 직전까지 아무 데도 드러나지 않다가** syncing 에서 영구 대기로
/// 나타난다. 실기기가 없으면 못 잡는 종류의 사고라 여기서 계약으로 박아 둔다.
SessionOrchestrator _orchestrator(FakeLink link, {String? categoryCode}) =>
    SessionOrchestrator(
      link: link,
      store: InMemorySessionStore(),
      sessionId: 's1',
      patientId: 'p1',
      deviceId: 'd1',
      categoryCode: categoryCode,
    );

void main() {
  late FakeLink link;
  setUp(() => link = FakeLink());
  tearDown(() async => link.dispose());

  List<String> cmds() =>
      link.sent.map((c) => c['cmd'] as String).toList();

  /// 상태 스트림 이벤트를 흘려보낸다.
  ///
  /// [SessionMachine.states] 는 브로드캐스트 스트림이라 전이 알림이 마이크로
  /// 태스크로 온다. 그 전에 dispose 하면 리스너가 죽은 notifier 를 건드린다.
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  _manualStimTests();
  _rawLogTests();

  group('RAW 스트림을 여는 start', () {
    test('세션을 시작하면 펌웨어에 start 를 보낸다', () async {
      final o = _orchestrator(link);
      await o.begin();

      expect(cmds(), contains('start'),
          reason: 'start 가 없으면 systemRunning 이 false 라 RAW 표본이 오지 않는다');
      await settle();
      o.dispose();
    });

    test('start 는 자극보다 먼저 나간다', () async {
      final o = _orchestrator(link);
      await o.begin();
      await o.stim.start();

      final order = cmds();
      expect(order, contains('start'));
      expect(order.indexOf('start'), lessThan(order.indexOf('trigger_stim')),
          reason: '스트림이 열리기 전에 자극하면 그 구간 표본을 통째로 잃는다');
      await settle();
      o.dispose();
    });

    test('마비 유형을 함께 보낸다 — 펌웨어가 프로토콜을 고른다', () async {
      final o = _orchestrator(link, categoryCode: 'C');
      await o.begin();

      final start = link.sent.firstWhere((c) => c['cmd'] == 'start');
      expect(start['category'], 'C');
      await settle();
      o.dispose();
    });

    test('유형을 모르면 category 를 붙이지 않는다', () async {
      final o = _orchestrator(link);
      await o.begin();

      final start = link.sent.firstWhere((c) => c['cmd'] == 'start');
      expect(start.containsKey('category'), isFalse,
          reason: '모르는 값을 빈 문자열로 보내면 펌웨어가 그걸 유형으로 읽는다');
      await settle();
      o.dispose();
    });
  });

  group('세션이 끝나면 닫는다', () {
    test('stop 을 보낸다', () async {
      final o = _orchestrator(link);
      await o.begin();
      await o.stopByUser();

      expect(cmds(), contains('stop'));
      await settle();
      o.dispose();
    });

    test('자극을 끈 뒤에 stop 이 나간다', () async {
      final o = _orchestrator(link);
      await o.begin();
      await o.stim.start();
      await o.stopByUser();

      final order = cmds();
      final lastStimOff = order.lastIndexOf('trigger_stim');
      expect(order.lastIndexOf('stop'), greaterThan(lastStimOff),
          reason: '자극을 끄는 명령이 세션 종료보다 뒤로 밀리면 안 된다');
      await settle();
      o.dispose();
    });

    test('링크가 죽어 있어도 종료가 예외로 무너지지 않는다', () async {
      final o = _orchestrator(link);
      await o.begin();
      link.failSend = true;

      await o.stopByUser();
      expect(o.endReason, isNotNull, reason: '기록은 남아야 한다');
      await settle();
      o.dispose();
    });
  });
}

/// 수동 자극 모드 — 마사지기가 아직 펌웨어에 배선되지 않은 동안의 계약.
void _manualStimTests() {
  late FakeLink link;
  setUp(() => link = FakeLink());
  tearDown(() async => link.dispose());

  SessionOrchestrator manual(FakeLink l) => SessionOrchestrator(
        link: l,
        store: InMemorySessionStore(),
        sessionId: 's1',
        patientId: 'p1',
        deviceId: 'd1',
        manualStim: true,
      );

  group('수동 자극 모드', () {
    test('trigger_stim 을 보내지 않는다 — 닿을 곳이 없는 명령이다', () async {
      final o = manual(link);
      await o.begin();
      await o.stim.start();
      await o.stim.stop(reason: StimStopReason.sessionEnd);
      await Future<void>.delayed(Duration.zero);

      expect(link.sent.map((c) => c['cmd']), isNot(contains('trigger_stim')));
      o.dispose();
    });

    test('그래도 RAW 스트림은 연다 — 신호가 있어야 게임이 돈다', () async {
      final o = manual(link);
      await o.begin();
      await Future<void>.delayed(Duration.zero);

      expect(link.sent.map((c) => c['cmd']), contains('start'));
      o.dispose();
    });

    test('자극 상태는 그대로 추적한다 — 기록에서 자극 구간이 사라지면 안 된다', () async {
      final o = manual(link);
      await o.begin();

      await o.stim.start();
      expect(o.stim.isStimulating, isTrue);
      await o.stim.stop(reason: StimStopReason.userStop);
      expect(o.stim.isStimulating, isFalse);
      expect(o.stim.lastStopReason, StimStopReason.userStop);

      await Future<void>.delayed(Duration.zero);
      o.dispose();
    });

    test('비상 정지는 그대로 나간다 — 펌웨어가 할 수 있는 일은 해야 한다', () async {
      final o = manual(link);
      await o.begin();
      await o.stim.start();
      await o.stim.emergencyStop();
      await Future<void>.delayed(Duration.zero);

      expect(link.sent.map((c) => c['cmd']), contains('emergency'));
      o.dispose();
    });
  });
}

/// raw 파형 기록 — 실기기 실패를 노트북에서 재현할 유일한 통로.
void _rawLogTests() {
  late FakeLink link;
  setUp(() => link = FakeLink());
  tearDown(() async => link.dispose());

  List<int> packet(int firstIdx, List<int> samples) {
    final b = ByteData(6 + 2 * samples.length);
    b.setUint32(0, firstIdx, Endian.little);
    b.setUint16(4, samples.length, Endian.little);
    for (var i = 0; i < samples.length; i++) {
      b.setInt16(6 + 2 * i, samples[i], Endian.little);
    }
    return b.buffer.asUint8List();
  }

  SessionOrchestrator make(FakeLink l) => SessionOrchestrator(
        link: l,
        store: InMemorySessionStore(),
        sessionId: 's1',
        patientId: 'p1',
        deviceId: 'd1',
        manualStim: true,
      );

  group('raw 기록', () {
    test('세션이 시작되면 표본을 받아 적는다', () async {
      final o = make(link);
      await o.begin();

      link.emit(packet(0, List<int>.filled(100, 1900)));
      link.emit(packet(100, List<int>.filled(100, 1910)));
      await Future<void>.delayed(Duration.zero);

      expect(o.rawLogSamples, 200);
      expect(o.rawLogDropped, 0);
      o.dispose();
    });

    test('패킷이 빠지면 유실로 센다 — 조용히 메우지 않는다', () async {
      final o = make(link);
      await o.begin();

      link.emit(packet(0, List<int>.filled(100, 1900)));
      // 100~199 를 통째로 건너뛴다.
      link.emit(packet(200, List<int>.filled(100, 1900)));
      await Future<void>.delayed(Duration.zero);

      expect(o.rawLogDropped, 100);
      o.dispose();
    });

    test('세션이 끝나면 기록도 멈춘다', () async {
      final o = make(link);
      await o.begin();
      link.emit(packet(0, List<int>.filled(100, 1900)));
      await Future<void>.delayed(Duration.zero);

      await o.stopByUser();
      final after = o.rawLogSamples;

      link.emit(packet(100, List<int>.filled(100, 1900)));
      await Future<void>.delayed(Duration.zero);

      expect(o.rawLogSamples, after, reason: '끝난 뒤 들어온 표본은 이 세션 것이 아니다');
      o.dispose();
    });
  });
}
