import 'package:flutter_app/game/data/live_fatigue_feed.dart';
import 'package:flutter_app/monitor/monitor_frame.dart';
import 'package:flutter_app/monitor/monitor_source.dart';
import 'package:flutter_app/services/session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeSink implements MonitorSink {
  final ticks = <MonitorTick>[];
  final events = <MonitorEvent>[];
  final links = <String>[];

  @override
  void tick(MonitorTick f) => ticks.add(f);

  @override
  void event(MonitorEvent e) => events.add(e);

  @override
  void link(String state) => links.add(state);
}

void main() {
  test('세션 값이 tick 으로 옮겨진다', () async {
    final session = SessionController();
    addTearDown(session.dispose);
    final feed = LiveFatigueFeed(session: session);
    addTearDown(feed.dispose);
    final sink = _FakeSink();
    final source = MonitorSource(session: session, feed: feed, sink: sink);

    await feed.start();
    source.start();
    addTearDown(source.stop);

    session.envLast = 120.0;
    session.rmsLast = 210.0;
    session.mdfLast = 88.0;
    source.emitTick();

    expect(sink.ticks, hasLength(1));
    expect(sink.ticks.single.env, 120.0);
    expect(sink.ticks.single.rms, 210.0);
    expect(sink.ticks.single.mdf, 88.0);
    // baseline 전이므로 σ 는 없다 — "정상"으로 단정하지 않는다.
    expect(sink.ticks.single.sigma, isNull);
  });

  test('연결 상태가 바뀌면 link 를 보낸다', () async {
    final session = SessionController();
    addTearDown(session.dispose);
    final feed = LiveFatigueFeed(session: session);
    addTearDown(feed.dispose);
    final sink = _FakeSink();
    final source = MonitorSource(session: session, feed: feed, sink: sink);

    await feed.start();
    source.start();
    addTearDown(source.stop);

    // notifyListeners 는 @protected 라 분석기가 경고한다. 테스트에서 상태 변화를
    // 직접 흘려보내기 위한 의도된 사용이므로 억제한다.
    session.connState = 'connected';
    // ignore: invalid_use_of_protected_member
    session.notifyListeners();
    session.connState = 'connected';
    // ignore: invalid_use_of_protected_member
    session.notifyListeners();
    session.connState = 'disconnected';
    // ignore: invalid_use_of_protected_member
    session.notifyListeners();

    // 같은 상태가 이어지면 중복 전송하지 않는다.
    expect(sink.links, ['connected', 'disconnected']);
  });

  test('buildHello 가 링버퍼와 baseline 을 담는다', () async {
    final session = SessionController();
    addTearDown(session.dispose);
    final feed = LiveFatigueFeed(session: session);
    addTearDown(feed.dispose);
    final sink = _FakeSink();
    final source = MonitorSource(session: session, feed: feed, sink: sink);

    await feed.start();
    source.start();
    addTearDown(source.stop);

    source.emitTick();
    source.emitTick();

    final hello = source.buildHello('홍길동');
    expect(hello.session, '홍길동');
    expect(hello.ticks, hasLength(2));
    expect(hello.mu0, feed.tracker.mu0);
    expect(hello.t1, feed.tracker.t1);
  });
}
