import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'package:flutter_app/core/subject_category.dart';
import 'package:flutter_app/features/app_state.dart';
import 'package:flutter_app/features/refit_theme.dart';
import 'package:flutter_app/features/setup/setup_screen.dart';
import 'package:flutter_app/services/profile_service.dart';

/// 운동 탭의 「운동 시작」이 **처음부터 눌린다.**
///
/// 예전에는 연결 → 부착 확인 → 강도 측정을 위에서부터 손으로 하나씩 눌러야
/// 버튼이 열렸다. 준비가 덜 끝났다는 이유로 버튼을 잠가 두면 화면은 어디가
/// 막혔는지 말해 주지 않는다 — 회색 버튼만 남는다.
///
/// ★ Hive 쓰기는 [setUp] 안에서 한다. `testWidgets` 본문은 fake-async 존이라
/// 디스크 flush 를 기다리는 Future 가 영영 완결되지 않는다.
RefitButton _startButton(WidgetTester tester) =>
    tester.widgetList<RefitButton>(find.byType(RefitButton)).last;

Future<void> pumpSetup(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: RefitTheme.material,
      home: Scaffold(
        body: SetupScreen(onSessionFinished: () {}),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('refit_setup_start_test');
    Hive.init(dir.path);
    await gProfileService.init();
    await gApp.init();
    // 기기 없이 도는 환경. 실기기를 찾으러 나가면 테스트가 BLE 를 탄다.
    await gApp.settings.setSyntheticMode(true);
    final p = gApp.patients.first
      ..category = SubjectCategory.incomplete
      ..age = 54
      ..name = '김재활';
    await gApp.savePatient(p);
  });

  tearDown(() async {
    gApp.live = null;
    await Hive.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  group('운동 시작 버튼 — 준비가 덜 돼도 눌린다', () {
    testWidgets('연결도 측정도 하지 않은 첫 화면에서 이미 눌린다', (tester) async {
      await pumpSetup(tester);

      final btn = _startButton(tester);
      expect(btn.label, '운동 시작');
      expect(btn.onPressed, isNotNull,
          reason: '회색 버튼만 남으면 어디가 막혔는지 화면이 말해 주지 않는다');
    });

    // 버튼을 **누른 뒤**의 자동 진행은 여기서 덮지 못한다.
    //
    // `_prepareThenStart` 의 첫 걸음인 `_connect` 가 안에서
    // `gApp.settings.setLastDeviceName/setLastError` 로 Hive 에 쓰는데,
    // `testWidgets` 본문은 fake-async 존이라 그 디스크 flush 가 영영
    // 완결되지 않는다 — 테스트가 실패하는 게 아니라 멈춘다. `runAsync` 로
    // 감싸면 이번엔 그 안에서 `pump` 를 못 한다.
    //
    // 대신 우회가 실제로 통하는지는 상태머신 쪽에서 본다:
    // `test/session/session_controller_test.dart` 의 '수동 통과' 그룹.
  });
}
