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

  /// 자극 감지 표시용 갱신. 조립부 알림은 버스트마다(1.6초) 오는데, 자극이
  /// **끊긴 것**은 버스트가 안 오는 상황이라 그 알림으로는 영영 못 본다.
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    gApp.addListener(_onAppChange);
  }

  /// 연결돼 있을 때만 돈다. 연결 전에는 볼 신호가 없다.
  void _syncTicker() {
    final want = _o != null;
    if (want == (_tick != null)) return;
    if (want) {
      _tick = Timer.periodic(const Duration(milliseconds: 400), (_) {
        if (mounted) setState(() {});
      });
    } else {
      _tick?.cancel();
      _tick = null;
    }
  }

  @override
  void dispose() {
    gApp.removeListener(_onAppChange);
    _tick?.cancel();
    _tick = null;
    _teardown();
    super.dispose();
  }

  /// 환자가 바뀌면 준비를 **버린다.**
  ///
  /// 이 화면은 탭 스택 안에서 계속 살아 있어서, 홈에서 환자를 바꾸고
  /// 돌아와도 앞사람에게 묶인 세션이 그대로 남는다. 그대로 시작하면
  /// 기록은 앞사람 이름으로 남고, 앞사람 팔에서 잰 강도로 뒷사람을
  /// 자극하게 된다. 판단은 [RefitAppState.preparedSessionIsStale] 한 곳이
  /// 내린다.
  void _onAppChange() {
    if (gApp.preparedSessionIsStale) {
      _teardown();
      _resetPreparation();
    }
    if (mounted) setState(() {});
  }

  /// 부착 확인·강도 측정 결과를 지운다. 다음 사람의 몸에서 다시 잰다.
  void _resetPreparation() {
    _linkError = null;
    _checking = false;
    _measuring = false;
    _measured = false;
    _eventsPerBurst = 0;
    _level = gApp.settings.defaultIntensity;
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
      // 펌웨어가 'C' 를 완전마비 프로토콜로 읽는다. 유형이 비어 있으면
      // 보내지 않는다 — 모른다는 사실을 "완전마비 아님"으로 바꾸지 않는다.
      categoryCode: patient.category?.code,
      // 합성 링크는 스스로 자극을 흉내내므로 수동이 아니다.
      manualStim: !synthetic && gApp.settings.manualStim,
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

  Future<void> _runCheck({bool force = false}) async {
    final o = _o;
    if (o == null) return;
    setState(() => _checking = true);
    // 판정은 신호 엔진이 한다. 확인 중에 **자극이 잠깐 나간다** — 자극
    // 반응이 없으면 패드가 붙었는지 알 방법이 없기 때문이다. 영점 보정이
    // 끝난 뒤에 켜고, 끝나면 반드시 끈다.
    final r = await o.runAttachmentCheckWithTestPulse();
    if (!mounted) return;
    setState(() => _checking = false);
    o.submitAttachmentCheck(r, force: force);
  }

  /// 부착 판정이 실패로 섰지만 그대로 진행한다.
  ///
  /// 판정을 다시 돌리지 않고 **방금 나온 결과를 그대로** 다시 낸다 — 우회는
  /// 판정을 지우는 게 아니라 판정을 알고도 넘어가는 것이고, 실패한 항목은
  /// 기록에 남아야 나중에 그 세션을 설명할 수 있다.
  void _forcePastCheck() {
    final o = _o;
    final r = o?.lastCheck;
    if (o == null || r == null || r.passed) return;
    o.submitAttachmentCheck(r, force: true);
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

  /// 한 번은 재 봐야 한다. 우회는 **결과를 무시하는 것**이지 측정을 건너뛰는
  /// 게 아니다 — events/burst 가 아예 없으면 그 세션은 나중에 기준점이 없어
  /// 다른 세션과 비교할 수 없게 된다.
  bool get _canStart =>
      _o?.state == SessionState.intensityWizard && _measured;

  // ── 시작 ────────────────────────────────────────────────

  /// 자동 진행 중 지금 밟고 있는 단계. 안 돌고 있으면 null.
  String? _autoStep;

  bool get _busy =>
      _connecting || _checking || _measuring || _starting || _autoStep != null;

  /// 「운동 시작」 한 번으로 남은 준비를 전부 지난다.
  ///
  /// 연결·부착 확인·강도 측정은 원래 위에서부터 손으로 하나씩 눌러야 열렸다.
  /// 준비가 덜 됐다고 버튼을 잠가 두면 화면은 **어디가 막혔는지 말해 주지
  /// 않는다** — 회색 버튼만 남는다. 그래서 버튼은 늘 살려 두고, 누른 뒤에
  /// 빠진 것만 채운다.
  ///
  /// 자동 판정이 실패로 서도 멈추지 않는다. 손으로 「그래도 진행」을 누른
  /// 것과 같은 경로이고, 우회 사실은 [SessionMachine.forcedGates] 에 남는다.
  ///
  /// **연결 실패만은 우회하지 않는다.** 기기가 없으면 흘릴 신호가 없어서,
  /// 밀어붙여 봐야 빈 세션이 하나 생길 뿐이다. 합성 신호로 몰래 바꾸지도
  /// 않는다 — 가짜 표본이 진짜 기록에 섞이면 나중에 갈라낼 수 없다.
  Future<void> _prepareThenStart() async {
    if (_busy) return;

    // 연결 — 이미 붙어 있으면 건너뛴다.
    if (_o == null || _link?.state != LinkState.connected) {
      setState(() => _autoStep = '기기 연결 중…');
      await _connect(synthetic: gApp.settings.syntheticMode);
      if (!mounted) return;
      if (_link?.state != LinkState.connected) {
        // _connect 가 이미 _linkError 를 화면에 띄웠다. 덮어쓰지 않는다.
        setState(() => _autoStep = null);
        return;
      }
    }

    final o = _o;
    if (o == null) {
      setState(() => _autoStep = null);
      return;
    }

    // 부착 확인 — 실패해도 진행한다.
    if (o.state == SessionState.attachmentCheck) {
      setState(() => _autoStep = '부착 확인 중…');
      await _runCheck(force: true);
      if (!mounted) return;
    }

    // 강도 측정 — 한 번은 재고 간다. 미달이어도 _start 가 force 로 넘긴다.
    if (o.state == SessionState.intensityWizard && !_measured) {
      setState(() => _autoStep = '강도 재는 중…');
      await _measure();
      if (!mounted) return;
    }

    setState(() => _autoStep = null);
    if (_canStart) await _start();
  }

  Future<void> _start() async {
    final o = _o;
    if (o == null) return;

    // 리스너가 놓쳤더라도 여기서 한 번 더 막는다. 세션 저장의 주인은
    // 이 시점에 정해지므로, 어긋난 채로 들어가면 되돌릴 방법이 없다.
    if (gApp.preparedSessionIsStale) {
      _teardown();
      setState(_resetPreparation);
      return;
    }

    setState(() => _starting = true);

    // 여기가 실제 게이트다. 상태머신이 통과시키지 않으면 아무 일도 없다.
    // 신호가 약한 걸 화면에 띄운 채로 눌렀다면 그 자체가 사용자의 결정이다.
    o.submitIntensity(
      level: _level,
      eventsPerBurst: _eventsPerBurst,
      force: !_signalStrong,
    );
    // 강도를 확정하면 곧바로 동기화가 아니라 **측정 대기**로 간다.
    // 실제 측정은 게임 화면의 "측정 시작" 을 눌러야 시작된다.
    if (o.state != SessionState.readyToMeasure) {
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

  /// 시작 버튼 위에 띄울 **한 줄**. 없으면 null.
  ///
  /// 조건마다 문구를 따로 쌓으면 셋이 동시에 뜨는 순간이 생기고, 버튼이 화면
  /// 밖으로 밀린다. 우선순위는 「막는 것 → 곧 막을 것 → 알아둘 것」 순이다.
  String? _startNote({required bool noPatient, required bool manualStim}) {
    if (noPatient) return '홈에서 사용할 사람을 먼저 골라 주세요.';
    if (_busy) return null; // 진행 중에는 버튼 라벨이 이미 말하고 있다
    if (_canStart && !_signalStrong) {
      return '신호가 약해요. 게임 속 손이 잘 안 쥐어질 수 있어요.';
    }
    if (manualStim) {
      return '자극기를 켜고 시작해 주세요. 꺼져 있으면 게임이 시작되지 않아요.';
    }
    return null;
  }

  // ── 화면 ────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final o = _o;
    final check = o?.lastCheck;
    final connected = _link?.state == LinkState.connected;
    final canCheck = o != null && o.state == SessionState.attachmentCheck;
    final canMeasure = o != null && o.state == SessionState.intensityWizard;
    final noPatient = gApp.patient == null;
    // 합성 링크는 스스로 자극을 흉내내므로 사람이 켤 것이 없다.
    final manualStim =
        gApp.settings.manualStim && !gApp.settings.syntheticMode;
    final note = _startNote(noPatient: noPatient, manualStim: manualStim);
    _syncTicker();

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
                      onPressed: _busy
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
                      onPressed:
                          _busy ? null : () => _connect(synthetic: true),
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
                    // 자극이 나간다는 사실을 숨기지 않는다. 예고 없이
                    // 근육이 움직이면 그 자체가 놀랄 일이다.
                    // 수동 모드에서는 앱이 자극을 켜지 못한다. "켜집니다" 라고
                    // 적어 두면 사용자는 자기가 켜야 한다는 걸 모른 채,
                    // 신호가 안 잡히는 이유를 엉뚱한 데서 찾게 된다.
                    Text(
                      manualStim
                          ? '자극기는 직접 켜 주세요.\n'
                              '낮은 단계부터 올리면서 근육이 움직이는지 보세요.'
                          : _checking
                              ? '확인 중이에요. 잠시 자극이 켜집니다.'
                              : '확인할 때 자극이 잠깐 켜집니다.\n'
                                  '기기 다이얼을 낮은 단계에 두고 시작해 주세요.',
                      style: RefitTheme.caption,
                      textAlign: TextAlign.center,
                    ),
                    // 「켜져 있는지 확인해 주세요」를 사람에게 떠넘기지 않는다.
                    //
                    // 앱은 자극기를 켜지도 끄지도 못하고, `isStimulating` 은
                    // 자기가 보낸 명령을 센 값이라 실제와 무관하다. 실제로
                    // 자극이 몸에 닿고 있는지 아는 길은 **신호에서 아티팩트가
                    // 보이는가** 하나뿐이고, 그건 파이프라인이 이미 재고 있다.
                    if (connected) ...[
                      const SizedBox(height: 12),
                      _StimLive(
                        // 검출기는 연결 후 몇 초 지나야 선다. 그 전에는
                        // "없다"가 아니라 "아직 모른다"이다.
                        ready: o?.pipeline.stimThreshold != null,
                        live: o?.pipeline.stimSeenRecently ?? false,
                      ),
                    ],
                    const SizedBox(height: 12),
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
                          (_busy || !canCheck) ? null : () => _runCheck(),
                    ),
                    // 판정이 실패로 선 뒤에만 열린다. 처음부터 보이면
                    // 재부착보다 이쪽이 빠른 길이 되어 버린다.
                    if (canCheck && check != null && !check.passed) ...[
                      const SizedBox(height: 10),
                      RefitButton(
                        label: '그래도 진행',
                        filled: false,
                        tone: RefitTheme.caution,
                        onPressed: _busy ? null : _forcePastCheck,
                      ),
                    ],
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
                    // 문단 둘을 하나로 합쳤다. 같은 사실(앱은 세기를 못 바꾼다)을
                    // 두 번 말하면 둘 다 안 읽힌다.
                    Text(
                      '기기 다이얼을 이 단계에 맞춰 주세요. '
                      '앱은 세기를 바꾸지 못하고, 이 단계에서 근육 반응이 '
                      '잡히는지만 확인합니다.',
                      style: RefitTheme.bodySmall,
                    ),
                    const SizedBox(height: 16),
                    RefitButton(
                      label: _measuring ? '보는 중…' : '이 세기로 측정',
                      onPressed: (_busy || !canMeasure) ? null : _measure,
                    ),
                    if (!canMeasure && check?.passed != true) ...[
                      const SizedBox(height: 10),
                      Text(
                        '부착 확인을 통과하면 열려요.',
                        style: RefitTheme.caption,
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
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 안내는 **한 줄만** 띄운다. 세 겹으로 쌓으면 버튼이 밀려
              // 내려가고, 셋 다 안 읽힌다. 지금 가장 중요한 것 하나를
              // [_startNote] 가 고른다.
              if (note != null) ...[
                Text(
                  note,
                  style: RefitTheme.caption,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
              ],
              RefitButton(
                label: _autoStep ??
                    (_starting
                        ? '시작하는 중…'
                        : (_canStart && !_signalStrong)
                            ? '이대로 운동 시작'
                            : '운동 시작'),
                onPressed:
                    (_busy || noPatient) ? null : _prepareThenStart,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 자극이 실제로 나가고 있는가 — **신호에서 읽은 사실.**
///
/// 앱이 자극기를 제어하지 못하므로(마사지기 미배선), 「켜져 있는지 확인해
/// 주세요」라고 사람에게 떠넘기는 대신 화면이 답한다. 근거는 EMG 에 자극
/// 아티팩트가 보이는가 하나뿐이다.
///
/// **「아직 모름」을 「없음」으로 말하지 않는다.** 검출 임계는 연결 후 몇 초
/// 지나야 서고, 그 전의 침묵은 자극이 꺼졌다는 뜻이 아니다.
class _StimLive extends StatelessWidget {
  const _StimLive({required this.ready, required this.live});

  final bool ready;
  final bool live;

  @override
  Widget build(BuildContext context) {
    final (label, tone, note) = switch ((ready, live)) {
      (false, _) => ('자극 확인 중', RefitTheme.inkFaint, '신호를 읽는 중이에요'),
      (true, true) => ('자극 감지됨', RefitTheme.glow, '자극이 몸에 닿고 있어요'),
      (true, false) => (
          '자극 없음',
          RefitTheme.caution,
          '기기를 켜고 세기를 올려 주세요',
        ),
    };

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        RefitChip(label: label, tone: tone),
        const SizedBox(width: 10),
        Flexible(child: Text(note, style: RefitTheme.caption)),
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
                    style: RefitTheme.caption.copyWith(color: on ? RefitTheme.inkSoft : RefitTheme.inkFaint),
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
                  style: RefitTheme.caption),
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
