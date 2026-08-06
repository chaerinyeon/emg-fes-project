import 'package:flutter/material.dart';

import 'dart:async';

import '../ble/device_connection.dart';
import '../data/local/hive_session_store.dart';
import '../data/local/session_store.dart';
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

  /// 기기를 못 찾았다. 환자 탓으로 들리지 않게, 다음 할 일과 함께 말한다.
  bool _noDevice = false;

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
    setState(() {
      _starting = true;
      _noDevice = false;
    });

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

    // 기기를 못 찾았으면 여기서 멈춘다. 그대로 들어가면 "기기를 찾고 있어요"
    // 화면에 갇혀 돌아올 길이 없다 — 블루투스가 없는 환경(시뮬레이터)에서
    // 반드시 걸리는 경로다.
    if (link.state != LinkState.connected) {
      o.dispose();
      if (link is SyntheticFesLink) await link.dispose();
      if (!mounted) return;
      setState(() {
        _starting = false;
        _noDevice = true;
      });
      return;
    }

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

  /// 데모 전용: **탭만** 대신 눌러 준다.
  ///
  /// 판정은 대신하지 않는다 — 부착 체크도 강도 측정도 실제 신호에서 뽑는다.
  /// 결과를 손으로 넣어 버리면 이 미리보기는 아무것도 검증하지 못하는
  /// 화면 구경이 되고, 게이트가 실제로 서는지는 끝까지 알 수 없다.
  ///
  /// **컴파일 타임 플래그로만 켜진다**(`AUTO_PREVIEW`). 기본 빌드에는
  /// 이 경로가 아예 들어가지 않으므로 게이트를 우회할 방법이 없다.
  Future<void> _driveDemo(SessionOrchestrator o) async {
    final check = await o.awaitAttachmentCheck();
    o.submitAttachmentCheck(check);
    if (!check.passed) return;

    final epb = await o.measureIntensity(3);
    o.submitIntensity(level: 3, eventsPerBurst: epb);
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
                    if (_noDevice)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 14),
                        child: Text(
                          '기기를 찾지 못했어요.\n전원을 켠 뒤 다시 눌러 주세요.',
                          style: RefitTheme.body,
                          textAlign: TextAlign.center,
                        ),
                      ),
                    RefitButton(
                      label: _starting
                          ? '준비하는 중…'
                          : (_noDevice ? '다시 시작하기' : '시작하기'),
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
