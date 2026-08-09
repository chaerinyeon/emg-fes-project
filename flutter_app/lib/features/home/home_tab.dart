import 'package:flutter/material.dart';

import '../app_state.dart';
import '../history/history_section.dart';
import '../patients/patient_select_screen.dart';
import '../refit_theme.dart';
import '../session_language.dart';

/// 홈 — **오늘 무엇을 할지 3초 안에 알려 주고, 그 아래에 지나온 날들이 있다.**
///
/// 기록을 별도 탭으로 두지 않는 이유: 환자가 보는 "오늘"과 치료사가 보는
/// "어제까지"가 결국 같은 하나의 흐름이기 때문이다. 탭을 옮겨 다녀야 하면
/// 그 둘이 서로 다른 이야기처럼 보이고, 무엇보다 "오늘 뭘 했더라"를 확인하는
/// 데 한 단계가 더 든다.
///
/// 순서에는 뜻이 있다. 위에서부터 **누가 · 오늘 몸 상태 · 지나온 날들**이고,
/// 시작 버튼은 스크롤과 무관하게 화면 하단에 붙어 있다 — 목록을 아무리
/// 내려도 한 손으로 닿는다.
///
/// **피로도는 퍼센트를 쓰지 않는다.** 좋음/주의/피로 3단계 상태로만 말하고,
/// 색도 빨강을 쓰지 않는다 — 빨강은 기기 문제 전용이다.
class HomeTab extends StatelessWidget {
  const HomeTab({super.key, required this.onStart});

  /// 운동 탭의 사전 세팅으로 보낸다.
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    final patient = gApp.patient;

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
            children: [
              // ── 환자 카드 ──
              RefitCard(
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const PatientSelectScreen(),
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.baseline,
                            textBaseline: TextBaseline.alphabetic,
                            children: [
                              Flexible(
                                child: Text(
                                  patient?.name ?? '환자를 골라 주세요',
                                  style: RefitTheme.title.copyWith(
                                      fontWeight: FontWeight.w500),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (patient?.age != null) ...[
                                const SizedBox(width: 8),
                                Text('${patient!.age}세',
                                    style: RefitTheme.bodySmall),
                              ],
                            ],
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              RefitChip(
                                label: patient?.category?.short ?? '유형 미정',
                                tone: patient?.category == null
                                    ? RefitTheme.alert
                                    : RefitTheme.glow,
                              ),
                              const SizedBox(width: 8),
                              Flexible(
                                child: Text(
                                  _patientHistory(),
                                  style: RefitTheme.bodySmall
                                      .copyWith(fontSize: 14),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const Icon(Icons.swap_horiz_rounded,
                        color: RefitTheme.inkFaint),
                  ],
                ),
              ),

              // ── 오늘 한 운동 ──
              const RefitSectionTitle('오늘'),
              _TodayCard(
                status: gApp.todayStatus,
                summary: gApp.todaySummary,
                changeNote: gApp.changeNote,
              ),

              // ── 지나온 날들 ──
              //
              // 최근 운동 결과를 따로 요약하지 않는다. 목록 첫 카드가 바로
              // 그것이라, 요약을 덧붙이면 같은 세션이 화면에 두 번 나온다.
              const HistorySection(),
            ],
          ),
        ),

        // 큰 버튼은 스크롤 밖 화면 하단에 붙는다. 한 손으로 닿아야 한다.
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
          child: RefitButton(label: '운동 시작', onPressed: onStart),
        ),
      ],
    );
  }

  String _patientHistory() {
    final n = gApp.patientSessions.length;
    if (n == 0) return '훈련 기록 없음';
    final last = gApp.patientSessions.first.startedAt;
    return '누적 $n회 · 마지막 ${last.month}월 ${last.day}일';
  }
}

/// 오늘 한 운동 요약 + 상태 한 줄.
///
/// 숫자는 **행동 기반**만 쓴다 — 쥔 횟수와 운동 시간. 피로도는 숫자가 아니라
/// 표정과 한 문장으로 말한다: 환자에게 필요한 답은 "내 피로가 몇 %인가"가
/// 아니라 "더 해도 되는가"이기 때문이다.
class _TodayCard extends StatelessWidget {
  const _TodayCard({
    required this.status,
    required this.summary,
    required this.changeNote,
  });

  final DailyStatus status;
  final DailySummary summary;
  final String? changeNote;

  @override
  Widget build(BuildContext context) {
    // 색 규칙: 적당=민트, 부족=노랑, 충분=호박. **빨강은 쓰지 않는다.**
    final tone = switch (status) {
      DailyStatus.none => RefitTheme.inkFaint,
      DailyStatus.more => RefitTheme.caution,
      DailyStatus.good => RefitTheme.good,
      DailyStatus.enough => RefitTheme.tired,
    };

    return RefitCard(
      tint: status == DailyStatus.none ? null : tone,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(status.emoji, style: const TextStyle(fontSize: 22)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  status.headline,
                  style: RefitTheme.body.copyWith(color: RefitTheme.ink),
                ),
              ),
              RefitChip(label: status.label, tone: tone),
            ],
          ),

          if (summary.isEmpty) ...[
            const SizedBox(height: 14),
            Text('아직 안 했어요', style: RefitTheme.bodySmall),
          ] else ...[
            const SizedBox(height: 18),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: _Stat(value: '${summary.reps}', unit: '번 쥐었어요'),
                ),
                Expanded(
                  child: _Stat(
                    value: formatDurationKo(summary.seconds),
                    unit: '운동했어요',
                  ),
                ),
              ],
            ),
            if (changeNote != null) ...[
              const SizedBox(height: 14),
              Text(
                changeNote!,
                style: RefitTheme.bodySmall.copyWith(color: RefitTheme.glow),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.unit});

  final String value;
  final String unit;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(value, style: RefitTheme.figure),
        const SizedBox(height: 4),
        Text(unit, style: RefitTheme.bodySmall.copyWith(fontSize: 14)),
      ],
    );
  }
}
