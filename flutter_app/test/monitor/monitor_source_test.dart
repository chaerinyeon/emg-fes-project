import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_app/game/data/live_fatigue_feed.dart';
import 'package:flutter_app/monitor/monitor_frame.dart';
import 'package:flutter_app/monitor/monitor_source.dart';
import 'package:flutter_app/services/session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

class _RawCall {
  _RawCall(this.firstSampleMs, this.samples);
  final int firstSampleMs;
  final List<int> samples;
}

class _FakeSink implements MonitorSink {
  final ticks = <MonitorTick>[];
  final events = <MonitorEvent>[];
  final links = <String>[];
  final raws = <_RawCall>[];

  @override
  void tick(MonitorTick f) => ticks.add(f);

  @override
  void event(MonitorEvent e) => events.add(e);

  @override
  void link(String state) => links.add(state);

  @override
  void raw(int firstSampleMs, List<int> samples) =>
      raws.add(_RawCall(firstSampleMs, samples));
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

  test('session 이 파싱한 RAW 패킷이 sink.raw 로 전달된다', () async {
    final rawCtrl = StreamController<List<int>>.broadcast();
    addTearDown(rawCtrl.close);
    final session = SessionController();
    addTearDown(session.dispose);
    // adopt() 를 빌려 rawStream 을 연결한다 — 실제 배선(home_page → adopt)과
    // 같은 경로다. dataStream 은 이 테스트에서 쓰지 않으므로 빈 스트림.
    session.adopt(
      dataStream: const Stream<List<int>>.empty(),
      rawStream: rawCtrl.stream,
      label: '테스트',
    );
    final feed = LiveFatigueFeed(session: session);
    addTearDown(feed.dispose);
    final sink = _FakeSink();
    final source = MonitorSource(session: session, feed: feed, sink: sink);

    await feed.start();
    source.start();
    addTearDown(source.stop);

    rawCtrl.add(_rawBytes(1000, [10, -20, 30]));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(sink.raws, hasLength(1));
    expect(sink.raws.single.firstSampleMs, 1000);
    expect(sink.raws.single.samples, [10, -20, 30]);
  });

  test('stop() 하면 더 이상 RAW 를 전달하지 않는다', () async {
    final rawCtrl = StreamController<List<int>>.broadcast();
    addTearDown(rawCtrl.close);
    final session = SessionController();
    addTearDown(session.dispose);
    session.adopt(
      dataStream: const Stream<List<int>>.empty(),
      rawStream: rawCtrl.stream,
      label: '테스트',
    );
    final feed = LiveFatigueFeed(session: session);
    addTearDown(feed.dispose);
    final sink = _FakeSink();
    final source = MonitorSource(session: session, feed: feed, sink: sink);

    await feed.start();
    source.start();
    source.stop();

    rawCtrl.add(_rawBytes(1000, [10, -20, 30]));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(sink.raws, isEmpty);
  });
}

/// RAW 패킷 바이트 조립 헬퍼(펌웨어 포맷, little-endian) — session_adopt_test.dart 와 동일.
List<int> _rawBytes(int firstSampleMs, List<int> samples) {
  final bd = ByteData(6 + 2 * samples.length);
  bd.setUint32(0, firstSampleMs, Endian.little);
  bd.setUint16(4, samples.length, Endian.little);
  for (var i = 0; i < samples.length; i++) {
    bd.setInt16(6 + 2 * i, samples[i], Endian.little);
  }
  return bd.buffer.asUint8List();
}
