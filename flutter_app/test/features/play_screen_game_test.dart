import 'package:flame/game.dart';
import 'package:flutter_app/game/flame/baseball_game.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_app/features/play/play_screen.dart';
import 'package:flutter_app/features/refit_theme.dart';

import '../support/fake_link.dart';
import 'ui_constraints_test.dart' show playingOrchestrator, settle;

void main() {
  late FakeLink link;
  setUp(() => link = FakeLink());
  tearDown(() async => link.dispose());

  group('훈련 화면의 본체는 게임이다', () {
    testWidgets('훈련 화면에 게임이 올라간다', (tester) async {
      final o = await playingOrchestrator(link);
      await tester.pumpWidget(MaterialApp(
          theme: RefitTheme.material, home: PlayScreen(orchestrator: o)));
      await settle(tester, o);

      expect(find.byType(GameWidget<BaseballGame>), findsOneWidget);
    });

    testWidgets('게임이 화면의 대부분을 차지한다', (tester) async {
      final o = await playingOrchestrator(link);
      await tester.pumpWidget(MaterialApp(
          theme: RefitTheme.material, home: PlayScreen(orchestrator: o)));
      await settle(tester, o);

      final screen = tester.getSize(find.byType(MaterialApp));
      final game = tester.getSize(find.byType(GameWidget<BaseballGame>));
      expect(game.height, greaterThan(screen.height * 0.7),
          reason: '게임이 곁들이가 아니라 화면 자체여야 한다');
      expect(game.width, closeTo(screen.width, 1));
    });

    testWidgets('게임 위에서도 중단 버튼이 하단 ⅓ 안에 있다', (tester) async {
      final o = await playingOrchestrator(link);
      await tester.pumpWidget(MaterialApp(
          theme: RefitTheme.material, home: PlayScreen(orchestrator: o)));
      await settle(tester, o);

      final screen = tester.getSize(find.byType(MaterialApp)).height;
      expect(tester.getTopLeft(find.text('오늘은 여기까지')).dy,
          greaterThan(screen * 2 / 3));
    });
  });
}
