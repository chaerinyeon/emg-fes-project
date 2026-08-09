import 'dart:async';

import 'package:flame/game.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../ble/device_connection.dart';
import '../../ble/stim_controller.dart';
import '../../game/data/mock_fatigue_feed.dart';
import '../../game/flame/baseball_game.dart';
import '../../signal/constants.dart';
import '../../signal/signal_pipeline.dart';
import '../app_state.dart';
import '../dev/synthetic_link.dart';
import '../refit_theme.dart';

/// TEST — AppBar 우측에 항상 있고 **BLE 연결 없이 동작한다.**
///
/// ## 게이트 우회로가 아니다
///
/// 자극이 나가지 않는 항목(화면 확인 · 센서 확인 · 진단 정보)은 언제나 열려
/// 있다. 하지만 **실제 자극을 쏘는 항목은 부착 확인을 통과한 뒤에만** 열린다.
/// 그렇지 않으면 "TEST 로 들어가서 전극 없이 자극" 이라는 경로가 생긴다.
///
/// 판정은 여기서 하지 않는다 — 잠금 여부는 살아 있는 세션
/// ([RefitAppState.live])의 상태머신이 이미 내려 둔 결론을 읽을 뿐이다.
Future<void> showTestSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: RefitTheme.deep,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
    builder: (_) => const _TestSheet(),
  );
}

class _TestSheet extends StatefulWidget {
  const _TestSheet();

  @override
  State<_TestSheet> createState() => _TestSheetState();
}

class _TestSheetState extends State<_TestSheet> {
  String? _sensorResult;
  bool _sensorRunning = false;

  String? _stimResult;
  bool _stimRunning = false;

  /// 실제 자극을 쏠 수 있는 조건. 살아 있는 링크 + 부착 확인 통과.
  bool get _stimUnlocked {
    final o = gApp.live;
    return o != null &&
        o.link.state == LinkState.connected &&
        (o.lastCheck?.passed ?? false);
  }

  /// 센서 확인 — 합성 신호를 실기기와 **같은 경로**로 흘려 파이프라인이
  /// 도는지 본다. 기기가 없어도 되고, 자극도 나가지 않는다.
  Future<void> _checkSensor() async {
    setState(() {
      _sensorRunning = true;
      _sensorResult = null;
    });

    final link = SyntheticFesLink(autoTick: false);
    final pipeline = SignalPipeline();
    final sub = rawSamples(link.rawPackets).listen((s) {
      pipeline.addSample(s.$1, s.$2);
    });
    await link.connect();
    // 시계를 손으로 민다 — 실시간 20초를 기다리게 하지 않는다.
    for (var t = 0; t < 20000; t += 100) {
      link.emitNextPacket();
      if (t % 2000 == 0) await Future<void>.delayed(Duration.zero);
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await sub.cancel();
    await link.dispose();

    final gate = pipeline.reliability;
    final ok = gate.burstCount > 0 &&
        gate.eventsPerBurst >= kMinEventsPerBurst &&
        pipeline.dcOffset != null;

    if (!mounted) return;
    setState(() {
      _sensorRunning = false;
      _sensorResult = ok
          ? '파이프라인 정상 · 버스트 ${gate.burstCount}개 · '
              'events/burst ${gate.eventsPerBurst.toStringAsFixed(1)} · 등급 ${gate.grade}'
          : '신호가 잡히지 않았어요 · 버스트 ${gate.burstCount}개';
    });
  }

  /// 자극기 확인 — 최저 단계 펄스를 한 번 쏘고 M-wave 가 잡히는지 본다.
  Future<void> _checkStim() async {
    final o = gApp.live;
    if (o == null) return;

    setState(() {
      _stimRunning = true;
      _stimResult = null;
    });

    final before = o.pipeline.reliability.burstCount;
    await o.stim.start();
    await Future<void>.delayed(const Duration(seconds: 3));
    await o.stim.stop(reason: StimStopReason.sessionEnd);

    final gate = o.pipeline.reliability;
    if (!mounted) return;
    setState(() {
      _stimRunning = false;
      _stimResult = gate.burstCount > before
          ? '자극이 나갔고 반응이 잡혀요'
          : '자극은 나갔지만 반응이 잡히지 않아요 · 패드를 확인해 주세요';
    });
  }

  /// 진단 정보 복사 — 버전 · 마지막 오류 · 검출률.
  Future<void> _copyDiagnostics() async {
    final o = gApp.live;
    final gate = o?.pipeline.reliability;
    final lines = <String>[
      'RE-FIT Play 진단',
      '앱 버전: ${o?.appVersion ?? '1.0.0'}',
      '펌웨어: ${o?.fwVersion ?? 'unknown'}',
      '기기: ${gApp.settings.lastDeviceName ?? '연결된 적 없음'}',
      '마지막 오류: ${gApp.settings.lastError ?? '없음'}',
      '링크 상태: ${o?.link.state.name ?? '세션 없음'}',
      '세션 상태: ${o?.state.name ?? '없음'}',
      if (gate != null) ...[
        '버스트: ${gate.burstCount}',
        'events/burst: ${gate.eventsPerBurst.toStringAsFixed(2)}',
        '검출률: ${gate.detectRate.toStringAsFixed(3)}',
        '신뢰도 등급: ${gate.grade}',
      ],
      '자극 주기(ms): ${o?.pipeline.periodMs?.toStringAsFixed(1) ?? '미확정'}',
      '저장된 세션: ${gApp.sessions.length}',
    ];
    await Clipboard.setData(ClipboardData(text: lines.join('\n')));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('진단 정보를 복사했어요')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 44,
                height: 4,
                margin: const EdgeInsets.only(bottom: 20),
                decoration: BoxDecoration(
                  color: RefitTheme.inkFaint,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Text('TEST', style: RefitTheme.title),
            ),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Text(
                '기기가 없어도 화면·센서는 확인할 수 있어요.',
                style: RefitTheme.bodySmall,
              ),
            ),
            const SizedBox(height: 18),

            RefitTile(
              title: '화면 확인',
              subtitle: '게임·손 애니메이션·색·글자 크기',
              leading: Icons.smartphone_rounded,
              onTap: () {
                Navigator.of(context).pop();
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const _GamePreviewScreen(),
                  ),
                );
              },
            ),
            RefitTile(
              title: '센서 확인',
              subtitle: _sensorRunning
                  ? '합성 신호를 흘리는 중…'
                  : (_sensorResult ?? '합성 신호로 파이프라인이 도는지 본다'),
              leading: Icons.monitor_heart_outlined,
              onTap: _sensorRunning ? null : _checkSensor,
            ),
            RefitTile(
              title: '자극기 확인',
              subtitle: _stimRunning
                  ? '펄스를 쏘는 중…'
                  : (_stimResult ??
                      (_stimUnlocked
                          ? '최저 단계 펄스 1회 + 반응 확인'
                          : '부착 확인을 통과한 뒤에 열려요')),
              leading: Icons.bolt_outlined,
              trailing: _stimUnlocked
                  ? null
                  : const Icon(Icons.lock_outline_rounded,
                      color: RefitTheme.inkFaint, size: 20),
              onTap: (_stimUnlocked && !_stimRunning) ? _checkStim : null,
            ),
            RefitTile(
              title: '진단 정보 복사',
              subtitle: '버전 · 마지막 오류 · 검출률',
              leading: Icons.copy_all_outlined,
              onTap: _copyDiagnostics,
            ),
          ],
        ),
      ),
    );
  }
}

/// 화면 확인 — 실측 세션을 재생하는 목 피드로 게임만 띄운다.
/// 자극도 BLE 도 관여하지 않는다.
class _GamePreviewScreen extends StatefulWidget {
  const _GamePreviewScreen();

  @override
  State<_GamePreviewScreen> createState() => _GamePreviewScreenState();
}

class _GamePreviewScreenState extends State<_GamePreviewScreen> {
  late final MockFatigueFeed _feed = MockFatigueFeed();
  late final BaseballGame _game = BaseballGame(feed: _feed);

  @override
  void initState() {
    super.initState();
    unawaited(_feed.start());
  }

  @override
  void dispose() {
    unawaited(_feed.stop());
    _feed.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: RefitTheme.abyss,
      body: Stack(
        fit: StackFit.expand,
        children: [
          GameWidget<BaseballGame>(game: _game),
          SafeArea(
            child: Column(
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: RefitTheme.abyss.withValues(alpha: 0.7),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text('화면 확인 (자극 없음)',
                          style: RefitTheme.label.copyWith(
                              color: RefitTheme.inkSoft)),
                    ),
                  ),
                ),
                const Spacer(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                  child: RefitButton(
                    label: '닫기',
                    filled: false,
                    tone: RefitTheme.inkSoft,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
