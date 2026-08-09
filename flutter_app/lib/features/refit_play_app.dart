import 'package:flutter/material.dart';

import 'refit_theme.dart';
import 'shell/refit_shell.dart';

/// RE-FIT Play — 환자 앱 진입점.
///
/// 화면 구조는 `docs/MENU_STRUCTURE.md` 가 정본이다. 진입하면 [RefitShell]
/// 이 하단 3탭(홈·운동·설정)을 세우고, 환자가 정해지지 않았거나 마비
/// 유형이 비어 있으면 탭 바깥의 환자 선택 화면을 먼저 보여 준다.
class RefitPlayApp extends StatelessWidget {
  const RefitPlayApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'RE-FIT Play',
      debugShowCheckedModeBanner: false,
      theme: RefitTheme.material,
      home: const RefitShell(),
    );
  }
}
