import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_app/game/data/live_fatigue_feed.dart';
import 'package:flutter_app/monitor/monitor_address.dart';
import 'package:flutter_app/monitor/monitor_broadcaster.dart';
import 'package:flutter_app/monitor/monitor_source.dart';
import 'package:flutter_app/services/profile_service.dart';
import 'package:flutter_app/services/session_controller.dart';
import 'package:flutter_app/services/simulator_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

void main() {
  // SessionController.startSimulator() 는 gProfileService.active 를 읽는다.
  // 앱은 main() 에서 Hive.initFlutter() 로 이를 준비하지만 테스트는 그 경로를
  // 타지 않는다. 모니터 파이프라인과는 무관한 테스트 배선이므로 임시
  // 디렉터리로 한 번만 초기화한다.
  late Directory hiveDir;

  setUpAll(() async {
    hiveDir = await Directory.systemTemp.createTemp('monitor_e2e_hive_');
    Hive.init(hiveDir.path);
    await gProfileService.init();
  });

  tearDownAll(() async {
    await Hive.close();
    if (await hiveDir.exists()) await hiveDir.delete(recursive: true);
  });

  test('시뮬레이터 → 소스 → 방송기 → WS 클라이언트', () async {
    final session = SessionController();
    addTearDown(session.dispose);
    final feed = LiveFatigueFeed(session: session);
    addTearDown(feed.dispose);

    late final MonitorSource source;
    final broadcaster = MonitorBroadcaster(
      pageLoader: () async => '<html></html>',
      helloBuilder: () => source.buildHello('시뮬레이터'),
      token: makeToken(),
    );
    source = MonitorSource(
      session: session,
      feed: feed,
      sink: BroadcasterSink(broadcaster),
    );

    final ep = await broadcaster.start();
    expect(ep, isNotNull);
    addTearDown(broadcaster.stop);

    await feed.start();
    source.start();
    addTearDown(source.stop);
    await session.startSimulator(SimScenario.continuousFatigue);
    addTearDown(session.stopSimulator);

    final ws = await WebSocket.connect(
        'ws://127.0.0.1:${ep!.port}/ws?k=${ep.token}');
    addTearDown(() => ws.close());

    final got = <Map<String, dynamic>>[];
    final sub = ws.listen(
        (m) => got.add(jsonDecode(m as String) as Map<String, dynamic>));
    addTearDown(sub.cancel);

    await Future<void>.delayed(const Duration(milliseconds: 600));

    expect(got.first['t'], 'hello');
    expect(got.first['session'], '시뮬레이터');
    expect(got.where((m) => m['t'] == 'tick').length, greaterThan(2),
        reason: '10 Hz 이므로 600ms 안에 여러 개가 와야 한다');
  });

  test('adopt 된 RAW 바이트가 구독한 WS 클라이언트에 도달한다', () async {
    final dataCtrl = StreamController<List<int>>.broadcast();
    addTearDown(dataCtrl.close);
    final rawCtrl = StreamController<List<int>>.broadcast();
    addTearDown(rawCtrl.close);

    final session = SessionController();
    addTearDown(session.dispose);
    // 실제 배선(home_page._openGame → adopt)과 동일하게, 데이터/RAW 두
    // characteristic 스트림을 함께 넘긴다.
    session.adopt(
      dataStream: dataCtrl.stream,
      rawStream: rawCtrl.stream,
      label: 'EMG-FES-01',
    );
    final feed = LiveFatigueFeed(session: session);
    addTearDown(feed.dispose);

    late final MonitorSource source;
    final broadcaster = MonitorBroadcaster(
      pageLoader: () async => '<html></html>',
      helloBuilder: () => source.buildHello('실측'),
      token: makeToken(),
    );
    source = MonitorSource(
      session: session,
      feed: feed,
      sink: BroadcasterSink(broadcaster),
    );

    final ep = await broadcaster.start();
    expect(ep, isNotNull);
    addTearDown(broadcaster.stop);

    await feed.start();
    source.start();
    addTearDown(source.stop);

    final ws = await WebSocket.connect(
        'ws://127.0.0.1:${ep!.port}/ws?k=${ep.token}');
    addTearDown(() => ws.close());

    final got = <Map<String, dynamic>>[];
    final sub = ws.listen(
        (m) => got.add(jsonDecode(m as String) as Map<String, dynamic>));
    addTearDown(sub.cancel);

    await Future<void>.delayed(const Duration(milliseconds: 100));

    // 구독 전: 폰이 RAW 패킷을 보내도(BLE 로부터 들어온 바이트) 웹으로는
    // 가지 않는다 — 진단 패널이 접혀 있는 것과 같은 상태다.
    rawCtrl.add(_rawBytes(0, [1, 2, 3]));
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(got.any((m) => m['t'] == 'raw'), isFalse);

    // 구독 후: 같은 경로로 들어온 RAW 바이트가 파싱되어 그대로 도달한다.
    ws.add(jsonEncode({'t': 'sub', 'raw': true}));
    await Future<void>.delayed(const Duration(milliseconds: 150));
    rawCtrl.add(_rawBytes(1000, [10, -20, 30]));
    await Future<void>.delayed(const Duration(milliseconds: 150));

    final rawMsg =
        got.firstWhere((m) => m['t'] == 'raw', orElse: () => const {});
    expect(rawMsg['i'], 1000);
    expect(rawMsg['v'], [10, -20, 30]);
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
