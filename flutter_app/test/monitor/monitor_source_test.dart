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

  // ── 신호 정지 감지 (Critical 2) ─────────────────────────────────────
  //
  // emitTick() 은 예전에 session.envLast/rmsLast/mdfLast·feed.tracker의
  // 캐시값을 무조건 tick 으로 내보냈다 — 전극이 빠지거나 ESP32 가 죽어도
  // 값이 그대로라 웹은 "지금"인 척 계속 그렸다. 웹의 stale 감지는 전부
  // tick **도착**에 걸려 있어(2초 무수신) 이 경로로는 절대 안 걸린다.
  group('신호 정지 감지 (Critical 2)', () {
    //
    // 두 테스트 모두 emitTick() 을 손으로 부르지 않고 source.start() 가 스스로
    // 띄우는 100ms 주기 실 타이머에 맡긴다 — 실제 프로덕션에서 emitTick() 은
    // 오직 그 타이머로만 불린다. 손으로 emitTick() 을 섞어 부르면 타이머의
    // 자동 호출과 경합해(둘 다 같은 _stalled 래치를 공유) 타이밍에 따라
    // 결과가 달라지는 테스트가 된다 — 실제로 처음 이 테스트를 짤 때 그렇게
    // 짰다가 겪었다.
    test('신호가 1.5초 넘게 없으면 tick 을 멈추고 link(\'stalled\') 를 한 번 보낸다',
        () async {
      final session = SessionController();
      addTearDown(session.dispose);
      final feed = LiveFatigueFeed(session: session);
      addTearDown(feed.dispose);
      final sink = _FakeSink();
      final source = MonitorSource(session: session, feed: feed, sink: sink);

      await feed.start();
      source.start();
      addTearDown(source.stop);

      // 정상 구간 — 시작 직후라 신호가 "최근"이다. 100ms 타이머가 몇 차례
      // 돌 시간을 준다.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(sink.ticks, isNotEmpty, reason: '정상 구간에는 tick 이 나가야 한다');

      // 그 뒤로 세션에 아무 신호도 주지 않는다 — 전극이 빠지거나 ESP32 가
      // 죽은 상황을 흉내낸다(세션 notifyListeners() 가 멈춘 것). 1.5초
      // 임계값을 넘도록 충분히 기다린다.
      await Future<void>.delayed(const Duration(milliseconds: 1500));

      expect(sink.links.where((l) => l == 'stalled'), hasLength(1),
          reason: 'link(\'stalled\') 가 정확히 한 번만 와야 한다(100ms 마다 '
              '도는 타이머가 매번 재발신하면 안 된다)');

      final ticksWhenStale = sink.ticks.length;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(sink.ticks.length, ticksWhenStale,
          reason: '신호가 죽으면 얼어붙은 값을 tick 으로 더 내보내면 안 된다 '
              '— 웹이 그걸 "지금"인 척 그린다(Critical 2)');
    });

    test('신호가 돌아오면 stalled 가 풀리고 tick 이 재개된다', () async {
      final session = SessionController();
      addTearDown(session.dispose);
      final feed = LiveFatigueFeed(session: session);
      addTearDown(feed.dispose);
      final sink = _FakeSink();
      final source = MonitorSource(session: session, feed: feed, sink: sink);

      await feed.start();
      source.start();
      addTearDown(source.stop);

      // 1.5초 임계값을 넘겨 stalled 로 만든다.
      await Future<void>.delayed(const Duration(milliseconds: 1700));
      expect(sink.links.where((l) => l == 'stalled'), hasLength(1));

      // 세션에 새 신호가 온 것처럼 흉내낸다 — _onSession() 이 이걸로
      // _lastSignalAt 을 갱신한다. 그 뒤로는 다시 100ms 타이머가 스스로
      // 재개를 감지해야 한다.
      session.envLast = 5.0;
      // ignore: invalid_use_of_protected_member
      session.notifyListeners();

      final ticksBeforeRecovery = sink.ticks.length;
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(sink.ticks.length, greaterThan(ticksBeforeRecovery),
          reason: '신호가 돌아오면 tick 발신이 재개돼야 한다');
      expect(sink.links.last, isNot('stalled'),
          reason: '신호가 돌아오면 link 상태도 실제 연결 상태로 복구돼야 '
              '한다 — 안 그러면 "센서 끊김" 배너가 영원히 안 지워진다');
    });
  });

  // ── hello.startedAtMs (Important 6b) ────────────────────────────────
  test('hello.startedAtMs 는 접속 시각이 아니라 세션 시작 시각이다', () async {
    final session = SessionController();
    addTearDown(session.dispose);
    final feed = LiveFatigueFeed(session: session);
    addTearDown(feed.dispose);
    final sink = _FakeSink();
    final source = MonitorSource(session: session, feed: feed, sink: sink);

    await feed.start();
    final beforeStart = DateTime.now().millisecondsSinceEpoch;
    source.start();
    addTearDown(source.stop);

    // buildHello() 를 세션 시작보다 한참 뒤(치료사가 세션 도중에 접속한
    // 상황)에 부른다. startedAtMs 가 "접속 시각"이면 이 지연만큼 벌어져야
    // 하고, "세션 시작 시각"이면 start() 시점 그대로여야 한다.
    await Future<void>.delayed(const Duration(milliseconds: 150));
    final hello = source.buildHello('테스트');
    final afterBuild = DateTime.now().millisecondsSinceEpoch;

    expect(hello.startedAtMs, inInclusiveRange(beforeStart, afterBuild));
    expect(afterBuild - hello.startedAtMs, greaterThanOrEqualTo(100),
        reason: 'buildHello() 를 나중에 불러도 시작 시각은 그대로여야 한다 — '
            '여기서 DateTime.now() 를 다시 읽으면 "세션 시작"이 아니라 '
            '"이 클라이언트가 접속한 시각"이 되어버린다(Important 6b).');
  });

  // ── 휴식 이벤트 (Important 4) ────────────────────────────────────────
  test('restStart/restEnd 가 rest_start/rest_end 이벤트를 낸다', () async {
    final session = SessionController();
    addTearDown(session.dispose);
    final feed = LiveFatigueFeed(session: session);
    addTearDown(feed.dispose);
    final sink = _FakeSink();
    final source = MonitorSource(session: session, feed: feed, sink: sink);

    await feed.start();
    source.start();
    addTearDown(source.stop);
    sink.events.clear();

    source.restStart(12.0);
    source.restEnd(30.0);

    expect(sink.events.map((e) => e.kind), ['rest_start', 'rest_end']);
    expect(sink.events[0].t, 12.0);
    expect(sink.events[1].t, 30.0);
  });

  // ── tick 의 t1/t2/t3 (Important 5) ───────────────────────────────────
  test('emitTick 이 tracker 의 t1/t2/t3 를 tick 마다 실어 보낸다', () async {
    final session = SessionController();
    addTearDown(session.dispose);
    final feed = LiveFatigueFeed(session: session);
    addTearDown(feed.dispose);
    final sink = _FakeSink();
    final source = MonitorSource(session: session, feed: feed, sink: sink);

    await feed.start();
    source.start();
    addTearDown(source.stop);

    // baseline 이 없으면 tracker 의 t1/t2/t3 도 전부 null 이라, "실어 보낸
    // 값이 tracker 값과 같다"는 비교가 null==null 로 트리비얼하게 통과해
    // 버려서 emitTick() 이 t1/t2/t3 를 아예 안 실어도 이 테스트가 못 잡는다.
    // 'zone 이벤트' 테스트와 같은 합성 시퀀스로 실제 1σ 도달을 만든다.
    for (var i = 0; i < 30; i++) {
      feed.tracker.addBurst(20.0 + i * 2.0, 100.0 + (i % 3));
    }
    for (var i = 0; i < 20; i++) {
      feed.tracker.addBurst(90.0 + i * 2.0, 100.0 - i * 4.0);
    }
    feed.tracker.flush();
    expect(feed.tracker.t1, isNotNull,
        reason: '합성 시퀀스가 1σ 도달을 못 만들었다 — 테스트 데이터를 다시 '
            '봐야 한다');

    source.emitTick();
    expect(sink.ticks.single.t1, feed.tracker.t1);
    expect(sink.ticks.single.t1, isNotNull);
    expect(sink.ticks.single.t2, feed.tracker.t2);
    expect(sink.ticks.single.t3, feed.tracker.t3);
  });

  // ── 이벤트 경로 일반 커버리지 ────────────────────────────────────────
  //
  // 이전엔 이 경로(session_start/session_stop/contraction/zone/fatigue)에
  // 테스트가 하나도 없었다 — Finding 3(fatigue 가 웹에서 조용히 버려짐)와
  // Finding 4(rest_start/rest_end 를 아무도 안 보냄)가 리뷰 전까지 살아남은
  // 이유다. "Dart 쪽에서 emit 되는가" 와 "웹이 그걸 처리하는가" 는 서로
  // 다른 질문이고, 이 그룹은 앞의 질문만 답한다 — 뒤의 질문은
  // protocol_completeness_test.dart 가 답한다.
  group('MonitorSource 이벤트 경로 (일반 커버리지)', () {
    test('start() 는 session_start 를, stop() 은 session_stop 을 낸다',
        () async {
      final session = SessionController();
      addTearDown(session.dispose);
      final feed = LiveFatigueFeed(session: session);
      addTearDown(feed.dispose);
      final sink = _FakeSink();
      final source = MonitorSource(session: session, feed: feed, sink: sink);

      await feed.start();
      source.start();
      expect(sink.events.map((e) => e.kind), contains('session_start'));

      source.stop();
      expect(sink.events.map((e) => e.kind), contains('session_stop'));
    });

    test('수축(버스트)이 contraction 이벤트로 나간다', () async {
      final session = SessionController();
      addTearDown(session.dispose);
      final feed = LiveFatigueFeed(session: session);
      addTearDown(feed.dispose);
      final sink = _FakeSink();
      final source = MonitorSource(session: session, feed: feed, sink: sink);

      await feed.start();
      source.start();
      addTearDown(source.stop);

      // feed._onSignal() 이 mwCount 증가를 버스트로 묶어 contractions 로
      // 흘린다 — BLE 메시지 전체를 조립할 필요 없이 st 를 직접 바꾸고
      // notifyListeners() 하나면 충분하다.
      session.st.mwCount = 1;
      session.st.mwAmp = 120.0;
      // ignore: invalid_use_of_protected_member
      session.notifyListeners();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(sink.events.map((e) => e.kind), contains('contraction'));
    });

    test('σ 가 존 경계를 넘으면 zone 이벤트가 나간다', () async {
      final session = SessionController();
      addTearDown(session.dispose);
      final feed = LiveFatigueFeed(session: session);
      addTearDown(feed.dispose);
      final sink = _FakeSink();
      final source = MonitorSource(session: session, feed: feed, sink: sink);

      await feed.start();
      source.start();
      addTearDown(source.stop);

      // SigmaTracker 에 직접 합성 시퀀스를 먹인다 — addBurst(t, amp) 는
      // 세션의 실시간과 무관한 순수 계산이라, baseline 창(90초)이 실제로
      // 지나가길 기다릴 필요가 없다. 초반 30점으로 baseline(진폭 100 근방,
      // 약간의 지터)을 만들고, 이후 20점으로 진폭을 급격히 떨어뜨려 σ 를
      // 존 경계 위로 올린다.
      for (var i = 0; i < 30; i++) {
        feed.tracker.addBurst(20.0 + i * 2.0, 100.0 + (i % 3));
      }
      for (var i = 0; i < 20; i++) {
        feed.tracker.addBurst(90.0 + i * 2.0, 100.0 - i * 4.0);
      }
      feed.tracker.flush();
      expect(feed.tracker.currentSigma, isNotNull,
          reason: '합성 시퀀스가 baseline 을 못 잡았다 — 테스트 데이터를 '
              '다시 봐야 한다');
      expect(feed.tracker.currentSigma, greaterThanOrEqualTo(1.0),
          reason: '합성 시퀀스가 존 전환을 일으킬 만큼 σ 를 못 올렸다');

      source.emitTick();

      expect(sink.events.map((e) => e.kind), contains('zone'));
    });

    test('fd 가 true 로 바뀌면 fatigue 이벤트가 나간다', () async {
      final session = SessionController();
      addTearDown(session.dispose);
      final feed = LiveFatigueFeed(session: session);
      addTearDown(feed.dispose);
      final sink = _FakeSink();
      final source = MonitorSource(session: session, feed: feed, sink: sink);

      await feed.start();
      source.start();
      addTearDown(source.stop);

      session.st.fatigueDetected = true;
      // ignore: invalid_use_of_protected_member
      session.notifyListeners();

      expect(sink.events.map((e) => e.kind), contains('fatigue'));
    });
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
