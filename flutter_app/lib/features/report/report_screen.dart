import 'package:flutter/material.dart';

import '../../session/end_conditions.dart';
import '../charts/trend_chart.dart';
import '../refit_theme.dart';
import '../session/session_orchestrator.dart';
import '../session_language.dart';

/// 결과 화면의 **치료사 보기** 재료.
///
/// 환자 화면에는 들어가지 않는 값들이다. 결과 화면이 조립부에 계속
/// 매달려 있지 않도록, 세션이 끝난 시점에 한 번 뽑아서 값으로 넘긴다.
class ReportDetail {
  const ReportDetail({
    required this.avgRms,
    required this.avgMdf,
    required this.detectRate,
    required this.eventsPerBurst,
    required this.grade,
    required this.levelChangeCount,
    required this.p2pTrend,
    required this.therapistViewOpens,
  });

  final double? avgRms;
  final double? avgMdf;
  final double detectRate;
  final double eventsPerBurst;
  final String grade;
  final int levelChangeCount;

  /// M-wave 진폭 추이 — 피로 판정의 실제 근거.
  final List<double> p2pTrend;

  final int therapistViewOpens;

  static ReportDetail from(SessionOrchestrator o) {
    final rows = o.bursts;
    final gate = o.pipeline.reliability;
    return ReportDetail(
      avgRms: _mean(rows.map((r) => r.rms).whereType<double>()),
      avgMdf: _mean(rows.map((r) => r.mdf).whereType<double>()),
      detectRate: gate.detectRate,
      eventsPerBurst: gate.eventsPerBurst,
      grade: gate.grade,
      levelChangeCount: o.pipeline.levelSegmentCount - 1,
      p2pTrend: rows.map((r) => r.p2p).toList(),
      therapistViewOpens: o.therapistViewOpens,
    );
  }

  static double? _mean(Iterable<double> xs) {
    if (xs.isEmpty) return null;
    return xs.reduce((a, b) => a + b) / xs.length;
  }
}

/// 종료 화면.
///
/// 환자가 읽는 부분은 **여전히 큰 글씨 몇 줄**이다. 그래프도 퍼센트도 없다.
/// 임상 지표는 전부 `치료사 보기` 뒤에 있다.
///
/// 피로 임계 도달은 **실패가 아니라 "오늘 목표 달성"**이다. 문구·색·연출
/// 전부 이 프레임을 지킨다. 장비 문제로 멈춘 경우에만 담담하게 사실을
/// 알린다 — 그것도 환자 탓으로 들리지 않게.
class ReportScreen extends StatefulWidget {
  const ReportScreen({
    super.key,
    required this.repCount,
    required this.durationS,
    required this.endReason,
    this.successRate,
    this.fatigueOnsetS,
    this.detail,
    this.onDone,
  });

  ReportScreen.of(SessionOrchestrator o, {super.key, this.onDone})
    : repCount = o.repCount,
      durationS = o.elapsedS.round(),
      endReason = o.endReason ?? SessionEndReason.error,
      successRate = o.machine.successRate,
      fatigueOnsetS = o.fatigueOnsetS,
      detail = ReportDetail.from(o);

  final int repCount;
  final int durationS;
  final SessionEndReason endReason;

  /// 수행 성공률. 없으면 그 줄을 만들지 않는다.
  final double? successRate;

  /// 피로가 시작된 시각(초). null 이면 "끝까지 힘이 남았다".
  final double? fatigueOnsetS;

  /// 치료사 보기 재료. 없으면 토글 자체가 뜨지 않는다.
  final ReportDetail? detail;

  final VoidCallback? onDone;

  @override
  State<ReportScreen> createState() => _ReportScreenState();
}

class _ReportScreenState extends State<ReportScreen> {
  bool _therapistView = false;

  /// 환자가 읽는 언어. 종료 코드를 그대로 보여주지 않는다.
  String get _closing => switch (widget.endReason) {
    SessionEndReason.fatigueThreshold ||
    SessionEndReason.successRateDrop => '오늘 몫을 다 했어요.\n내일도 같은 시간에 만나요',
    SessionEndReason.gameComplete => '오늘 목표를 채웠어요.\n내일도 같은 시간에 만나요',
    SessionEndReason.timeout => '오늘도 끝까지 했어요.\n내일도 같은 시간에 만나요',
    SessionEndReason.userStop => '오늘도 수고했어요.\n내일 다시 만나요',
    SessionEndReason.remoteStop => '치료사가 오늘 훈련을 마무리했어요',
    SessionEndReason.signalLost ||
    SessionEndReason.deviceDisconnect => '기기 연결이 끊겨 여기서 멈췄어요.\n다음에 이어서 해요',
    SessionEndReason.error => '여기서 멈췄어요.\n다음에 이어서 해요',
  };

  String get _duration {
    final m = widget.durationS ~/ 60;
    final s = widget.durationS % 60;
    if (m == 0) return '$s초 함께했어요';
    return '$m분 $s초 함께했어요';
  }

  @override
  Widget build(BuildContext context) {
    final rate = widget.successRate;
    final detail = widget.detail;

    return Scaffold(
      body: RefitBackdrop(
        child: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  children: [
                    const SizedBox(height: 28),
                    // 1줄 — 오늘 몇 번 쥐었나
                    Center(
                      child: Text('${widget.repCount}',
                          style: RefitTheme.counter),
                    ),
                    const SizedBox(height: 6),
                    Center(
                      child: Text(
                        '번 쥐었어요',
                        style: RefitTheme.title
                            .copyWith(fontWeight: FontWeight.w300),
                      ),
                    ),
                    const SizedBox(height: 36),
                    // 2줄 — 얼마나 함께했나
                    Text(_duration,
                        style: RefitTheme.body,
                        textAlign: TextAlign.center),
                    const SizedBox(height: 14),
                    // 3줄 — 내일로 잇는 말
                    Text(_closing,
                        style: RefitTheme.body,
                        textAlign: TextAlign.center),

                    const SizedBox(height: 30),
                    // 오늘 몸이 어떻게 지나갔는지 두 문장. 퍼센트는 쓰지 않는다.
                    Text(
                      fatigueOnsetLine(widget.fatigueOnsetS),
                      style: RefitTheme.bodySmall,
                      textAlign: TextAlign.center,
                    ),
                    if (rate != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        '${successRatioLine(rate)} 잡았어요',
                        style: RefitTheme.bodySmall,
                        textAlign: TextAlign.center,
                      ),
                    ],

                    if (detail != null) ...[
                      const SizedBox(height: 22),
                      Center(
                        child: TextButton.icon(
                          onPressed: () => setState(
                              () => _therapistView = !_therapistView),
                          style: TextButton.styleFrom(
                              foregroundColor: RefitTheme.inkFaint),
                          icon: Icon(
                            _therapistView
                                ? Icons.expand_less_rounded
                                : Icons.expand_more_rounded,
                            size: 20,
                          ),
                          label: const Text('치료사 보기'),
                        ),
                      ),
                      if (_therapistView) _TherapistSection(detail: detail),
                    ],
                    const SizedBox(height: 12),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
                child: RefitButton(label: '마치기', onPressed: widget.onDone),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TherapistSection extends StatelessWidget {
  const _TherapistSection({required this.detail});

  final ReportDetail detail;

  @override
  Widget build(BuildContext context) {
    final d = detail;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: RefitCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('M-wave 진폭 추이', style: RefitTheme.label),
            const SizedBox(height: 10),
            SizedBox(
              height: 96,
              child: TrendChart(
                values: d.p2pTrend,
                color: RefitTheme.glow,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '피로 판정의 근거는 이 곡선 하나뿐입니다.',
              style: RefitTheme.bodySmall.copyWith(fontSize: 13),
            ),
            const Divider(height: 26, color: RefitTheme.hairline),
            _row('평균 RMS', d.avgRms?.toStringAsFixed(1) ?? '—'),
            _row('평균 MDF',
                d.avgMdf == null ? '—' : '${d.avgMdf!.toStringAsFixed(0)} Hz'),
            _row('검출률', d.detectRate.toStringAsFixed(2)),
            _row('events/burst', d.eventsPerBurst.toStringAsFixed(1)),
            _row('신뢰도 등급', d.grade),
            _row('레벨 변화 횟수', '${d.levelChangeCount}회'),
            _row('치료사 보기 연 횟수', '${d.therapistViewOpens}회'),
          ],
        ),
      ),
    );
  }

  Widget _row(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          children: [
            Expanded(child: Text(k, style: RefitTheme.bodySmall)),
            Text(
              v,
              style: RefitTheme.bodySmall.copyWith(
                color: RefitTheme.ink,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      );
}
