import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_app/game/data/fatigue_feed.dart';
import 'package:flutter_app/game/ui/game_screen.dart';
import 'package:flutter_app/game/ui/widgets/session_hud.dart';
import 'package:flutter_test/flutter_test.dart';

/// 아무것도 흘리지 않는 조용한 피드 — 배치만 보면 되므로 애니메이션을 안 만든다.
class _StillFeed implements FatigueFeed {
  _StillFeed(this.sigma);

  final double sigma;

  @override
  double get nowSec => 0;

  @override
  Stream<ContractionEvent> get contractions => const Stream.empty();

  @override
  Stream<double> get sigmaNow => Stream.value(sigma);

  @override
  Stream<double> get sigmaPredicted => Stream.value(sigma + 0.6);

  @override
  double get predictionHorizonSec => 30;

  @override
  double? get nextContractionEta => null;

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  @override
  void dispose() {}
}

void main() {
  /// Flame 의 글러브가 공을 받는 y 좌표(화면 높이 대비). BaseballGame 과 같은 값.
  const glovePlateRatio = 0.80;

  Future<void> pumpAt(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(home: GameScreen(feed: _StillFeed(2.4))),
    );
    // pumpAndSettle 은 쓰지 않는다 — 게임 루프가 매 프레임 다시 그려 영영 안 멈춘다.
    await tester.pump(const Duration(milliseconds: 32));
  }

  group('★ HUD 가 포구 지점을 가리지 않는다', () {
    /// 화면 중앙 아래쪽 — 공이 날아와 글러브에 잡히는 영역.
    Rect playArea(Size s) => Rect.fromLTRB(
          s.width * 0.25,
          s.height * 0.45,
          s.width * 0.75,
          s.height,
        );

    for (final size in const [
      Size(390, 844), // iPhone 세로
      Size(320, 568), // 구형 소형
      Size(900, 500), // 가로
    ]) {
      testWidgets('${size.width.toInt()}x${size.height.toInt()} — '
          'HUD 가 포구 영역을 침범하지 않는다', (tester) async {
        await pumpAt(tester, size);
        final zone = playArea(size);

        for (final finder in [
          find.byType(SessionHud),
          find.byType(FatiguePanel),
        ]) {
          expect(finder, findsOneWidget);
          final rect = tester.getRect(finder);
          expect(rect.overlaps(zone), isFalse,
              reason: '$rect 가 포구 영역 $zone 을 덮는다 — 공이 잡히는 장면이 '
                  '이 화면의 전부라 절대 가리면 안 된다');
        }
        expect(tester.takeException(), isNull, reason: '오버플로우가 나면 안 된다');
      });
    }

    testWidgets('세션 바는 좌상단, 게이지는 우상단', (tester) async {
      await pumpAt(tester, const Size(390, 844));
      final hud = tester.getRect(find.byType(SessionHud));
      final panel = tester.getRect(find.byType(FatiguePanel));
      expect(hud.left, lessThan(390 / 2));
      expect(panel.right, greaterThan(390 / 2));
      expect(hud.overlaps(panel), isFalse, reason: '두 박스가 겹치면 안 된다');
    });

    testWidgets('두 박스 모두 화면 안에 있다', (tester) async {
      await pumpAt(tester, const Size(320, 568));
      for (final f in [find.byType(SessionHud), find.byType(FatiguePanel)]) {
        final r = tester.getRect(f);
        expect(r.left, greaterThanOrEqualTo(0));
        expect(r.right, lessThanOrEqualTo(320));
      }
    });
  });
}
