import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_app/ble/stim_controller.dart';
import 'package:flutter_app/data/local/session_store.dart';
import 'package:flutter_app/features/intensity_wizard/intensity_wizard_screen.dart';
import 'package:flutter_app/features/play/play_screen.dart';
import 'package:flutter_app/features/refit_theme.dart';
import 'package:flutter_app/features/report/report_screen.dart';
import 'package:flutter_app/features/session/session_orchestrator.dart';
import 'package:flutter_app/session/end_conditions.dart';
import 'package:flutter_app/session/session_controller.dart';
import 'package:flutter_app/signal/constants.dart';
import 'package:flutter_app/signal/fatigue_engine.dart' show HandState;

import '../support/fake_link.dart';

/// 타이머를 켜지 않고 playing 상태까지 데려간다 (위젯 테스트용).
Future<SessionOrchestrator> playingOrchestrator(FakeLink link) async {
  final o = SessionOrchestrator(
    link: link,
    store: InMemorySessionStore(),
    sessionId: 's1',
    patientId: 'p1',
    deviceId: 'd1',
  );
  await o.machine.begin();
  o.machine.onLinkConnected();
  o.machine.submitAttachmentCheck(const AttachmentCheck(
      emgElectrodeOk: true, stimPadOk: true, deviceOk: true));
  o.machine.submitIntensity(level: 3, eventsPerBurst: 18);
  o.machine.onSyncProgress(kSyncWindowS + 1.0);
  return o;
}

/// 자극이 켜지길 기다렸다가 끈다.
///
/// syncing 에 들어가면 조립부가 자극을 켜고, StimController 가 170초짜리
/// 상한 타이머를 건다. testWidgets 는 살아 있는 타이머를 실패로 본다.
/// stop() 은 첫 await 이전에 타이머를 동기적으로 취소하므로 await 하지 않아도
/// 된다(fake-async 존에서는 StreamController.close 가 완결되지 않는다).
Future<void> settle(WidgetTester tester, SessionOrchestrator o) async {
  await tester.pump();
  unawaited(o.stim.stop(reason: StimStopReason.sessionEnd));
  await tester.pump();
}

/// 화면에 그려진 모든 Text 를 모은다.
List<String> allText(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((t) => t.data ?? '')
    .toList();

void main() {
  late FakeLink link;
  setUp(() => link = FakeLink());
  tearDown(() async => link.dispose());

  group('완료 기준 — 피로도 퍼센트는 앱 어디에도 없다', () {
    testWidgets('훈련 화면에 %가 없다', (tester) async {
      final o = await playingOrchestrator(link);
      for (var i = 0; i < 40; i++) {
        await o.machine.onBurst(
            fatiguePct: 45 + i.toDouble(),
            contractionOk: i % 3 != 0,
            reliable: true,
            tSeconds: 40 + i * 1.618);
      }

      await tester.pumpWidget(MaterialApp(
          theme: RefitTheme.material,
          home: PlayScreen(orchestrator: o)));
      await settle(tester, o);

      final texts = allText(tester);
      expect(texts, isNotEmpty);
      for (final t in texts) {
        expect(t, isNot(contains('%')),
            reason: '피로도 퍼센트는 웹(치료사)에만 있어야 한다: "$t"');
      }
    });

    testWidgets('종료 화면에 %도 그래프도 없다', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: RefitTheme.material,
        home: const ReportScreen(
          repCount: 340,
          durationS: 558,
          endReason: SessionEndReason.fatigueThreshold,
        ),
      ));
      await tester.pump();

      for (final t in allText(tester)) {
        expect(t, isNot(contains('%')));
      }
    });

    testWidgets('강도 마법사가 events/burst 수치를 노출하지 않는다', (tester) async {
      final o = await playingOrchestrator(link);
      await tester.pumpWidget(MaterialApp(
          theme: RefitTheme.material,
          home: IntensityWizardScreen(orchestrator: o)));
      await settle(tester, o);

      for (final t in allText(tester)) {
        expect(t, isNot(contains('%')));
        expect(t, isNot(contains('events')));
      }
    });
  });

  group('한 손 조작', () {
    testWidgets('중단 버튼이 상시 노출된다', (tester) async {
      final o = await playingOrchestrator(link);
      await tester.pumpWidget(MaterialApp(
          theme: RefitTheme.material,
          home: PlayScreen(orchestrator: o)));
      await settle(tester, o);

      expect(find.text('오늘은 여기까지'), findsOneWidget);
    });

    testWidgets('주요 버튼이 화면 하단 ⅓ 안에 있다', (tester) async {
      final o = await playingOrchestrator(link);
      await tester.pumpWidget(MaterialApp(
          theme: RefitTheme.material,
          home: PlayScreen(orchestrator: o)));
      await settle(tester, o);

      final screen = tester.getSize(find.byType(MaterialApp)).height;
      final stopTop = tester.getTopLeft(find.text('오늘은 여기까지')).dy;
      expect(stopTop, greaterThan(screen * 2 / 3),
          reason: '한 손으로 닿아야 한다');
    });

    testWidgets('버튼 높이가 최소 44pt 이상이다', (tester) async {
      expect(RefitTheme.touchMin, greaterThanOrEqualTo(44.0));

      final o = await playingOrchestrator(link);
      await tester.pumpWidget(MaterialApp(
          theme: RefitTheme.material,
          home: PlayScreen(orchestrator: o)));
      await settle(tester, o);

      for (final b in tester.widgetList<RefitButton>(
          find.byType(RefitButton))) {
        final size = tester.getSize(find.byWidget(b));
        expect(size.height, greaterThanOrEqualTo(44.0));
      }
    });
  });

  group('실패를 연출하지 않는다', () {
    testWidgets('수축 실패 문구가 화면에 없다', (tester) async {
      final o = await playingOrchestrator(link);
      o.hand = HandState.failedContraction;

      await tester.pumpWidget(MaterialApp(
          theme: RefitTheme.material,
          home: PlayScreen(orchestrator: o)));
      await settle(tester, o);

      for (final t in allText(tester)) {
        for (final bad in ['실패', '놓침', '실수', '틀렸']) {
          expect(t, isNot(contains(bad)), reason: '"$t" 에 실패 표현이 있다');
        }
      }
    });

    testWidgets('피로로 끝나도 "오늘 목표 달성"의 언어를 쓴다', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: RefitTheme.material,
        home: const ReportScreen(
          repCount: 340,
          durationS: 558,
          endReason: SessionEndReason.fatigueThreshold,
        ),
      ));
      await tester.pump();

      for (final t in allText(tester)) {
        for (final bad in ['실패', '중단됨', '한계', '초과']) {
          expect(t, isNot(contains(bad)), reason: '"$t"');
        }
      }
      expect(find.textContaining('오늘 몫을 다 했어요'), findsOneWidget);
    });

    testWidgets('기기 문제로 멈춘 것은 환자 탓으로 들리지 않게 알린다', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: RefitTheme.material,
        home: const ReportScreen(
          repCount: 120,
          durationS: 200,
          endReason: SessionEndReason.deviceDisconnect,
        ),
      ));
      await tester.pump();

      expect(find.textContaining('기기 연결이 끊겨'), findsOneWidget);
    });
  });

  group('종료 화면은 3줄이다', () {
    testWidgets('횟수 · 시간 · 내일로 잇는 말', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: RefitTheme.material,
        home: const ReportScreen(
          repCount: 340,
          durationS: 558,
          endReason: SessionEndReason.gameComplete,
        ),
      ));
      await tester.pump();

      expect(find.text('340'), findsOneWidget);
      expect(find.text('번 쥐었어요'), findsOneWidget);
      expect(find.textContaining('9분 18초'), findsOneWidget);
    });
  });
}
