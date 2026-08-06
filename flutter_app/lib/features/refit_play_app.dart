import 'package:flutter/material.dart';

import 'dart:async';

import '../ble/device_connection.dart';
import '../data/local/hive_session_store.dart';
import '../data/local/session_store.dart';
import '../session/session_controller.dart';
import 'dev/synthetic_link.dart';
import 'refit_play_flow.dart';
import 'refit_theme.dart';
import 'session/session_orchestrator.dart';

/// RE-FIT Play — 환자 앱 진입점.
class RefitPlayApp extends StatelessWidget {
  const RefitPlayApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'RE-FIT Play',
      debugShowCheckedModeBanner: false,
      theme: RefitTheme.material,
      home: const StartScreen(),
    );
  }
}

/// 시작 화면.
///
/// 첫 실행부터 게임 시작까지 3분 안에 들어와야 한다. 그래서 고를 것을
/// 늘리지 않는다 — 큰 버튼 하나가 기본이고, 미리보기는 개발·시연용이다.
class StartScreen extends StatefulWidget {
  const StartScreen({super.key});

  @override
  State<StartScreen> createState() => _StartScreenState();
}

class _StartScreenState extends State<StartScreen> {
  bool _starting = false;

  /// `--dart-define=AUTO_PREVIEW=1` 로 빌드하면 합성 세션이 바로 시작된다.
  /// 시뮬레이터에는 탭 자동화가 없어서 화면 확인용으로 둔다.
  static const bool _autoPreview =
      bool.fromEnvironment('AUTO_PREVIEW', defaultValue: false);

  @override
  void initState() {
    super.initState();
    if (_autoPreview) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _start(synthetic: true),
      );
    }
  }

  Future<void> _start({required bool synthetic}) async {
    setState(() => _starting = true);

    final DeviceLink link =
        synthetic ? SyntheticFesLink() : BleDeviceConnection();

    SessionStore store;
    try {
      store = await HiveSessionStore.open();
    } catch (_) {
      // 저장소가 안 열려도 훈련은 되어야 한다.
      store = InMemorySessionStore();
    }

    final o = SessionOrchestrator(
      link: link,
      store: store,
      sessionId: 'local-${DateTime.now().millisecondsSinceEpoch}',
      patientId: 'local',
      deviceId: synthetic ? 'synthetic' : 'ble',
    );

    await link.connect();
    await o.begin();

    if (_autoPreview) unawaited(_driveDemo(o));

    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RefitPlayFlow(
          orchestrator: o,
          onFinished: () => Navigator.of(context).pop(),
        ),
      ),
    );

    o.dispose();
    if (link is SyntheticFesLink) await link.dispose();
    if (mounted) setState(() => _starting = false);
  }

  /// 데모 전용: 부착 체크·강도 게이트를 자동 통과시켜 훈련 화면까지 간다.
  ///
  /// **컴파일 타임 플래그로만 켜진다**(`AUTO_PREVIEW`). 기본 빌드에는
  /// 이 경로가 아예 들어가지 않으므로 게이트를 우회할 방법이 없다.
  Future<void> _driveDemo(SessionOrchestrator o) async {
    await Future<void>.delayed(const Duration(seconds: 2));
    o.submitAttachmentCheck(const AttachmentCheck(
      emgElectrodeOk: true,
      stimPadOk: true,
      deviceOk: true,
    ));
    await Future<void>.delayed(const Duration(milliseconds: 600));
    o.submitIntensity(level: 3, eventsPerBurst: 18);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: RefitBackdrop(
        child: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('RE-FIT', style: RefitTheme.label),
                      const SizedBox(height: 12),
                      Text('오늘도\n손을 움직여요',
                          style: RefitTheme.display,
                          textAlign: TextAlign.center),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    RefitButton(
                      label: _starting ? '준비하는 중…' : '시작하기',
                      onPressed:
                          _starting ? null : () => _start(synthetic: false),
                    ),
                    const SizedBox(height: 12),
                    RefitButton(
                      label: '기기 없이 둘러보기',
                      filled: false,
                      tone: RefitTheme.inkSoft,
                      onPressed:
                          _starting ? null : () => _start(synthetic: true),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
