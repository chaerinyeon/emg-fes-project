import 'package:flutter/material.dart';

import '../../model/zone.dart';
import 'sigma_gauge.dart';
import 'stamina_bar.dart';
import 'zone_timeline.dart';

/// 강판/휴식 오버레이 — 3σ(관리이탈) 도달 시.
///
/// ★ 점수 페널티가 없다. 이 이벤트는 벌이 아니라 안전장치다. 피로가 점수를
/// 깎으면 사용자가 무리해서 계속하려 든다 — 그러지 않도록 설계를 나눴다.
///
/// 쉬는 동안 **풀 게이지와 타임라인**을 보여준다. 게임 중에는 공을 봐야 해서
/// 못 보던 자기 피로 곡선을, 어차피 멈춘 김에 제대로 보게 하는 자리다.
class RestOverlay extends StatelessWidget {
  const RestOverlay({
    super.key,
    required this.sigma,
    required this.remainingSec,
    required this.history,
    required this.nowSec,
    required this.inning,
    this.t1,
    this.t2,
    this.t3,
    this.onSkip,
  });

  final double? sigma;
  final double remainingSec;
  final List<({double t, double z})> history;
  final double nowSec;
  final int inning;
  final double? t1, t2, t3;
  final VoidCallback? onSkip;

  @override
  Widget build(BuildContext context) {
    final lead = (t2 != null && t3 != null) ? t3! - t2! : null;

    return ColoredBox(
      color: const Color(0xFF0D1117).withValues(alpha: 0.93),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '휴식 이닝',
                style: TextStyle(
                  color: Color(0xFFE74C3C),
                  fontSize: 26,
                  fontWeight: FontWeight.w900,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 6),
              const Text(
                '관리이탈 구간입니다. 점수는 깎이지 않습니다 — 쉬었다 가세요.',
                style: TextStyle(color: Color(0xFF8B949E), fontSize: 13),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              Text(
                remainingSec.ceil().toString(),
                style: const TextStyle(
                  color: Color(0xFFE6EDF3),
                  fontSize: 64,
                  fontWeight: FontWeight.w900,
                  height: 1,
                ),
              ),
              const Text(
                '초 후 다음 이닝',
                style: TextStyle(color: Color(0xFF8B949E), fontSize: 13),
              ),
              const SizedBox(height: 24),
              SigmaGauge(sigma: sigma),
              const SizedBox(height: 20),
              _Card(child: StaminaBar(sigma: sigma)),
              const SizedBox(height: 12),
              _Card(
                child: ZoneTimeline(
                  history: history,
                  nowSec: nowSec,
                  t1: t1,
                  t2: t2,
                  t3: t3,
                ),
              ),
              const SizedBox(height: 12),
              _Card(
                child: Wrap(
                  spacing: 22,
                  runSpacing: 12,
                  children: [
                    _Stat(label: '1σ 도달', value: _fmt(t1)),
                    _Stat(label: '2σ 도달', value: _fmt(t2)),
                    _Stat(label: '3σ 도달', value: _fmt(t3)),
                    _Stat(
                      label: '2σ→3σ 리드',
                      value: lead == null ? '—' : '${lead.round()} s',
                      hint: '선제 대응 여유',
                    ),
                    _Stat(label: '이닝', value: '$inning'),
                  ],
                ),
              ),
              if (onSkip != null) ...[
                const SizedBox(height: 18),
                TextButton(
                  onPressed: onSkip,
                  child: const Text(
                    '휴식 건너뛰기',
                    style: TextStyle(color: Color(0xFF8B949E)),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  static String _fmt(double? t) {
    if (t == null) return '—';
    final m = t ~/ 60;
    final s = (t % 60).round();
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: const Color(0xFF161B22),
      border: Border.all(color: const Color(0xFF21262D)),
      borderRadius: BorderRadius.circular(16),
    ),
    child: child,
  );
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, this.hint});

  final String label;
  final String value;
  final String? hint;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: const TextStyle(color: Color(0xFF8B949E), fontSize: 11),
      ),
      Text(
        value,
        style: const TextStyle(
          color: Color(0xFFE6EDF3),
          fontSize: 18,
          fontWeight: FontWeight.w700,
        ),
      ),
      if (hint != null)
        Text(
          hint!,
          style: const TextStyle(color: Color(0xFF6E7681), fontSize: 10),
        ),
    ],
  );
}

/// 존 배너 한 줄 — 화면 어디서든 현재 상태 문구를 띄운다.
class ZoneBanner extends StatelessWidget {
  const ZoneBanner({super.key, required this.sigma});

  final double? sigma;

  @override
  Widget build(BuildContext context) {
    final z = sigma;
    if (z == null) {
      return const Text(
        '워밍업 이닝 — 초기 기준을 재는 중입니다',
        style: TextStyle(color: Color(0xFF8B949E), fontSize: 13),
      );
    }
    final zone = zoneOf(z);
    return Text(
      zone.banner,
      style: TextStyle(
        color: Color(zone.argb),
        fontSize: 13,
        fontWeight: FontWeight.w700,
      ),
    );
  }
}
