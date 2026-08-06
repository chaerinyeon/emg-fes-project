import 'package:flutter/material.dart';

import '../../signal/constants.dart';
import '../refit_theme.dart';
import '../session/session_orchestrator.dart';

/// 사용자 응답.
enum FeltResponse { none, right, tooStrong }

/// 강도 설정 마법사. 낮은 단계부터 한 단계씩 올린다.
///
/// 목표는 `events/burst >= 10` 을 만족하는 **최소** 강도다 — 세면 셀수록
/// 좋은 게 아니다. 세션 중엔 하향만 가능하니 여기서 정한 값이 그날의 상한이다.
class IntensityWizardScreen extends StatefulWidget {
  const IntensityWizardScreen({super.key, required this.orchestrator});

  final SessionOrchestrator orchestrator;

  @override
  State<IntensityWizardScreen> createState() => _IntensityWizardScreenState();
}

class _IntensityWizardScreenState extends State<IntensityWizardScreen> {
  int _level = 1;
  double _eventsPerBurst = 0;
  bool _measuring = false;
  bool _measured = false;

  Future<void> _measure() async {
    setState(() {
      _measuring = true;
      _measured = false;
    });
    // 이 단계에서 실제로 자극을 주고 events/burst 를 잰다.
    final epb = await widget.orchestrator.measureIntensity(_level);
    if (!mounted) return;
    setState(() {
      _eventsPerBurst = epb;
      _measuring = false;
      _measured = true;
    });
  }

  void _step(int delta) => setState(() {
    _level = (_level + delta).clamp(1, kMaxWizardLevel);
    _measured = false;
  });

  void _answer(FeltResponse r) {
    final enough = _eventsPerBurst >= kMinEventsPerBurst;

    if (r == FeltResponse.tooStrong && _level > 1) return _step(-1);

    // 신호가 충분하고 사용자도 괜찮다고 하면 확정.
    if (enough && r == FeltResponse.right) {
      widget.orchestrator.submitIntensity(
        level: _level,
        eventsPerBurst: _eventsPerBurst,
      );
      return;
    }

    // 아직 부족하면 한 단계 올린다.
    if (_level < kMaxWizardLevel) _step(1);
  }

  @override
  Widget build(BuildContext context) {
    final enough = _eventsPerBurst >= kMinEventsPerBurst;

    return Scaffold(
      body: RefitBackdrop(
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('세기 맞추기', style: RefitTheme.label),
                    const SizedBox(height: 10),
                    Text('오늘 몸에 맞는\n세기를 찾을게요', style: RefitTheme.display),
                  ],
                ),
              ),
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _LevelDots(level: _level, max: kMaxWizardLevel),
                      const SizedBox(height: 28),
                      Text(
                        '$_level단계',
                        style: RefitTheme.title.copyWith(
                          fontWeight: FontWeight.w300,
                        ),
                      ),
                      const SizedBox(height: 12),
                      // 숫자 대신 상태. events/burst 값을 그대로 띄우지 않는다.
                      Text(
                        _measuring
                            ? '신호를 보는 중…'
                            : !_measured
                            ? '준비되면 아래를 눌러 주세요'
                            : enough
                            ? '신호가 잘 잡혀요'
                            : '신호가 약해요',
                        style: RefitTheme.body,
                      ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!_measured) ...[
                      RefitButton(
                        label: _measuring ? '보는 중…' : '이 세기로 해보기',
                        onPressed: _measuring ? null : _measure,
                      ),
                    ] else ...[
                      Text(
                        '움직임이 느껴지나요?',
                        style: RefitTheme.body.copyWith(color: RefitTheme.ink),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(
                            child: RefitButton(
                              label: '안 느껴짐',
                              filled: false,
                              onPressed: () => _answer(FeltResponse.none),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: RefitButton(
                              label: '적당함',
                              onPressed: enough
                                  ? () => _answer(FeltResponse.right)
                                  : null,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      RefitButton(
                        label: '너무 셈',
                        filled: false,
                        tone: RefitTheme.alert,
                        onPressed: () => _answer(FeltResponse.tooStrong),
                      ),
                    ],
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

/// 마법사에서 올릴 수 있는 최대 단계.
const int kMaxWizardLevel = 10;

class _LevelDots extends StatelessWidget {
  const _LevelDots({required this.level, required this.max});

  final int level;
  final int max;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(max, (i) {
        final on = i < level;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          margin: const EdgeInsets.symmetric(horizontal: 4),
          width: on ? 14 : 9,
          height: on ? 14 : 9,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: on ? RefitTheme.glow : const Color(0x33F2F6F5),
          ),
        );
      }),
    );
  }
}
