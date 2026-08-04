// GameScreen ↔ 모니터 배선 통합 테스트.
//
// commit 27cffa2 가 home_page._openGame() 에 실 세션을 주입하고 GameScreen 이
// 관찰 서버를 띄우게 만들었는데, 그 배선 자체(재진입 가드·pause/resume·
// dispose 순서)엔 자동화된 커버리지가 없었다. `MonitorAddressCard` 세 가지
// 정적 렌더 상태만 있었을 뿐 실제 통합 경로는 아무도 실행하지 않았다.
//
// 여기는 그 배선을 실 `HttpServer.bind` 로 검증한다 — 그래서 `tester.runAsync`
// 로 감싼다. 위젯 트리를 만드는 `pumpWidget`/`pump` 는 fake clock 위에서
// 돌지만, `MonitorBroadcaster.start()` 는 진짜 소켓 바인딩(dart:io)이라 fake
// clock 으로는 절대 끝나지 않는다.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_app/game/ui/game_screen.dart';
import 'package:flutter_app/monitor/monitor_broadcaster.dart';
import 'package:flutter_app/monitor/monitor_source.dart';
import 'package:flutter_app/services/session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

/// home_page._openGame() 이 하는 것과 동일하게 adopt() 로 "연결됨" 상태를
/// 만든다 — 실 BLE 없이 GameScreen 이 (MockFatigueFeed 가 아니라)
/// LiveFatigueFeed 를 타게 만드는 최소 구성. 스트림은 비어 있어 값은 안
/// 흐르지만, 이 파일의 테스트는 모니터 배선(기동·재진입 가드·pause/resume·
/// dispose)만 본다 — 신호 값 자체는 다른 테스트(monitor_source_test 등)가
/// 이미 검증한다.
SessionController _connectedSession() {
  final session = SessionController();
  session.adopt(dataStream: const Stream<List<int>>.empty());
  return session;
}

/// `_GameScreenState` 는 라이브러리 비공개라 테스트가 타입으로 못 잡는다.
/// `@visibleForTesting` 로 공개해 둔 `debugMonitor*` 게터들을 dynamic 으로
/// 호출해 내부 배선(엔드포인트·MonitorSource 동일성·토큰)을 들여다본다.
dynamic _stateOf(WidgetTester tester) => tester.state(find.byType(GameScreen));

Future<void> _settle(
  WidgetTester tester, [
  Duration wait = const Duration(milliseconds: 300),
]) async {
  await Future<void>.delayed(wait);
  await tester.pump();
}

/// `TestWidgetsFlutterBinding` 은 위젯 테스트 전역에 [HttpOverrides] 를 깔아
/// 모든 `HttpClient` 요청을 400 으로 가짜 응답한다(실수로 진짜 네트워크를
/// 타지 않게 하는 안전장치). 이 클래스는 아무것도 오버라이드하지 않는 빈
/// 서브클래스라 [HttpOverrides.createHttpClient] 기본 구현(진짜 `HttpClient`)
/// 을 그대로 쓴다 — `createHttpClient:` 콜백 안에서 `HttpClient()` 를 다시
/// 부르면 같은 zone 을 타고 자기 자신을 재귀 호출해 스택이 넘친다.
class _RealHttpOverrides extends HttpOverrides {}

Future<T> _withRealHttp<T>(Future<T> Function() body) =>
    HttpOverrides.runWithHttpOverrides(body, _RealHttpOverrides());

void main() {
  testWidgets(
    '_startMonitor() 가 초기 바인딩 중 겹쳐 불려도 포트는 하나만 뜬다',
    (tester) async {
      await tester.runAsync(() async {
        final session = _connectedSession();
        addTearDown(session.dispose);

        // pumpWidget 을 아직 await 하지 않은 채로 곧바로 lifecycle 이벤트를
        // 흘려보낸다. Dart 는 async 함수도 첫 await 지점까지는 동기 실행하므로,
        // `tester.pumpWidget(...)` 이 호출되는 이 한 줄만으로 이미
        // `attachRootWidget` → `initState` → `_startMonitor()` 의 동기 구간
        // (== `_monitorStarting = true` 까지)이 전부 실행된 상태다. 즉
        // `await broadcaster.start()` (실 HttpServer.bind, 아직 완료 전)에
        // 걸려 있는 게 보장된다 — `await tester.pumpWidget(...)` 로 한 번
        // 완전히 끝내고 나서 이벤트를 보내면 그 사이 실제 소켓 바인딩이 이미
        // 끝나 있어 "재진입" 이 우연히도 항상 순차 호출이 돼 가드가 없어도
        // 통과해버린다 — 그래서는 회귀를 못 잡는다.
        final pump = tester.pumpWidget(
          MaterialApp(home: GameScreen(session: session)),
        );
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        tester.binding
            .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await pump;

        await _settle(tester, const Duration(milliseconds: 500));

        final state = _stateOf(tester);
        final MonitorEndpoint? ep = state.debugMonitorEndpoint;
        expect(ep, isNotNull, reason: '모니터가 최소 한 번은 떠 있어야 한다');

        // 진짜 로컬 서버를 검증해야 하므로 이 블록 안에서만 진짜 HttpClient
        // 로 되돌린다 (_withRealHttp 독스트링 참고).
        await _withRealHttp(() async {
          // 후보 포트 전 구간(kMonitorPortFirst..Last)을 훑어 실제로 응답하는
          // 포트가 몇 개인지 센다. "바로 옆 포트만 본다"로는 부족하다 — 두
          // 서버가 동시에 뜨면 나중에 setState 한 쪽이 `_broadcaster` 필드를
          // 덮어써 [ep]는 **둘 중 아무 쪽이나** 가리킬 수 있고(먼저 뜬 쪽이
          // 오히려 낮은 포트에 남아 있을 수도 있다), 리크된 서버가 [ep] 보다
          // 낮은 포트에 있을 수도 있기 때문이다.
          final client = HttpClient();
          addTearDown(client.close);
          final reachable = <int>[];
          for (var port = kMonitorPortFirst; port <= kMonitorPortLast; port++) {
            try {
              final req = await client
                  .getUrl(Uri.parse('http://127.0.0.1:$port/?k=${ep!.token}'));
              final res = await req.close();
              if (res.statusCode == 200) reachable.add(port);
              await res.drain<void>();
            } on SocketException {
              // 아무도 없음 — 정상.
            }
          }
          expect(reachable, [ep!.port],
              reason: '가드가 없으면 두 번째 _startMonitor() 호출이 별도 포트에 '
                  '서버를 하나 더 띄우고 아무도 stop() 하지 않아 리크된다. '
                  '응답 가능한 포트가 정확히 하나(=$reachable)여야 한다.');
        });
      });
    },
  );

  testWidgets(
    'pause 후 resume 해도 방송기는 하나, MonitorSource 는 같은 인스턴스, 링버퍼는 이어진다',
    (tester) async {
      await tester.runAsync(() async {
        final session = _connectedSession();
        addTearDown(session.dispose);

        await tester.pumpWidget(
          MaterialApp(home: GameScreen(session: session)),
        );
        await _settle(tester);

        final beforeState = _stateOf(tester);
        expect(beforeState.debugMonitorEndpoint, isNotNull);
        final MonitorSource source = beforeState.debugMonitorSource;

        // MonitorSource 의 100ms 타이머가 실제로 링버퍼를 채우게 기다린다.
        await Future<void>.delayed(const Duration(milliseconds: 350));
        final framesBeforePause = source.ring.length;
        expect(framesBeforePause, greaterThan(0),
            reason: '100ms tick 타이머가 링버퍼를 채우고 있어야 한다');

        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump();
        expect(beforeState.debugMonitorEndpoint, isNull,
            reason: 'paused 면 방송기는 내려가 있어야 한다(Finding 4)');
        // 소스는 pause 중에도 같은 인스턴스다 — 재생성되면 세션 시계와
        // 60초 링버퍼가 초기화된다(_startMonitor 독스트링 참고). 이게 이
        // 파일에서 가장 깨지기 쉬운 불변조건이다.
        expect(identical(beforeState.debugMonitorSource, source), isTrue);

        // 방송기가 죽어 있는 동안에도 소스의 타이머는 계속 돈다 — 링버퍼가
        // 더 자라야 한다(줄어들거나 0으로 리셋되면 안 된다).
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(source.ring.length, greaterThanOrEqualTo(framesBeforePause));

        tester.binding
            .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await _settle(tester, const Duration(milliseconds: 500));

        final afterState = _stateOf(tester);
        expect(afterState.debugMonitorEndpoint, isNotNull,
            reason: 'resumed 후 방송기가 다시 떠야 한다');
        expect(afterState.debugHasBroadcaster, isTrue);
        expect(identical(afterState.debugMonitorSource, source), isTrue,
            reason: '방송기만 새로 뜨고 MonitorSource 는 재사용해야 한다');
      });
    },
  );

  testWidgets(
    'pause 후 resume 해도 접속 토큰은 그대로다 — 열어 둔 브라우저 탭이 403 받지 않는다',
    (tester) async {
      await tester.runAsync(() async {
        final session = _connectedSession();
        addTearDown(session.dispose);

        await tester.pumpWidget(
          MaterialApp(home: GameScreen(session: session)),
        );
        await _settle(tester);

        final state = _stateOf(tester);
        final beforeEp = state.debugMonitorEndpoint as MonitorEndpoint?;
        expect(beforeEp, isNotNull);
        final tokenBefore = beforeEp!.token;
        expect(tokenBefore, state.debugMonitorToken as String);

        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump();
        tester.binding
            .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await _settle(tester, const Duration(milliseconds: 500));

        final afterEp = state.debugMonitorEndpoint as MonitorEndpoint?;
        expect(afterEp, isNotNull);
        // 방송기(그리고 포트)는 재생성됐을 수 있지만 토큰은 위젯 수명 내내
        // 고정이어야 한다.
        expect(afterEp!.token, tokenBefore);
        expect(state.debugMonitorToken as String, tokenBefore);
      });
    },
  );

  testWidgets(
    'dispose 순서 — 소스·방송기가 예외 없이 내려가고 포트가 반환된다',
    (tester) async {
      await tester.runAsync(() async {
        final session = _connectedSession();
        addTearDown(session.dispose);

        await tester.pumpWidget(
          MaterialApp(home: GameScreen(session: session)),
        );
        await _settle(tester);

        final state = _stateOf(tester);
        final ep = state.debugMonitorEndpoint as MonitorEndpoint?;
        expect(ep, isNotNull);

        // 위젯 트리를 통째로 갈아끼워 GameScreen.dispose() 를 태운다.
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull,
            reason: 'dispose() 안 source.stop()/broadcaster.stop() 순서가 '
                '깨지면 여기서 예외가 튄다');

        // 포트가 실제로 반환됐는지 — 같은 포트에 새 서버를 바로 띄워 확인한다.
        final probe = await HttpServer.bind(InternetAddress.anyIPv4, ep!.port);
        await probe.close(force: true);
      });
    },
  );
}
