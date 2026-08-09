import 'package:flutter/material.dart';

import '../app_state.dart';
import '../history/history_tab.dart';
import '../home/home_tab.dart';
import '../patients/patient_select_screen.dart';
import '../refit_theme.dart';
import '../settings/settings_tab.dart';
import '../setup/setup_screen.dart';
import '../test/test_sheet.dart';

/// 앱 셸 — 하단 네비게이션 4탭과 상시 노출되는 `TEST` 버튼.
///
/// ```
/// ├─ [최초 진입] 환자 선택        ← 탭 바깥. 마비 유형이 정해지기 전까지.
/// └─ 하단 네비게이션 (4탭)
///     ├─ ① 홈    ② 운동    ③ 기록    ④ 설정
/// ```
///
/// ## 탭이 사라지는 구간
///
/// 훈련이 **시작된 뒤에는 하단 탭이 숨는다.** `Setup → Game → Result` 는
/// 단방향 흐름이라, 중간에 다른 탭으로 빠져나가면 자극이 켜진 채 화면만
/// 바뀐다. 그래서 훈련은 탭 위로 올라오는 전체 화면 라우트로 열리고,
/// 결과 화면에서 `마치기` 를 눌러야 탭이 돌아온다.
class RefitShell extends StatefulWidget {
  const RefitShell({super.key});

  @override
  State<RefitShell> createState() => _RefitShellState();
}

class _RefitShellState extends State<RefitShell> {
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    gApp.addListener(_onAppChange);
  }

  @override
  void dispose() {
    gApp.removeListener(_onAppChange);
    super.dispose();
  }

  void _onAppChange() {
    if (mounted) setState(() {});
  }

  void _goTo(int tab) => setState(() => _tab = tab);

  @override
  Widget build(BuildContext context) {
    // 마비 유형이 없으면 훈련에 들어갈 수 없다 — 피로 판정에 어떤 지표를
    // 쓸지가 그 값에서 갈리기 때문이다. 그래서 탭 바깥에서 먼저 묻는다.
    if (!gApp.patientReady) {
      return const PatientSelectScreen(dismissible: false);
    }

    final tabs = [
      HomeTab(onStart: () => _goTo(1)),
      SetupScreen(onSessionFinished: () => _goTo(0)),
      const HistoryTab(),
      SettingsTab(onGoToSetup: () => _goTo(1)),
    ];

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleSpacing: 20,
        title: Text(
          gApp.patient?.name ?? 'RE-FIT',
          style: RefitTheme.bodySmall.copyWith(
            color: RefitTheme.ink,
            fontWeight: FontWeight.w600,
          ),
        ),
        actions: [
          // BLE 연결이 없어도 동작한다. 게이트 우회로는 아니다 — 실제
          // 자극을 쏘는 항목만 부착 확인 뒤에 열린다(test_sheet.dart).
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: TextButton(
              onPressed: () => showTestSheet(context),
              style: TextButton.styleFrom(
                foregroundColor: RefitTheme.glow,
                minimumSize: const Size(64, 40),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                  side: BorderSide(
                    color: RefitTheme.glow.withValues(alpha: 0.45),
                  ),
                ),
              ),
              child: const Text(
                'TEST',
                style: TextStyle(
                    fontWeight: FontWeight.w700, letterSpacing: 0.8),
              ),
            ),
          ),
        ],
      ),
      body: RefitBackdrop(
        child: SafeArea(child: IndexedStack(index: _tab, children: tabs)),
      ),
      bottomNavigationBar: _NavBar(index: _tab, onTap: _goTo),
    );
  }
}

class _NavBar extends StatelessWidget {
  const _NavBar({required this.index, required this.onTap});

  final int index;
  final ValueChanged<int> onTap;

  static const _items = <(IconData, IconData, String)>[
    (Icons.home_outlined, Icons.home_rounded, '홈'),
    (Icons.sports_baseball_outlined, Icons.sports_baseball_rounded, '운동'),
    (Icons.bar_chart_outlined, Icons.bar_chart_rounded, '기록'),
    (Icons.settings_outlined, Icons.settings_rounded, '설정'),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: RefitTheme.abyss,
        border: Border(top: BorderSide(color: RefitTheme.hairline)),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: List.generate(_items.length, (i) {
            final (off, on, label) = _items[i];
            final selected = i == index;
            return Expanded(
              child: InkResponse(
                onTap: () => onTap(i),
                radius: 44,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        selected ? on : off,
                        size: 26,
                        color: selected
                            ? RefitTheme.glow
                            : RefitTheme.inkFaint,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        label,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight:
                              selected ? FontWeight.w600 : FontWeight.w400,
                          color: selected
                              ? RefitTheme.glow
                              : RefitTheme.inkFaint,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }),
        ),
      ),
    );
  }
}
