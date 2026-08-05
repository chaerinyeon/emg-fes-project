import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/ble/device_connection.dart';
import 'package:flutter_app/ble/stim_controller.dart';

/// 하드웨어 없이 안전 로직을 검증하기 위한 가짜 링크.
class FakeLink implements DeviceLink {
  final _state = StreamController<LinkState>.broadcast();
  final _packets = StreamController<List<int>>.broadcast();

  LinkState _current = LinkState.connected;
  final sent = <Map<String, dynamic>>[];

  /// true 면 send 가 예외를 던진다 (링크가 죽는 중).
  bool failSend = false;

  @override
  LinkState get state => _current;

  @override
  Stream<LinkState> get stateStream => _state.stream;

  @override
  Stream<List<int>> get rawPackets => _packets.stream;

  @override
  Future<void> send(Map<String, dynamic> cmd) async {
    if (failSend) throw StateError('link down');
    sent.add(cmd);
  }

  @override
  Future<void> connect() async => drop(LinkState.connected);

  @override
  Future<void> disconnect() async => drop(LinkState.disconnected);

  void drop(LinkState s) {
    _current = s;
    _state.add(s);
  }

  void pushPacket(List<int> bytes) => _packets.add(bytes);

  Future<void> dispose() async {
    await _state.close();
    await _packets.close();
  }
}

StimController _make(
  FakeLink link, {
  Duration maxStim = const Duration(seconds: 10),
  Duration dataWatchdog = const Duration(seconds: 10),
}) =>
    StimController(link, maxStimDuration: maxStim, dataTimeout: dataWatchdog);

void main() {
  late FakeLink link;

  setUp(() => link = FakeLink());
  tearDown(() async => link.dispose());

  group('StimController — 기본 제어', () {
    test('start는 trigger_stim on=true 를 보낸다', () async {
      final c = _make(link);
      final ok = await c.start();
      expect(ok, isTrue);
      expect(c.isStimulating, isTrue);
      expect(link.sent.last, {'cmd': 'trigger_stim', 'on': true});
      await c.dispose();
    });

    test('stop은 trigger_stim on=false 를 보낸다', () async {
      final c = _make(link);
      await c.start();
      await c.stop(reason: StimStopReason.userStop);
      expect(c.isStimulating, isFalse);
      expect(link.sent.last, {'cmd': 'trigger_stim', 'on': false});
      await c.dispose();
    });

    test('stop은 여러 번 불러도 안전하다', () async {
      final c = _make(link);
      await c.start();
      await c.stop(reason: StimStopReason.userStop);
      final n = link.sent.length;
      await c.stop(reason: StimStopReason.userStop);
      expect(c.isStimulating, isFalse);
      expect(link.sent.length, n, reason: '이미 꺼진 상태면 중복 전송하지 않는다');
      await c.dispose();
    });
  });

  group('StimController — BLE 끊김 페일세이프', () {
    test('링크가 끊기면 자극은 즉시 꺼진 것으로 본다', () async {
      final c = _make(link);
      await c.start();
      expect(c.isStimulating, isTrue);

      link.drop(LinkState.disconnected);
      await Future<void>.delayed(Duration.zero);

      expect(c.isStimulating, isFalse,
          reason: '앱이 자극 중이라고 믿고 있으면 안전 로직이 전부 어긋난다');
      await c.dispose();
    });

    test('끊긴 상태에서는 start를 거부한다', () async {
      final c = _make(link);
      link.drop(LinkState.disconnected);
      await Future<void>.delayed(Duration.zero);

      final ok = await c.start();
      expect(ok, isFalse);
      expect(c.isStimulating, isFalse);
      expect(link.sent, isEmpty);
      await c.dispose();
    });

    test('재연결해도 자동으로 자극이 켜지지 않는다', () async {
      final c = _make(link);
      await c.start();
      link.drop(LinkState.disconnected);
      await Future<void>.delayed(Duration.zero);
      link.drop(LinkState.connected);
      await Future<void>.delayed(Duration.zero);

      expect(c.isStimulating, isFalse,
          reason: '환자가 모르는 사이 자극이 되살아나면 안 된다');
      await c.dispose();
    });

    test('전송이 실패해도 로컬 상태는 꺼짐으로 바뀐다', () async {
      final c = _make(link);
      await c.start();
      link.failSend = true;

      await c.stop(reason: StimStopReason.userStop);
      expect(c.isStimulating, isFalse);
      await c.dispose();
    });
  });

  group('StimController — 비상 정지', () {
    test('emergency는 다른 무엇보다 먼저 나간다', () async {
      final c = _make(link);
      await c.start();
      await c.emergencyStop();

      expect(c.isStimulating, isFalse);
      expect(link.sent.map((m) => m['cmd']), contains('emergency'));
      await c.dispose();
    });

    test('자극 중이 아니어도 emergency는 전송된다', () async {
      final c = _make(link);
      await c.emergencyStop();
      expect(link.sent.map((m) => m['cmd']), contains('emergency'));
      await c.dispose();
    });

    test('emergency 이후에는 start가 잠긴다', () async {
      final c = _make(link);
      await c.emergencyStop();
      final ok = await c.start();
      expect(ok, isFalse);
      expect(c.isStimulating, isFalse);
      await c.dispose();
    });

    test('잠금은 명시적으로 풀어야 한다', () async {
      final c = _make(link);
      await c.emergencyStop();
      c.clearEmergency();
      expect(await c.start(), isTrue);
      await c.dispose();
    });
  });

  group('StimController — 로컬 자동 종료 (1차 안전장치)', () {
    test('로컬 상한은 펌웨어 상한(180초)보다 짧아야 한다', () {
      expect(kLocalMaxStimSeconds, lessThan(180),
          reason: '로컬 자동 종료가 언제나 1차여야 한다. '
              '펌웨어 타임아웃이 먼저 걸리면 앱은 이유를 모른다');
    });

    test('상한에 도달하면 스스로 끈다', () async {
      final c = _make(link, maxStim: const Duration(milliseconds: 60));
      await c.start();
      await Future<void>.delayed(const Duration(milliseconds: 140));

      expect(c.isStimulating, isFalse);
      expect(link.sent.last, {'cmd': 'trigger_stim', 'on': false});
      expect(c.lastStopReason, StimStopReason.maxDuration);
      await c.dispose();
    });

    test('데이터가 끊기면 자극을 멈춘다', () async {
      final c = _make(link, dataWatchdog: const Duration(milliseconds: 60));
      await c.start();
      await Future<void>.delayed(const Duration(milliseconds: 140));

      expect(c.isStimulating, isFalse);
      expect(c.lastStopReason, StimStopReason.signalLost);
      await c.dispose();
    });

    test('데이터가 계속 들어오면 워치독이 걸리지 않는다', () async {
      final c = _make(link, dataWatchdog: const Duration(milliseconds: 100));
      await c.start();
      for (var i = 0; i < 6; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        c.noteDataReceived();
      }
      expect(c.isStimulating, isTrue);
      await c.dispose();
    });
  });

  group('StimController — 감사 로그', () {
    test('모든 상태 변화가 기록된다', () async {
      final c = _make(link);
      final log = <StimTransition>[];
      final sub = c.transitions.listen(log.add);

      await c.start();
      await c.stop(reason: StimStopReason.userStop);
      await Future<void>.delayed(Duration.zero);

      expect(log.length, 2);
      expect(log[0].on, isTrue);
      expect(log[1].on, isFalse);
      expect(log[1].reason, StimStopReason.userStop);
      await sub.cancel();
      await c.dispose();
    });
  });

  group('StimController — dispose', () {
    test('dispose하면 자극을 끄고 나간다', () async {
      final c = _make(link);
      await c.start();
      await c.dispose();
      expect(link.sent.last, {'cmd': 'trigger_stim', 'on': false});
    });
  });
}
