import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../signal/fatigue_engine.dart' show FatigueAdvice;
import '../refit_theme.dart';
import '../session/session_orchestrator.dart';
import '../session_language.dart';

/// 치료사 보기 — 훈련 화면 아래에서 올라오는 패널.
///
/// ## 왜 뒤에 숨기는가
///
/// 환자 기본 화면에는 임상 지표가 없다. 피로도 퍼센트·RMS·MDF·그래프를
/// 훈련 중에 보여 주면, 자기 몸이 나빠지는 숫자를 10분 내내 응시하게 된다.
/// 그래서 이것들은 전부 이 패널 뒤에 있고, **연 사실 자체가 기록된다**
/// ([SessionOrchestrator.noteTherapistViewOpened]).
///
/// ## 그래프가 게임을 밀지 않는다
///
/// 파형은 조립부의 링버퍼를 [_refresh] 주기로 **읽기만** 한다. 큐 스케줄러는
/// 렌더 루프와 분리된 타이머로 돌기 때문에(하드 제약 7), 이 패널이 열려
/// 있어도 자극 타이밍은 흔들리지 않는다. 닫혀 있으면 타이머 자체가 없다.
class TherapistPanel extends StatefulWidget {
  const TherapistPanel({
    super.key,
    required this.orchestrator,
    this.monitorUrl,
  });

  final SessionOrchestrator orchestrator;

  /// 같은 Wi-Fi 의 노트북에서 열 관찰 화면 주소. 서버가 못 떴으면 null.
  final String? monitorUrl;

  @override
  State<TherapistPanel> createState() => _TherapistPanelState();
}

class _TherapistPanelState extends State<TherapistPanel> {
  static const Duration _refresh = Duration(milliseconds: 100);
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(_refresh, (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final o = widget.orchestrator;
    final b = o.lastBurst;
    final change = o.lastIntensityChange;

    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
      decoration: BoxDecoration(
        color: RefitTheme.abyss.withValues(alpha: 0.94),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        border: Border(top: BorderSide(color: RefitTheme.hairline)),
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('치료사 보기', style: RefitTheme.label),
                const Spacer(),
                _FatigueDot(advice: b?.advice, fatiguePct: b?.fatiguePct),
              ],
            ),
            const SizedBox(height: 14),

            // EMG 실시간 파형 — 1kHz 원본을 8배 솎아 그린다.
            SizedBox(
              height: 92,
              child: CustomPaint(
                size: Size.infinite,
                painter: _WavePainter(o.waveSnapshot()),
              ),
            ),
            const SizedBox(height: 16),

            Row(
              children: [
                Expanded(
                  child: _Metric(
                    label: 'M-wave 진폭',
                    value: b == null ? '—' : b.p2p.toStringAsFixed(0),
                    // 피로 판정의 실제 근거는 이것 하나뿐이다.
                    starred: true,
                  ),
                ),
                Expanded(
                  child: _Metric(
                    label: 'RMS',
                    value: b == null ? '—' : b.rms.toStringAsFixed(1),
                  ),
                ),
                Expanded(
                  child: _Metric(
                    label: 'MDF',
                    value: b?.mdfHz == null
                        ? '—'
                        : '${b!.mdfHz!.toStringAsFixed(0)}Hz',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'RMS · MDF 는 관찰용입니다. 피로 판정은 M-wave 진폭으로만 합니다.',
              style: RefitTheme.bodySmall.copyWith(fontSize: 13),
            ),

            const Divider(height: 28, color: RefitTheme.hairline),

            Row(
              children: [
                Expanded(
                  child: _Metric(
                    label: 'FES 강도',
                    value: '${o.intensityLevel}단계',
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: _Metric(
                    label: '마지막 변경',
                    value: change == null
                        ? '없음 (시작값 유지)'
                        : '${formatDurationKo(change.atS.round())} · '
                            '${change.reason}',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _Metric(
                    label: '검출률',
                    value: o.pipeline.reliability.detectRate
                        .toStringAsFixed(2),
                  ),
                ),
                Expanded(
                  child: _Metric(
                    label: 'events/burst',
                    value: o.pipeline.reliability.eventsPerBurst
                        .toStringAsFixed(1),
                  ),
                ),
                Expanded(
                  child: _Metric(
                    label: '신뢰도',
                    value: o.pipeline.reliability.grade,
                  ),
                ),
              ],
            ),

            const Divider(height: 28, color: RefitTheme.hairline),
            _MonitorAddress(url: widget.monitorUrl),
          ],
        ),
      ),
    );
  }
}

/// 노트북에서 열 관찰 화면 주소.
///
/// 서버는 폰 안에 있고 같은 Wi-Fi 안에서만 닿는다 — 인터넷도 계정도 필요
/// 없다. 주소 뒤의 4자리는 암호가 아니라, 같은 Wi-Fi 의 다른 사람이
/// 우발적으로 열어보는 것만 막는 값이다.
class _MonitorAddress extends StatelessWidget {
  const _MonitorAddress({required this.url});

  final String? url;

  @override
  Widget build(BuildContext context) {
    final u = url;
    return Row(
      children: [
        const Icon(Icons.cast_rounded, size: 18, color: RefitTheme.inkFaint),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '노트북에서 보기',
                style: RefitTheme.bodySmall.copyWith(
                  fontSize: 13,
                  color: RefitTheme.inkFaint,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                // 못 띄운 이유를 감추지 않는다 — 주소가 없으면 치료사는
                // 브라우저만 새로고침하며 원인을 영영 모른다.
                u ?? '관찰 서버를 띄우지 못했어요 (Wi-Fi 확인)',
                style: RefitTheme.bodySmall.copyWith(
                  color: u == null ? RefitTheme.alert : RefitTheme.ink,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
        if (u != null)
          IconButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: u));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('주소를 복사했어요')),
              );
            },
            icon: const Icon(Icons.copy_rounded, size: 18),
            color: RefitTheme.inkSoft,
          ),
      ],
    );
  }
}

/// 피로도 상태 색 — 초록 / 노랑 / 호박. 숫자는 여기서도 크게 쓰지 않는다.
class _FatigueDot extends StatelessWidget {
  const _FatigueDot({required this.advice, required this.fatiguePct});

  final FatigueAdvice? advice;
  final double? fatiguePct;

  @override
  Widget build(BuildContext context) {
    // 급등은 피로가 아니라 센서 문제로 분기한다(하드 제약 5).
    if (advice == FatigueAdvice.checkSensor) {
      return const RefitChip(label: '센서 확인', tone: RefitTheme.alert);
    }
    final f = fatiguePct;
    if (f == null) return const RefitChip(label: '측정 전', tone: RefitTheme.inkFaint);

    final (label, tone) = switch (f) {
      < 35 => ('좋음', RefitTheme.good),
      < 65 => ('주의', RefitTheme.caution),
      _ => ('피로', RefitTheme.tired),
    };
    return RefitChip(label: label, tone: tone);
  }
}

class _Metric extends StatelessWidget {
  const _Metric({
    required this.label,
    required this.value,
    this.starred = false,
  });

  final String label;
  final String value;
  final bool starred;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                label,
                style: RefitTheme.bodySmall.copyWith(
                  fontSize: 13,
                  color: RefitTheme.inkFaint,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (starred)
              const Padding(
                padding: EdgeInsets.only(left: 4),
                child: Icon(Icons.star_rounded,
                    size: 12, color: RefitTheme.glow),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: RefitTheme.bodySmall.copyWith(
            color: starred ? RefitTheme.glow : RefitTheme.ink,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

/// 파형 한 줄. 값의 절대 크기는 의미가 없어 창 안 최대값으로 정규화한다.
class _WavePainter extends CustomPainter {
  const _WavePainter(this.samples);

  final List<double> samples;

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = RefitTheme.hairline
      ..strokeWidth = 1;
    canvas.drawLine(
        Offset(0, size.height / 2), Offset(size.width, size.height / 2), grid);

    if (samples.length < 2) return;

    var peak = 0.0;
    for (final v in samples) {
      final a = v.abs();
      if (a > peak) peak = a;
    }
    if (peak <= 0) return;

    final path = Path();
    for (var i = 0; i < samples.length; i++) {
      final x = size.width * i / (samples.length - 1);
      final y = size.height / 2 - (samples[i] / peak) * (size.height / 2 - 4);
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..color = RefitTheme.glow.withValues(alpha: 0.9),
    );
  }

  @override
  bool shouldRepaint(_WavePainter old) => true;
}
