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
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_app/game/ui/game_screen.dart';
import 'package:flutter_app/monitor/monitor_broadcaster.dart';
import 'package:flutter_app/monitor/monitor_source.dart';
import 'package:flutter_app/services/session_controller.dart';
import 'package:flutter_app/widgets/monitor/monitor_address_card.dart';
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

/// 후보 포트 전 구간(kMonitorPortFirst..Last)을 훑어 [token] 으로 우리
/// 프로토콜(WS 업그레이드 + hello 메시지)에 실제로 응답하는 포트 목록을
/// 돌려준다. "몇 개가 떠 있는가" 를 직접 세는 유일한 방법이다 —
/// `_broadcaster` 필드 하나만 보면 그 필드가 가리키지 않는 두 번째
/// 살아있는(또는 리크된) 서버를 놓친다.
///
/// 순수 TCP connect 로 "포트에 뭔가 있다"만 확인하는 건 부족하다 — 이
/// 파일을 `monitor_broadcaster_test.dart` 처럼 같은 포트 대역(8080..8090)
/// 을 쓰는 다른 테스트 파일과 나란히 돌리면(`flutter test` 는 기본적으로
/// 파일별로 병렬 프로세스를 띄운다), 그쪽의 "포트가 점유되면 다음 포트로
/// 넘어간다" 테스트가 8080 을 리스너 없이 그냥 bind 만 해 둔 상태로 겹칠
/// 수 있고, TCP handshake 는 그것만으로 성공해 버려 우리 서버로
/// 오인한다 — 실제로 겪었다. HTTP GET 으로 `/` 를 요청하는 것도 안 된다
/// — `/` 는 pageLoader() 를 거쳐 rootBundle.loadString() 을 부르는데, 실
/// 소켓 콜백이 자신을 낳은 테스트의 에셋 목 스코프 밖(다음 테스트로 넘어간
/// 뒤)에서 실행되면 "Unable to load asset" 이 튄다 — 이것도 실제로 겪었다.
/// `/ws` 는 `helloBuilder()` 만 거치고 자산을 전혀 안 읽으며, 토큰이
/// 맞고 우리 JSON hello 프레임이 와야만 "있다"고 센다.
Future<List<int>> _reachablePorts(String token) async {
  final reachable = <int>[];
  for (var port = kMonitorPortFirst; port <= kMonitorPortLast; port++) {
    WebSocket? ws;
    try {
      ws = await WebSocket.connect('ws://127.0.0.1:$port/ws?k=$token')
          .timeout(const Duration(milliseconds: 400));
      final first =
          await ws.first.timeout(const Duration(milliseconds: 400));
      final decoded = jsonDecode(first as String) as Map<String, dynamic>;
      if (decoded['t'] == 'hello') reachable.add(port);
    } catch (_) {
      // 아무도 없거나, 우리 프로토콜이 아니거나, 토큰이 안 맞음 — 다 '없음'.
    } finally {
      try {
        await ws?.close();
      } catch (_) {}
    }
  }
  return reachable;
}

/// 각 테스트가 끝나기 전에 위젯 트리를 치워 `GameScreen.dispose()` 를 이
/// `runAsync` 블록 **안에서** 태운다.
///
/// `dispose()` 의 `broadcaster.stop()` 은 fire-and-forget 이다(`dispose()`
/// 자체가 동기라 await 할 수 없다). 이걸 감싸지 않으면 실 소켓 종료가
/// `runAsync` 블록 밖(테스트 사이의 fake-time 구간)으로 흘러나가고, 다음
/// 테스트가 시작될 때도 이전 테스트의 서버가 아직 포트를 붙들고 있을 수
/// 있다 — 이 파일의 여러 테스트가 전 포트 대역을 실제로 스캔하는데
/// (`_reachablePorts`), 그 잔존 서버가 다음 테스트의 스캔에 잡혀 "방송기가
/// 둘"로 오판될 수 있다. 실제로 이 파일을 여러 테스트와 함께 돌리다 겪은
/// 문제다.
Future<void> _disposeAndSettle(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await Future<void>.delayed(const Duration(milliseconds: 300));
}

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

        // 후보 포트 전 구간을 훑어 실제로 응답하는 포트가 몇 개인지 센다.
        // "바로 옆 포트만 본다"로는 부족하다 — 두 서버가 동시에 뜨면 나중에
        // setState 한 쪽이 `_broadcaster` 필드를 덮어써 [ep]는 **둘 중 아무
        // 쪽이나** 가리킬 수 있고(먼저 뜬 쪽이 오히려 낮은 포트에 남아 있을
        // 수도 있다), 리크된 서버가 [ep] 보다 낮은 포트에 있을 수도 있다.
        final reachable = await _reachablePorts(ep!.token);
        expect(reachable, [ep.port],
            reason: '가드가 없으면 두 번째 _startMonitor() 호출이 별도 포트에 '
                '서버를 하나 더 띄우고 아무도 stop() 하지 않아 리크된다. '
                '응답 가능한 포트가 정확히 하나(=$reachable)여야 한다.');

        await _disposeAndSettle(tester);
      });
    },
  );

  testWidgets(
    '연속된 배경 전환 도중의 재시작 요청이 재진입 가드에 막혀도 유실되지 않는다 (회귀)',
    (tester) async {
      await tester.runAsync(() async {
        final session = _connectedSession();
        addTearDown(session.dispose);

        await tester.pumpWidget(
          MaterialApp(home: GameScreen(session: session)),
        );
        await _settle(tester);

        dynamic state() => _stateOf(tester);
        expect(state().debugMonitorEndpoint, isNotNull,
            reason: '최초 바인딩이 끝나 있어야 트레이스를 시작할 수 있다');

        // 리뷰가 지적한 정확한 트레이스를 재현한다:
        //   1) paused  — 떠 있던 방송기(B1)가 죽는다.
        //   2) resumed — 새 방송기(B2) 바인딩이 시작된다.
        //   3) paused 가 다시 껴든다 — 아직 뜨지도 않은 B2 를 좀비로 만든다.
        //   4) B2.start() 가 끝나 좀비 분기로 들어가 스스로 stop() 을
        //      시작하는 바로 그 순간.
        //   5) 그 좀비 정리가 아직 끝나지 않았을 그 순간에 resumed —
        //      재진입 가드가 이 재시작 요청을 거부하는 바로 그 창이다.
        //
        // 실 소켓 바인딩/종료 속도는 기계마다 달라("몇 ms 기다렸다 흘려보내는"
        // 폴링 방식은 이 창을 번번이 놓치거나 일찍 지나쳐 버렸다), 그래서
        // `_startMonitor`/`didChangeAppLifecycleState` 안에 심어 둔
        // 테스트 전용 훅으로 3), 5) 단계를 정확한 지점에 동기적으로
        // 끼워 넣는다 — 타이밍을 맞히는 대신 코드가 알려주는 순간에 정확히
        // 개입한다.
        final zombieHookFired = Completer<void>();
        state().debugOnBindStarting = () async {
          state().debugOnBindStarting = null; // 딱 한 번만 — B2 에만 적용
          tester.binding
              .handleAppLifecycleStateChanged(AppLifecycleState.paused); // 3)
        };
        state().debugOnZombieStopping = () async {
          state().debugOnZombieStopping = null; // 딱 한 번만
          if (!zombieHookFired.isCompleted) zombieHookFired.complete();
          tester.binding
              .handleAppLifecycleStateChanged(AppLifecycleState.resumed); // 5)
        };

        tester.binding
            .handleAppLifecycleStateChanged(AppLifecycleState.paused); // 1)
        await tester.pump();
        tester.binding
            .handleAppLifecycleStateChanged(AppLifecycleState.resumed); // 2)

        // 트레이스가 실제로 좀비 분기를 탔는지 확인한다 — 못 탔다면 이
        // 테스트가 재현하려는 상황 자체가 안 만들어진 것이므로 그 자체가
        // 테스트 결함으로 실패해야 한다(회귀와는 다른 실패).
        await zombieHookFired.future.timeout(
          const Duration(seconds: 5),
          onTimeout: () => fail('B2 가 좀비 분기를 타지 않았다 — 트레이스 재현 실패'),
        );

        // 여러 차례의 실 소켓 바인딩·종료가 끝날 시간을 넉넉히 준다.
        await _settle(tester, const Duration(milliseconds: 1500));

        final ep = state().debugMonitorEndpoint as MonitorEndpoint?;
        expect(ep, isNotNull,
            reason: '재시작 요청이 가드에 막혀 유실되면 세션 내내 여기서 죽는다 '
                '— _broadcaster 는 non-null(죽은 핸들)인데 _monitorEndpoint 는 '
                '계속 null 인 채로 남는다. 오직 또 한 번의 완전한 백그라운드 '
                '왕복만이 복구하는데, 화면이 그냥 멈춘 것처럼 보이는 치료사 '
                '입장에선 그걸 할 이유가 없다.');

        final reachable = await _reachablePorts(ep!.token);
        expect(reachable, [ep.port],
            reason: '복구된 방송기도 정확히 하나여야 한다');

        await _disposeAndSettle(tester);
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
        final MonitorEndpoint? afterEp = afterState.debugMonitorEndpoint;
        expect(afterEp, isNotNull, reason: 'resumed 후 방송기가 다시 떠야 한다');
        expect(identical(afterState.debugMonitorSource, source), isTrue,
            reason: '방송기만 새로 뜨고 MonitorSource 는 재사용해야 한다');

        // `debugHasBroadcaster` 하나만 보면 "그 필드가 non-null 이다" 밖에
        // 확인 못 한다 — 두 번째 방송기가 몰래 더 떠 있어도 이 필드는 그냥
        // 둘 중 하나를 가리킬 뿐이라 여전히 true 다. "방송기는 하나"라는
        // Finding 7 요구사항은 실제로 응답하는 포트 수를 세야만 검증된다.
        final reachable = await _reachablePorts(afterEp!.token);
        expect(reachable, [afterEp.port],
            reason: 'pause/resume 뒤에 방송기가 정확히 하나만 살아 있어야 한다 '
                '(응답 가능한 포트=$reachable)');

        await _disposeAndSettle(tester);
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

        await _disposeAndSettle(tester);
      });
    },
  );

  testWidgets(
    '관찰 주소 트리거 → 다이얼로그 → 복사하면 스낵바가 뜬다 (모달 배리어에 가려지지 않는다)',
    (tester) async {
      await tester.runAsync(() async {
        final session = _connectedSession();
        addTearDown(session.dispose);

        await tester.pumpWidget(
          MaterialApp(home: GameScreen(session: session)),
        );
        await _settle(tester);
        expect(_stateOf(tester).debugMonitorEndpoint, isNotNull);

        await tester.tap(find.byIcon(Icons.desktop_windows_outlined));
        // pumpAndSettle 은 쓰지 않는다 — Flame 의 게임 루프가 매 프레임
        // 다시 그려 영영 settle 되지 않는다(game_screen_layout_test.dart 와
        // 같은 이유). 다이얼로그 전환 애니메이션이 끝날 만큼만 고정 시간을 편다.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byType(MonitorAddressCard), findsOneWidget,
            reason: '트리거를 탭하면 카드가 다이얼로그로 펼쳐져야 한다');

        await tester.tap(find.byIcon(Icons.copy));
        await tester.pump(); // 스낵바가 애니메이션을 시작하는 프레임

        // 다이얼로그 안에 ScaffoldMessenger 만 있고 그 밑에 실제로 등록할
        // Scaffold 가 없으면 ScaffoldMessengerState.showSnackBar 가
        // "no descendant Scaffolds to present to" assert 로 죽는다 —
        // 이 자체가 실제로 겪은 회귀였다(Material 로만 감쌌을 때 재현됨).
        expect(tester.takeException(), isNull,
            reason: '복사 버튼을 누르면 예외 없이 스낵바가 떠야 한다');
        expect(find.text('주소를 복사했습니다'), findsOneWidget,
            reason: '스낵바가 앱 최상위 ScaffoldMessenger 로 가면 이 다이얼로그의 '
                '모달 배리어 아래에 그려져 트리는 갖고 있어도 사용자 눈엔 안 '
                '보였다 — 로컬 ScaffoldMessenger+Scaffold 로 감싸야 실제로 뜬다');

        // 다이얼로그가 열려 있는 채로 위젯을 치운다 — Navigator 가 다이얼로그
        // 라우트까지 함께 정리해야 한다.
        await _disposeAndSettle(tester);
      });
    },
  );

  testWidgets(
    '다이얼로그가 열려 있는 동안 배경 전환이 오면 다이얼로그 내용도 즉시 갱신된다',
    (tester) async {
      await tester.runAsync(() async {
        final session = _connectedSession();
        addTearDown(session.dispose);

        await tester.pumpWidget(
          MaterialApp(home: GameScreen(session: session)),
        );
        await _settle(tester);

        await tester.tap(find.byIcon(Icons.desktop_windows_outlined));
        // pumpAndSettle 은 쓰지 않는다 — Flame 의 게임 루프가 매 프레임
        // 다시 그려 영영 settle 되지 않는다(game_screen_layout_test.dart 와
        // 같은 이유). 다이얼로그 전환 애니메이션이 끝날 만큼만 고정 시간을 편다.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.textContaining('모니터 비활성'), findsNothing,
            reason: '아직 살아 있으니 비활성 문구가 없어야 한다');

        tester.binding
            .handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump();

        // 다이얼로그는 GameScreen 과 별개의 라우트라 GameScreen 의 setState
        // 로는 재빌드되지 않는다. ValueListenableBuilder 로 endpoint 를 직접
        // 구독하지 않았다면, 다이얼로그를 닫았다 다시 열기 전까지 죽은 주소를
        // 계속 보여줬을 것이다.
        expect(find.textContaining('모니터 비활성'), findsOneWidget,
            reason: '다이얼로그를 새로 열지 않아도 배경 전환이 즉시 반영돼야 한다');

        await _disposeAndSettle(tester);
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
