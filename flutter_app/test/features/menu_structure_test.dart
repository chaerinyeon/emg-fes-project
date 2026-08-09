import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'package:flutter_app/core/subject_category.dart';
import 'package:flutter_app/data/local/session_store.dart';
import 'package:flutter_app/features/app_state.dart';
import 'package:flutter_app/features/history/session_detail_screen.dart';
import 'package:flutter_app/features/refit_theme.dart';
import 'package:flutter_app/features/report/report_screen.dart';
import 'package:flutter_app/features/shell/refit_shell.dart';
import 'package:flutter_app/services/profile_service.dart';
import 'package:flutter_app/session/end_conditions.dart';

/// `docs/MENU_STRUCTURE.md` 가 화면으로 실제로 서는지 본다.
///
/// 여기서 지키는 것은 구조와 **하드 제약**이다 — 4탭이 있는가, TEST 가 모든
/// 탭에서 닿는가, 마비 유형 없이 훈련에 들어갈 수 없는가, 환자 화면에
/// 퍼센트가 새지 않는가.
///
/// ★ Hive 쓰기는 반드시 [setUp] 이나 `tester.runAsync` 안에서 한다.
/// `testWidgets` 본문은 fake-async 존이라 디스크 flush 를 기다리는 Future 가
/// **영영 완결되지 않는다** — 테스트가 실패하는 게 아니라 멈춘다.
SessionSummary _session({
  String id = 's1',
  required String patientId,
  SessionEndReason endReason = SessionEndReason.userStop,
  int repCount = 340,
}) =>
    SessionSummary(
      id: id,
      patientId: patientId,
      deviceId: 'd1',
      startedAt: DateTime.now().subtract(const Duration(minutes: 20)),
      endedAt: DateTime.now(),
      durationS: 558,
      gameId: 'fishing',
      stageId: 's1',
      intensityLevel: 3,
      endReason: endReason,
      repCount: repCount,
      successRate: 0.8,
      maxFatigue: 27.4,
      endFatigue: 18,
      onsetS: 372,
      burstCount: 340,
      detectRate: 0.95,
      eventsPerBurstMedian: 19,
      levelChangeCount: 2,
      reliabilityGrade: 'A',
      stimPeriodMs: 1619,
      appVersion: '1.0.0',
      fwVersion: 'fw',
    );

List<String> allText(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((t) => t.data ?? '')
    .toList();

Future<void> pumpShell(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(theme: RefitTheme.material, home: const RefitShell()),
  );
  await tester.pump();
}

void main() {
  late Directory dir;
  late UserProfile patient;

  /// 마비 유형까지 채운 환자를 세운다. setUp 은 실제 async 존이라
  /// Hive 쓰기가 정상적으로 끝난다.
  Future<void> giveParalysisType(SubjectCategory type) async {
    patient = gApp.patients.first
      ..category = type
      ..age = 54
      ..name = '김재활';
    await gApp.savePatient(patient);
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('refit_menu_test');
    Hive.init(dir.path);
    await gProfileService.init();
    await gApp.init();
    patient = gApp.patients.first;
  });

  tearDown(() async {
    gApp.live = null;
    await Hive.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  group('최초 진입 — 마비 유형은 라벨이 아니라 분석 경로 스위치다', () {
    testWidgets('유형이 비어 있으면 탭이 아니라 환자 화면이 뜬다', (tester) async {
      // ProfileService 가 만든 기본 프로파일에는 마비 유형이 없다.
      expect(gApp.patientReady, isFalse);

      await pumpShell(tester);

      expect(find.text('＋ 환자 추가'), findsOneWidget);
      expect(find.text('홈'), findsNothing, reason: '탭 바깥의 화면이어야 한다');
    });

    testWidgets('유형을 채우면 4탭이 선다', (tester) async {
      await tester.runAsync(() => giveParalysisType(SubjectCategory.complete));
      expect(gApp.patientReady, isTrue);

      await pumpShell(tester);

      for (final tab in ['홈', '운동', '기록', '설정']) {
        expect(find.text(tab), findsOneWidget, reason: '$tab 탭이 있어야 한다');
      }
    });
  });

  group('TEST 는 모든 탭에서 닿는다', () {
    testWidgets('네 탭 전부에서 AppBar 우측에 TEST 가 있다', (tester) async {
      await tester
          .runAsync(() => giveParalysisType(SubjectCategory.incomplete));
      await pumpShell(tester);

      for (final tab in ['홈', '운동', '기록', '설정']) {
        await tester.tap(find.text(tab));
        await tester.pump();
        expect(find.text('TEST'), findsOneWidget, reason: '$tab 탭에서도 닿아야 한다');
      }
    });

    testWidgets('BLE 없이 열리고, 자극을 쏘는 항목만 잠겨 있다', (tester) async {
      await tester.runAsync(() => giveParalysisType(SubjectCategory.complete));
      await pumpShell(tester);

      await tester.tap(find.text('TEST'));
      await tester.pumpAndSettle();

      expect(find.text('화면 확인'), findsOneWidget);
      expect(find.text('센서 확인'), findsOneWidget);
      expect(find.text('자극기 확인'), findsOneWidget);
      // 살아 있는 세션이 없으므로 자극 항목은 잠겨 있어야 한다.
      expect(gApp.live, isNull);
      expect(find.text('부착 확인을 통과한 뒤에 열려요'), findsOneWidget);
    });
  });

  group('운동 탭 — 게이트는 버튼 비활성화가 아니라 상태머신이다', () {
    testWidgets('연결 전에는 확인·측정·시작이 모두 잠겨 있다', (tester) async {
      // 사전 세팅은 카드 세 장짜리라 기본 테스트 화면(800×600)에서는 아래쪽이
      // 빌드되지 않는다. 세 버튼을 한 번에 보려고 화면을 키운다.
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.runAsync(() => giveParalysisType(SubjectCategory.complete));
      await pumpShell(tester);

      await tester.tap(find.text('운동'));
      await tester.pump();

      for (final label in ['확인 시작', '이 세기로 측정', '운동 시작']) {
        final b = tester.widget<RefitButton>(
          find.widgetWithText(RefitButton, label),
        );
        expect(b.onPressed, isNull, reason: '"$label" 이 눌리면 안 된다');
      }
    });

    testWidgets('강도 화면이 events/burst 수치를 노출하지 않는다', (tester) async {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.runAsync(() => giveParalysisType(SubjectCategory.complete));
      await pumpShell(tester);
      await tester.tap(find.text('운동'));
      await tester.pump();

      for (final t in allText(tester)) {
        expect(t, isNot(contains('%')), reason: '"$t"');
        expect(t, isNot(contains('events')), reason: '"$t"');
      }
      // 신호 상태는 숫자가 아니라 문장으로만 말한다.
      expect(find.text('기기 다이얼을 이 단계에 맞춰 주세요.'), findsOneWidget);
    });
  });

  group('홈 — 퍼센트를 쓰지 않는다', () {
    testWidgets('오늘의 상태는 3단계 상태로만 말한다', (tester) async {
      await tester.runAsync(() async {
        await giveParalysisType(SubjectCategory.complete);
        await gApp.store.saveSession(_session(
          patientId: patient.id,
          endReason: SessionEndReason.fatigueThreshold,
        ));
        await gApp.reloadSessions();
      });

      await pumpShell(tester);

      for (final t in allText(tester)) {
        expect(t, isNot(contains('%')), reason: '환자 화면에 퍼센트는 없다: "$t"');
      }
      expect(find.text('피로'), findsOneWidget);
      expect(find.textContaining('오늘 1회 완료'), findsOneWidget);
    });
  });

  group('기록 탭 — 치료사·보호자의 화면', () {
    testWidgets('세션 카드에서 세부 기록으로 들어간다', (tester) async {
      await tester.runAsync(() async {
        await giveParalysisType(SubjectCategory.complete);
        await gApp.store.saveSession(_session(patientId: patient.id));
        await gApp.store.appendBursts([
          for (var i = 0; i < 40; i++)
            BurstRow(
              sessionId: 's1',
              tS: i * 1.618,
              p2p: 1000 - i * 8.0,
              fatigue: i.toDouble(),
              contractionOk: i % 4 != 0,
              valid: true,
              rms: 300 - i.toDouble(),
              mdf: 64 - i * 0.2,
            ),
        ]);
        await gApp.reloadSessions();
      });

      await pumpShell(tester);
      await tester.tap(find.text('기록'));
      await tester.pump();

      expect(find.textContaining('340번'), findsOneWidget);

      await tester.tap(find.textContaining('340번'));
      await tester.pumpAndSettle();

      expect(find.byType(SessionDetailScreen), findsOneWidget);
      // 여기서는 지표를 감추지 않는다 — 다만 무엇이 근거인지 구분해 준다.
      expect(find.text('M-wave 진폭'), findsOneWidget);
      expect(find.text('★ 피로 판정의 근거'), findsOneWidget);
      expect(find.text('RMS'), findsOneWidget);
      expect(find.text('MDF'), findsOneWidget);
      expect(find.text('관찰용 — 판정에 쓰지 않는다'), findsNWidgets(2));
    });
  });

  group('환자 개념 이전 기록이 사라지지 않는다', () {
    // 앱에 환자가 없던 시절 세션은 patient_id = 'local' 로 저장됐다.
    // 기록 탭이 선택된 환자로 목록을 좁히면서 그 기록이 통째로 사라졌다.
    //
    // 맞추는 방향이 중요하다 — 고치는 것은 **프로파일 id** 이지 기록이
    // 아니다. `sessions.patient_id` 는 서버와 공유하는 값이라 앱이 다시
    // 쓰면 이미 업로드된 것과 어긋난다.
    testWidgets('환자가 한 명이면 프로파일 id 를 기록에 맞춘다', (tester) async {
      late String idBefore;
      await tester.runAsync(() async {
        idBefore = gApp.patients.single.id;
        await gApp.store.saveSession(_session(patientId: 'local'));
        await gApp.reloadSessions();
        expect(gApp.unassignedSessions, hasLength(1));

        // 앱을 다시 켠 것과 같다.
        await gApp.init();
      });

      expect(idBefore, isNot('local'));
      expect(gApp.patient!.id, 'local', reason: '이전 환자 id 와 같아져야 한다');
      expect(gApp.unassignedSessions, isEmpty);
      expect(gApp.patientSessions, hasLength(1));

      // 기록 자체는 손대지 않았다.
      final stored = await tester.runAsync(() => gApp.store.session('s1'));
      expect(stored!.patientId, 'local');
      expect(stored.synced, isFalse);
    });

    testWidgets('환자가 여럿이면 추측하지 않고 미지정으로 남긴다', (tester) async {
      await tester.runAsync(() async {
        await gApp.savePatient(UserProfile(
          id: 'p_second',
          name: '다른 환자',
          age: 61,
          category: SubjectCategory.incomplete,
        ));
        await gApp.store.saveSession(_session(patientId: 'local'));
        await gApp.reloadSessions();
        await gApp.init();
      });

      expect(gApp.unassignedSessions, hasLength(1),
          reason: '남의 이름에 붙이느니 미지정으로 둔다');
      expect(gApp.patientSessions, isEmpty);
    });

    testWidgets('이미 자기 기록이 있으면 id 를 옮기지 않는다', (tester) async {
      await tester.runAsync(() async {
        await giveParalysisType(SubjectCategory.complete);
        await gApp.store.saveSession(_session(patientId: 'local'));
        await gApp.store.saveSession(
          _session(id: 's2', patientId: patient.id),
        );
        await gApp.reloadSessions();
        await gApp.init();
      });

      expect(gApp.patient!.id, isNot('local'),
          reason: 'id 를 옮기면 새 기록이 주인을 잃는다');
      expect(gApp.patientSessions, hasLength(1));
      expect(gApp.unassignedSessions, hasLength(1));
    });

    testWidgets('기록 탭이 비었을 때 미지정 기록을 알리고 이어받을 수 있다', (tester) async {
      await tester.runAsync(() async {
        await giveParalysisType(SubjectCategory.complete);
        await gApp.savePatient(UserProfile(
          id: 'p_second',
          name: '다른 환자',
          age: 61,
          category: SubjectCategory.incomplete,
        ));
        await gApp.store.saveSession(_session(patientId: 'local'));
        await gApp.reloadSessions();
      });

      await pumpShell(tester);
      await tester.tap(find.text('기록'));
      await tester.pump();

      expect(find.text('환자가 지정되지 않은 기록 1건'), findsOneWidget);

      final moved =
          await tester.runAsync(() => gApp.claimUnassignedSessions());
      await tester.pump();

      expect(moved, 1);
      expect(gApp.patient!.id, 'local');
      expect(gApp.patientSessions, hasLength(1));
    });
  });

  group('결과 화면 — 임상 지표는 치료사 보기 뒤에 있다', () {
    testWidgets('기본 상태에는 퍼센트도 그래프도 없다', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: RefitTheme.material,
        home: const ReportScreen(
          repCount: 340,
          durationS: 558,
          endReason: SessionEndReason.fatigueThreshold,
          successRate: 0.8,
          fatigueOnsetS: 372,
          detail: ReportDetail(
            avgRms: 280,
            avgMdf: 61,
            detectRate: 0.95,
            eventsPerBurst: 19,
            grade: 'A',
            levelChangeCount: 2,
            p2pTrend: [900, 880, 860, 840],
            therapistViewOpens: 0,
          ),
        ),
      ));
      await tester.pump();

      for (final t in allText(tester)) {
        expect(t, isNot(contains('%')));
      }
      expect(find.text('평균 RMS'), findsNothing);
      // 성공률은 퍼센트가 아니라 비율 문장으로 말한다.
      expect(find.textContaining('10번 중 8번'), findsOneWidget);
      expect(find.textContaining('힘이 줄기 시작했어요'), findsOneWidget);
    });

    testWidgets('치료사 보기를 열면 관찰 지표가 나온다', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: RefitTheme.material,
        home: const ReportScreen(
          repCount: 340,
          durationS: 558,
          endReason: SessionEndReason.userStop,
          successRate: 0.8,
          detail: ReportDetail(
            avgRms: 280,
            avgMdf: 61,
            detectRate: 0.95,
            eventsPerBurst: 19,
            grade: 'A',
            levelChangeCount: 2,
            p2pTrend: [900, 880, 860, 840],
            therapistViewOpens: 1,
          ),
        ),
      ));
      await tester.pump();

      await tester.tap(find.text('치료사 보기'));
      await tester.pumpAndSettle();

      expect(find.text('평균 RMS'), findsOneWidget);
      expect(find.text('평균 MDF'), findsOneWidget);
      expect(find.text('신뢰도 등급'), findsOneWidget);
    });
  });
}
