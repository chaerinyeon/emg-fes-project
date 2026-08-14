import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_app/features/monitor_service.dart';

/// `initState` 에서 [MonitorService] 를 건드리는 화면.
///
/// 훈련 화면([RefitPlayFlow])이 하는 일과 같은 모양이다 — 새 라우트가 마운트되면
/// `initState` 가 서비스를 붙였다 뗀다. `initState` 는 **빌드 단계 안**에서 돈다.
class _TouchOnInit extends StatefulWidget {
  const _TouchOnInit({required this.onInit});

  final VoidCallback onInit;

  @override
  State<_TouchOnInit> createState() => _TouchOnInitState();
}

class _TouchOnInitState extends State<_TouchOnInit> {
  @override
  void initState() {
    super.initState();
    widget.onInit();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

void main() {
  group('빌드 도중에 난 알림', () {
    testWidgets('다른 가지의 구독자를 깨뜨리지 않는다', (tester) async {
      final monitor = MonitorService();
      addTearDown(monitor.dispose);

      var builds = 0;

      // 구독자는 훈련 화면과 **다른 가지**에 있다. 실제로는 설정 탭의
      // ListenableBuilder 인데, 탭이 IndexedStack 이라 안 보여도 살아 있다.
      Widget tree({bool withScreen = false}) => MaterialApp(
            home: Column(
              children: [
                ListenableBuilder(
                  listenable: monitor,
                  builder: (_, _) {
                    builds++;
                    return const SizedBox.shrink();
                  },
                ),
                if (withScreen)
                  // detachSession 은 **동기**다. disable 은 async 라
                  // await 지점에서 끊겨 알림이 빌드 밖으로 새 나간다 —
                  // 그러면 이 회귀 테스트가 아무것도 못 잡는다.
                  _TouchOnInit(onInit: monitor.detachSession),
              ],
            ),
          );

      await tester.pumpWidget(tree());

      // 훈련 화면이 붙는다. 예전에는 여기서
      // "setState() or markNeedsBuild() called during build" 로 터졌다 —
      // 빌드 중에 이미 지나친 가지를 더럽혔기 때문이다.
      await tester.pumpWidget(tree(withScreen: true));
      expect(tester.takeException(), isNull);

      // 알림이 사라지지도 않아야 한다. 미룬 것은 한 프레임뿐이다.
      final afterMount = builds;
      await tester.pump();
      expect(builds, afterMount + 1,
          reason: '미뤄 둔 알림이 다음 프레임에 도착해야 한다');
    });

    testWidgets('빌드 밖에서는 그 자리에서 알린다', (tester) async {
      final monitor = MonitorService();
      addTearDown(monitor.dispose);

      var builds = 0;
      await tester.pumpWidget(MaterialApp(
        home: ListenableBuilder(
          listenable: monitor,
          builder: (_, _) {
            builds++;
            return const SizedBox.shrink();
          },
        ),
      ));

      final before = builds;
      monitor.detachSession(); // 빌드 단계가 아니다 — 버튼 탭·타이머와 같은 자리
      await tester.pump();
      expect(builds, before + 1);
    });
  });
}
