import 'package:flutter/material.dart';

import '../../ble/device_connection.dart';
import '../../ble/stim_controller.dart';
import '../../session/session_controller.dart';
import '../app_state.dart';
import '../patients/patient_select_screen.dart';
import '../refit_theme.dart';

/// 설정 탭 — 기기 · 강도 · 환자 · 앱 정보.
///
/// 여기는 **연결을 관리하는 곳이지 세션을 시작하는 곳이 아니다.** 연결과
/// 부착 확인은 운동 탭의 사전 세팅이 한 흐름으로 가지고 있어야 게이트가
/// 한 군데서만 선다.
class SettingsTab extends StatefulWidget {
  const SettingsTab({super.key, required this.onGoToSetup});

  /// "운동 탭에서 연결하기" — 연결 흐름의 주인에게 넘긴다.
  final VoidCallback onGoToSetup;

  @override
  State<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<SettingsTab> {
  Future<void> _disconnect() async {
    final o = gApp.live;
    if (o == null) return;
    await o.link.disconnect();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final o = gApp.live;
    final connected = o?.link.state == LinkState.connected;
    final settings = gApp.settings;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
      children: [
        // ── BLE 연결 관리 ──
        const RefitSectionTitle('BLE 연결 관리'),
        RefitCard(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            children: [
              RefitTile(
                title: '연결 상태',
                subtitle: connected ? '연결됨' : '연결 안 됨',
                leading: Icons.bluetooth_rounded,
                trailing: RefitChip(
                  label: connected ? '연결됨' : '끊김',
                  tone: connected ? RefitTheme.glow : RefitTheme.inkFaint,
                ),
              ),
              RefitTile(
                title: '마지막 연결 기기',
                subtitle: settings.lastDeviceName ?? '연결된 적 없음',
                leading: Icons.devices_other_rounded,
              ),
              RefitTile(
                title: connected ? '연결 해제' : '기기 연결하기',
                subtitle: connected
                    ? '훈련 중에는 해제하지 마세요'
                    : '운동 탭의 사전 세팅에서 연결합니다',
                leading: connected
                    ? Icons.link_off_rounded
                    : Icons.link_rounded,
                onTap: connected ? _disconnect : widget.onGoToSetup,
              ),
              // 원인을 화면에서 지우지 않는다 — 다음에 무엇을 할지
              // 말하려면 마지막 오류가 남아 있어야 한다.
              RefitTile(
                title: '마지막 오류',
                subtitle: settings.lastError ?? '없음',
                leading: Icons.error_outline_rounded,
              ),
            ],
          ),
        ),

        // ── 기기 설정 ──
        const RefitSectionTitle('기기 설정'),
        RefitCard(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            children: [
              RefitTile(
                title: '펌웨어 버전',
                subtitle: o?.fwVersion ?? '연결 후 확인',
                leading: Icons.memory_rounded,
              ),
              RefitTile(
                title: '자극 타임아웃 (펌웨어)',
                // 세션 상한이 여기서 유도된다. 펌웨어 값을 올리지 않으면
                // 세션은 2.8분에서 끊긴다.
                subtitle: '$kFirmwareStimTimeoutSeconds초 → '
                    '세션 상한 $kEffectiveSessionMaxSeconds초',
                leading: Icons.timer_outlined,
              ),
              RefitTile(
                title: '영점 보정',
                subtitle: o == null
                    ? '연결 후 세션 시작 시 자동으로 잡힙니다'
                    : (o.pipeline.dcOffset == null
                        ? '아직 잡히지 않았어요'
                        : 'DC ${o.pipeline.dcOffset!.toStringAsFixed(1)} · '
                            '잡음 σ ${o.pipeline.noiseSigma.toStringAsFixed(1)}'),
                leading: Icons.tune_rounded,
              ),
            ],
          ),
        ),

        // ── 기본 자극 강도 ──
        const RefitSectionTitle('기본 자극 강도'),
        RefitCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text('${settings.defaultIntensity}',
                      style: RefitTheme.figure),
                  const SizedBox(width: 4),
                  Text('단계', style: RefitTheme.bodySmall),
                ],
              ),
              SliderTheme(
                data: SliderThemeData(
                  activeTrackColor: RefitTheme.glow,
                  inactiveTrackColor: RefitTheme.panel,
                  thumbColor: RefitTheme.glow,
                  overlayColor: RefitTheme.glow.withValues(alpha: 0.16),
                  trackHeight: 6,
                  thumbShape:
                      const RoundSliderThumbShape(enabledThumbRadius: 14),
                ),
                child: Slider(
                  value: settings.defaultIntensity.toDouble(),
                  min: kMinIntensityLevel.toDouble(),
                  max: kMaxIntensityLevel.toDouble(),
                  divisions: kMaxIntensityLevel - kMinIntensityLevel,
                  onChanged: (v) async {
                    await settings.setDefaultIntensity(v.round());
                    if (mounted) setState(() {});
                  },
                ),
              ),
              Text(
                '다음 세션이 시작할 단계입니다. '
                '세션 중 내린 값은 여기 저장하지 않아요.',
                style: RefitTheme.bodySmall.copyWith(fontSize: 13),
              ),
            ],
          ),
        ),

        // ── 환자 관리 ──
        const RefitSectionTitle('환자 관리'),
        RefitCard(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: RefitTile(
            title: gApp.patient?.name ?? '환자를 골라 주세요',
            subtitle: '리스트 · 추가 · 수정 · 삭제',
            leading: Icons.people_alt_outlined,
            onTap: () async {
              await Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const PatientSelectScreen(),
                ),
              );
              if (mounted) setState(() {});
            },
          ),
        ),

        // ── 앱 정보 ──
        const RefitSectionTitle('앱 정보'),
        RefitCard(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            children: [
              RefitTile(
                title: '앱 버전',
                subtitle: o?.appVersion ?? '1.0.0',
                leading: Icons.info_outline_rounded,
              ),
              RefitTile(
                title: '데이터 저장',
                subtitle: gApp.storePersistent
                    ? '로컬 ${gApp.sessions.length}세션 · '
                        '${gApp.sessions.where((s) => !s.synced).length}건 업로드 대기'
                    : '저장소를 열지 못했어요 — 앱을 닫으면 사라집니다',
                leading: Icons.storage_rounded,
                trailing: gApp.storePersistent
                    ? null
                    : const RefitChip(label: '휘발', tone: RefitTheme.alert),
              ),
              RefitTile(
                title: '라이선스',
                subtitle: '오픈소스 라이선스 보기',
                leading: Icons.description_outlined,
                onTap: () => showLicensePage(
                  context: context,
                  applicationName: 'RE-FIT Play',
                  applicationVersion: o?.appVersion ?? '1.0.0',
                ),
              ),
            ],
          ),
        ),

        // ── 개발 ──
        const RefitSectionTitle('개발'),
        RefitCard(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: RefitTile(
            title: '합성 신호 모드',
            subtitle: '기기 없이 전 구간을 돌려 봅니다',
            leading: Icons.science_outlined,
            trailing: Switch(
              value: settings.syntheticMode,
              activeThumbColor: RefitTheme.glow,
              onChanged: (v) async {
                await settings.setSyntheticMode(v);
                if (mounted) setState(() {});
              },
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          '자극 차단의 1차는 폰의 로컬 자동 종료입니다. 원격은 언제나 2차입니다.',
          style: RefitTheme.bodySmall
              .copyWith(fontSize: 13, color: RefitTheme.inkFaint),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}
