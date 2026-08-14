import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_app/data/local/session_store.dart';
import 'package:flutter_app/features/session/session_orchestrator.dart';
import 'package:flutter_app/monitor/monitor_frame.dart';
import 'package:flutter_app/monitor/monitor_source.dart' show MonitorSink;
import 'package:flutter_app/monitor/refit_monitor_source.dart';
import 'package:flutter_app/signal/fatigue_engine.dart' show FatigueAdvice;
import 'package:flutter_app/signal/signal_pipeline.dart';

import '../support/fake_link.dart';

class RecordingSink implements MonitorSink {
  final ticks = <MonitorTick>[];
  final events = <MonitorEvent>[];
  final links = <String>[];
  final raws = <int>[];

  @override
  void tick(MonitorTick f) => ticks.add(f);
  @override
  void event(MonitorEvent e) => events.add(e);
  @override
  void link(String state) => links.add(state);
  @override
  void raw(int firstSampleIndex, List<int> samples) => raws.add(firstSampleIndex);
}

/// 조립부를 손으로 밀기 위한 최소 세트.
SessionOrchestrator makeOrchestrator(FakeLink link) => SessionOrchestrator(
      link: link,
      store: InMemorySessionStore(),
      sessionId: 's1',
      patientId: 'p1',
      deviceId: 'd1',
    );

BurstResult burst(int i, double t, double p2p) => BurstResult(
      index: i,
      tSeconds: t,
      p2p: p2p,
      p2pRaw: p2p,
      fatiguePct: 0,
      contractionOk: true,
      eventsInBurst: 18,
      reliable: true,
      levelSegmentIndex: 0,
      stimOnsetMs: (t * 1000).round(),
      aRef: 1000,
      advice: FatigueAdvice.normal,
      rms: 300,
      mdfHz: 62,
    );

void main() {
  late FakeLink link;
  late SessionOrchestrator o;
  late RecordingSink sink;
  late RefitMonitorSource source;
  late DateTime clock;

  setUp(() {
    clock = DateTime.utc(2026, 8, 10, 10);
    link = FakeLink();
    o = makeOrchestrator(link);
    sink = RecordingSink();
    source = RefitMonitorSource(
      orchestrator: o,
      sink: sink,
      now: () => clock,
    );
  });

  tearDown(() async {
    source.stop();
    o.dispose();
    await link.dispose();
  });

  group('σ 를 지어내지 않는다', () {
    test('baseline 이 서기 전에는 σ 가 null 이고 존도 없다', () {
      source.start();
      o.lastSampleWallMs = clock.millisecondsSinceEpoch;

      source.emitTick();

      final f = sink.ticks.last;
      expect(f.sigma, isNull, reason: '모르는 값을 "정상"으로 단정하지 않는다');
      expect(f.zone, isNull);
      expect(f.stamina, isNull);
    });

    test('세션 90초 전에는 baseline 이 서지 않는다', () {
      source.start();
      o.lastSampleWallMs = clock.millisecondsSinceEpoch;

      // 50버스트 × 1.618초 = 81초. baseline 창(20~90초)이 아직 안 닫혔다.
      for (var i = 0; i < 50; i++) {
        o.lastBurst = burst(i, i * 1.618, 1000 + (i % 7) * 12.0);
        o.notifyListeners();
      }
      source.emitTick();

      expect(source.tracker.mu0, isNull);
      expect(sink.ticks.last.sigma, isNull,
          reason: '감시 시작 전이다 — 모르는 것을 "정상"으로 그리지 않는다');
    });

    test('90초를 지나면 M-wave 진폭으로 진짜 σ 가 선다', () {
      source.start();
      o.lastSampleWallMs = clock.millisecondsSinceEpoch;

      // 안정 구간(잔잔한 변동) 뒤 진폭이 떨어진다 = 피로.
      for (var i = 0; i < 80; i++) {
        final t = i * 1.618;
        o.lastBurst =
            burst(i, t, t < 90 ? 1000 + (i % 7) * 12.0 : 500);
        o.notifyListeners();
      }
      source.emitTick();

      expect(source.tracker.mu0, isNotNull, reason: 'baseline 이 서야 한다');
      expect(sink.ticks.last.sigma, isNotNull);
      expect(sink.ticks.last.sigma, greaterThan(0),
          reason: '진폭이 줄었으니 σ 는 양수 — 피로 방향이다');
      // 관찰용 지표도 그대로 실린다.
      expect(sink.ticks.last.env, 500, reason: 'env 자리는 M-wave 진폭이다');
      expect(sink.ticks.last.rms, 300);
      expect(sink.ticks.last.mdf, 62);
    });

    test('버스트마다 contraction 사건이 한 번씩 나간다', () {
      source.start();
      for (var i = 0; i < 5; i++) {
        o.lastBurst = burst(i, i * 1.618, 900);
        o.notifyListeners();
        o.notifyListeners(); // 같은 버스트로 두 번 알려도 한 번만
      }
      expect(
        sink.events.where((e) => e.kind == 'contraction').length,
        5,
      );
    });
  });

  group('표본이 멈추면 tick 도 멈춘다', () {
    test('얼어붙은 값을 "지금"인 척 내보내지 않는다', () {
      source.start();
      o.lastSampleWallMs = clock.millisecondsSinceEpoch;
      source.emitTick();
      final before = sink.ticks.length;

      // 표본이 끊긴 채 시간이 흐른다.
      clock = clock.add(const Duration(seconds: 3));
      source.emitTick();

      expect(sink.ticks.length, before, reason: 'tick 이 더 나가면 안 된다');
      expect(sink.links.last, 'stalled');
    });

    test('신호가 돌아오면 링크 상태를 되돌린다', () {
      source.start();
      o.lastSampleWallMs = clock.millisecondsSinceEpoch;
      source.emitTick();

      clock = clock.add(const Duration(seconds: 3));
      source.emitTick();
      expect(sink.links.last, 'stalled');

      o.lastSampleWallMs = clock.millisecondsSinceEpoch;
      source.emitTick();
      expect(sink.links.last, 'connected');
      expect(sink.ticks.last.t, isNotNull);
    });

    test('세션 도중 접속한 치료사에게 stalled 를 숨기지 않는다', () {
      source.start();
      o.lastSampleWallMs = clock.millisecondsSinceEpoch;
      clock = clock.add(const Duration(seconds: 3));
      source.emitTick();

      // BLE 는 connected 인데 전극만 빠진 상황.
      expect(link.state.name, 'connected');
      expect(source.buildHello('s').link, 'stalled');
    });
  });

  test('세션 시작·종료가 사건으로 남는다', () {
    source.start();
    expect(sink.events.first.kind, 'session_start');
    source.stop();
    expect(sink.events.last.kind, 'session_stop');
  });
}
