import 'dart:convert';
import 'dart:io';

import 'package:flutter_app/game/data/live_fatigue_feed.dart';
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
}
