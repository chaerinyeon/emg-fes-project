import 'dart:async';

import 'package:flutter/material.dart';

import '../../ble/device_connection.dart';
import '../../session/session_controller.dart';
import '../../signal/constants.dart';
import '../app_state.dart';
import '../dev/synthetic_link.dart';
import '../refit_play_flow.dart';
import '../refit_theme.dart';
import '../session/session_orchestrator.dart';
import '../test/test_sheet.dart';

/// 사전 세팅 — 운동 탭의 첫 화면.
///
/// `Setup → Game → Result` 는 **단방향**이다. 시작된 뒤에는 하단 탭이 숨고
/// (훈련은 전체 화면 라우트로 올라간다), 결과에서 `마치기` 를 눌러야 탭이
/// 돌아온다. 중간에 다른 탭으로 빠져나가면 자극이 켜진 채 화면만 바뀐다.
///
/// ## 게이트는 버튼 비활성화가 아니다
///
/// `운동 시작` 이 눌리려면 부착 3항목 + 강도 측정을 통과해야 하는데, 이건
/// UI 규칙이 아니라 [SessionMachine] 의 전이다. 부착 체크를 통과해야
/// `intensityWizard` 로 가고, `events/burst ≥ kMinEventsPerBurst` 여야
/// `syncing` 으로 간다. 화면이 상태와 1:1이라 "건너뛰고 게임으로" 가는
/// 경로가 애초에 없다.
class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key, required this.onSessionFinished});

  /// 결과 화면에서 `마치기` 를 누른 뒤 — 홈으로 돌려보낸다.
  final VoidCallback onSessionFinished;

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  DeviceLink? _link;
  SessionOrchestrator? _o;

  bool _connecting = false;
  String? _linkError;

  bool _checking = false;
  bool _measuring = false;
  bool _starting = false;

  late int _level = gApp.settings.defaultIntensity;
  double _eventsPerBurst = 0;
  bool _measured = false;

  @override
  void dispose() {
    _teardown();
    super.dispose();
  }

  void _teardown() {
    final link = _link;
    final o = _o;
    _o = null;
    _link = null;
    if (gApp.live == o) gApp.live = null;
    o?.dispose();
    // 세션이 끝났으면 링크도 놓는다. 남겨 두면 주인 없는 연결이 배터리를
    // 먹고, 다음 연결에서 같은 기기가 이미 잡혀 있어 실패한다.
    if (link is SyntheticFesLink) {
      unawaited(link.dispose());
    } else if (link != null) {
      unawaited(link.disconnect());
    }
  }

  // ── 연결 ────────────────────────────────────────────────

  Future<void> _connect({required bool synthetic}) async {
    final patient = gApp.patient;
    if (patient == null) return;

    setState(() {
      _connecting = true;
      _linkError = null;
    });
    _teardown();

    final link = synthetic ? SyntheticFesLink() : BleDeviceConnection();
    final o = SessionOrchestrator(
      link: link,
      store: gApp.store,
      sessionId: 'local-${DateTime.now().millisecondsSinceEpoch}',
      patientId: patient.id,
      deviceId: synthetic ? 'synthetic' : 'ble',
    );

    await link.connect();

    // 기기를 못 찾았으면 여기서 멈춘다. 그대로 들어가면 "기기를 찾고 있어요"
    // 화면에 갇혀 돌아올 길이 없다 — 블루투스가 없는 환경에서 반드시
    // 걸리는 경로다. **원인을 화면에서 지우지 않는다.**
    if (link.state != LinkState.connected) {
      o.dispose();
      if (link is SyntheticFesLink) await link.dispose();
      await gApp.settings.setLastError('기기를 찾지 못했어요 (${link.state.name})');
      if (!mounted) return;
      setState(() {
        _connecting = false;
        _linkError = '기기를 찾지 못했어요. 전원을 켠 뒤 다시 눌러 주세요.';
      });
      return;
    }

    await o.begin();
    await gApp.settings.setLastDeviceName(synthetic ? '합성 신호' : 'RE-FIT 기기');
    await gApp.settings.setLastError(null);

    o.addListener(_onOrchestratorChange);
    gApp.live = o;

    if (!mounted) {
      o.dispose();
      return;
    }
    setState(() {
      _link = link;
      _o = o;
      _connecting = false;
      _measured = false;
    });
  }

  void _onOrchestratorChange() {
    if (mounted) setState(() {});
  }

  // ── 부착 확인 ────────────────────────────────────────────

  Future<void> _runCheck() async {
    final o = _o;
    if (o == null) return;
    setState(() => _checking = true);
    // 판정은 신호 엔진이 한다. 신호가 아직 안 왔을 뿐인 상태를
    // "안 붙었다"로 말하지 않게, 판정이 설 때까지 기다린다.
    final r = await o.awaitAttachmentCheck();
    if (!mounted) return;
    setState(() => _checking = false);
    o.submitAttachmentCheck(r);
  }

  // ── 강도 ────────────────────────────────────────────────

  Future<void> _measure() async {
    final o = _o;
    // 자극이 실제로 나가는 동작이다. 부착 확인을 통과해 강도 단계에
    // 들어와 있을 때만 허용한다.
    if (o == null || o.state != SessionState.intensityWizard) return;

    setState(() {
      _measuring = true;
      _measured = false;
    });
    final epb = await o.measureIntensity(_level);
    if (!mounted) return;
    setState(() {
      _eventsPerBurst = epb;
      _measuring = false;
      _measured = true;
    });
  }

  bool get _signalStrong => _eventsPerBurst >= kMinEventsPerBurst;

  bool get _canStart =>
      _o?.state == SessionState.intensityWizard && _measured && _signalStrong;

  // ── 시작 ────────────────────────────────────────────────

  Future<void> _start() async {
    final o = _o;
    if (o == null) return;

    setState(() => _starting = true);

    // 여기가 실제 게이트다. 상태머신이 통과시키지 않으면 아무 일도 없다.
    o.submitIntensity(level: _level, eventsPerBurst: _eventsPerBurst);
    if (o.state != SessionState.syncing) {
      if (mounted) setState(() => _starting = false);
      return;
    }

    // 그날의 상한을 다음 세션 기본값으로 남긴다.
    await gApp.settings.setDefaultIntensity(_level);

    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (routeCtx) => RefitPlayFlow(
          orchestrator: o,
          onFinished: () => Navigator.of(routeCtx).pop(),
        ),
      ),
    );

    _teardown();
    await gApp.reloadSessions();
    if (!mounted) return;
    setState(() {
      _starting = false;
      _measured = false;
      _eventsPerBurst = 0;
      _level = gApp.settings.defaultIntensity;
    });
    widget.onSessionFinished();
  }

  // ── 화면 ────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final o = _o;
    final check = o?.lastCheck;
    final connected = _link?.state == LinkState.connected;
    final canCheck = o != null && o.state == SessionState.attachmentCheck;
    final canMeasure = o != null && o.state == SessionState.intensityWizard;

    return Column(
      children: [
        const _StageIndicator(step: 0),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
            children: [
              // ── 장치 연결 ──
              RefitCard(
                tint: connected ? RefitTheme.glow : null,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text('장치 연결', style: RefitTheme.label),
                        const Spacer(),
                        RefitChip(
                          label: _connecting
                              ? '찾는 중'
                              : connected
                                  ? '연결됨'
                                  : '연결 안 됨',
                          tone: connected
                              ? RefitTheme.glow
                              : _connecting
                                  ? RefitTheme.caution
                                  : RefitTheme.inkFaint,
                        ),
                      ],
                    ),
                    if (_linkError != null) ...[
                      const SizedBox(height: 12),
                      Text(_linkError!, style: RefitTheme.bodySmall),
                    ],
                    const SizedBox(height: 14),
                    RefitButton(
                      label: _connecting
                          ? '찾는 중…'
                          : connected
                              ? '다시 연결'
                              : '장치 연결',
                      filled: !connected,
                      onPressed: _connecting
                          ? null
                          : () => _connect(
                                synthetic: gApp.settings.syntheticMode,
                              ),
                    ),
                    const SizedBox(height: 10),
                    // 블루투스가 없는 환경에서도 전 구간이 지나가야 한다.
                    RefitButton(
                      label: '기기 없이 둘러보기',
                      filled: false,
                      tone: RefitTheme.inkSoft,
                      onPressed: _connecting
                          ? null
                          : () => _connect(synthetic: true),
                    ),
                  ],
                ),
              ),

              // ── 부착 상태 확인 ──
              const RefitSectionTitle('부착 상태 확인'),
              RefitCard(
                child: Column(
                  children: [
                    _CheckRow(
                      title: 'EMG 전극',
                      hint: '팔 안쪽, 손목에서 손가락 세 마디 위',
                      diagram: AttachDiagram.emg,
                      ok: check?.emgElectrodeOk,
                    ),
                    const SizedBox(height: 12),
                    _CheckRow(
                      title: '자극 패드',
                      hint: '전극 아래쪽, 두 장이 닿지 않게',
                      diagram: AttachDiagram.pad,
                      ok: check?.stimPadOk,
                    ),
                    const SizedBox(height: 12),
                    _CheckRow(
                      title: '기기 연결 상태',
                      hint: '배터리와 연결 상태',
                      diagram: AttachDiagram.device,
                      ok: check?.deviceOk,
                    ),
                    const SizedBox(height: 16),
                    if (check != null && !check.passed)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Text(
                          '다시 붙이고 한 번 더 눌러 주세요',
                          style: RefitTheme.bodySmall,
                          textAlign: TextAlign.center,
                        ),
                      ),
                    RefitButton(
                      label: _checking
                          ? '확인하는 중…'
                          : check == null
                              ? '확인 시작'
                              : '다시 확인',
                      filled: check?.passed != true,
                      onPressed:
                          (_checking || !canCheck) ? null : _runCheck,
                    ),
                  ],
                ),
              ),

              // ── 강도 설정 ──
              const RefitSectionTitle('강도 설정'),
              RefitCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Text('$_level', style: RefitTheme.figure),
                        const SizedBox(width: 4),
                        Text('단계', style: RefitTheme.bodySmall),
                        const Spacer(),
                        if (_measured)
                          RefitChip(
                            label: _signalStrong ? '신호가 잘 잡혀요' : '신호가 약해요',
                            tone: _signalStrong
                                ? RefitTheme.glow
                                : RefitTheme.caution,
                          ),
                      ],
                    ),
                    SliderTheme(
                      data: SliderThemeData(
                        activeTrackColor: RefitTheme.glow,
                        inactiveTrackColor: RefitTheme.panel,
                        thumbColor: RefitTheme.glow,
                        overlayColor: RefitTheme.glow.withValues(alpha: 0.16),
                        trackHeight: 6,
                        thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 14),
                      ),
                      child: Slider(
                        value: _level.toDouble(),
                        min: kMinIntensityLevel.toDouble(),
                        max: kMaxIntensityLevel.toDouble(),
                        divisions: kMaxIntensityLevel - kMinIntensityLevel,
                        onChanged: _measuring
                            ? null
                            : (v) => setState(() {
                                  _level = v.round();
                                  // 단계가 바뀌면 이전 측정은 무효다.
                                  _measured = false;
                                  _eventsPerBurst = 0;
                                }),
                      ),
                    ),
                    Text(
                      '기기 다이얼을 이 단계에 맞춰 주세요.',
                      style: RefitTheme.bodySmall,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      // 슬라이더가 기기 출력을 바꾸지 못한다는 사실을 숨기지
                      // 않는다. 여기서 하는 일은 기록과 측정이다.
                      '앱이 기기 출력을 직접 바꾸지는 못해요. '
                      '이 단계에서 근육 반응이 잡히는지 확인합니다.',
                      style: RefitTheme.bodySmall.copyWith(fontSize: 13),
                    ),
                    const SizedBox(height: 16),
                    RefitButton(
                      label: _measuring ? '보는 중…' : '이 세기로 측정',
                      onPressed:
                          (_measuring || !canMeasure) ? null : _measure,
                    ),
                    if (!canMeasure && check?.passed != true) ...[
                      const SizedBox(height: 10),
                      Text(
                        '부착 확인을 통과하면 열려요.',
                        style: RefitTheme.bodySmall.copyWith(fontSize: 13),
                      ),
                    ],
                  ],
                ),
              ),

              const SizedBox(height: 16),
              RefitButton(
                label: '테스트',
                filled: false,
                tone: RefitTheme.inkSoft,
                onPressed: () => showTestSheet(context),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
          child: RefitButton(
            label: _starting ? '시작하는 중…' : '운동 시작',
            onPressed: (_canStart && !_starting) ? _start : null,
          ),
        ),
      ],
    );
  }
}

/// Setup → Game → Result. 지금 어디인지 세 점으로만 말한다.
class _StageIndicator extends StatelessWidget {
  const _StageIndicator({required this.step});

  final int step;

  static const _labels = ['준비', '운동', '결과'];

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
      child: Row(
        children: List.generate(_labels.length, (i) {
          final on = i <= step;
          return Expanded(
            child: Padding(
              padding: EdgeInsets.only(right: i == _labels.length - 1 ? 0 : 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    height: 3,
                    decoration: BoxDecoration(
                      color: on ? RefitTheme.glow : RefitTheme.panel,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _labels[i],
                    style: RefitTheme.bodySmall.copyWith(
                      fontSize: 13,
                      color: on ? RefitTheme.inkSoft : RefitTheme.inkFaint,
                    ),
                  ),
                ],
              ),
            ),
          );
        }),
      ),
    );
  }
}

/// 부착 위치 도식 종류.
enum AttachDiagram { emg, pad, device }

class _CheckRow extends StatelessWidget {
  const _CheckRow({
    required this.title,
    required this.hint,
    required this.diagram,
    required this.ok,
  });

  final String title;
  final String hint;
  final AttachDiagram diagram;
  final bool? ok;

  @override
  Widget build(BuildContext context) {
    final (icon, tint) = switch (ok) {
      null => (null, RefitTheme.inkFaint),
      true => (Icons.check_rounded, RefitTheme.glow),
      false => (Icons.refresh_rounded, RefitTheme.alert),
    };

    return Row(
      children: [
        SizedBox(
          width: 52,
          height: 52,
          child: CustomPaint(painter: AttachDiagramPainter(diagram, tint)),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: RefitTheme.bodySmall.copyWith(
                  color: RefitTheme.ink,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(hint,
                  style: RefitTheme.bodySmall.copyWith(fontSize: 13)),
            ],
          ),
        ),
        if (icon != null) Icon(icon, color: tint, size: 24),
      ],
    );
  }
}

/// 부착 위치 도식 (플레이스홀더).
/// 실제 일러스트 에셋이 준비되면 이 페인터를 이미지로 바꾼다.
class AttachDiagramPainter extends CustomPainter {
  AttachDiagramPainter(this.kind, this.tint);

  final AttachDiagram kind;
  final Color tint;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..color = RefitTheme.inkSoft;
    final fill = Paint()..color = tint.withValues(alpha: 0.85);

    if (kind == AttachDiagram.device) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(w * 0.22, h * 0.28, w * 0.56, h * 0.44),
          const Radius.circular(8),
        ),
        stroke,
      );
      canvas.drawCircle(Offset(w * 0.5, h * 0.5), 5, fill);
      return;
    }

    // 팔뚝 실루엣 + 붙이는 자리. 전극은 위, 패드는 아래.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * 0.30, h * 0.10, w * 0.40, h * 0.80),
        Radius.circular(w * 0.20),
      ),
      stroke,
    );
    final y = kind == AttachDiagram.emg ? 0.34 : 0.62;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * 0.36, h * y, w * 0.28, h * 0.13),
        const Radius.circular(4),
      ),
      fill,
    );
  }

  @override
  bool shouldRepaint(AttachDiagramPainter old) =>
      old.kind != kind || old.tint != tint;
}
