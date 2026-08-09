import 'package:flutter/material.dart';

import '../app_state.dart';
import '../history/history_section.dart';
import '../patients/patient_select_screen.dart';
import '../refit_theme.dart';

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
    final today = gApp.sessionsOn(DateTime.now());

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

              // ── 오늘의 상태 ──
              const RefitSectionTitle('오늘'),
              _TodayCard(
                status: gApp.todayStatus,
                sessionsToday: today.length,
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

class _TodayCard extends StatelessWidget {
  const _TodayCard({required this.status, required this.sessionsToday});

  final DailyStatus status;
  final int sessionsToday;

  @override
  Widget build(BuildContext context) {
    // 색 규칙: 좋음=민트, 주의=노랑, 피로=호박. **빨강은 쓰지 않는다.**
    final tone = switch (status) {
      DailyStatus.none => RefitTheme.inkFaint,
      DailyStatus.good => RefitTheme.good,
      DailyStatus.caution => RefitTheme.caution,
      DailyStatus.tired => RefitTheme.tired,
    };

    final headline = switch (status) {
      DailyStatus.none => '오늘은 아직 기록이 없어요',
      DailyStatus.good => '몸 상태가 좋아요',
      DailyStatus.caution => '조금 무리했을 수 있어요',
      DailyStatus.tired => '오늘 몫을 다 했어요',
    };

    return RefitCard(
      tint: status == DailyStatus.none ? null : tone,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('피로도', style: RefitTheme.label),
              const Spacer(),
              RefitChip(label: status.label, tone: tone),
            ],
          ),
          const SizedBox(height: 14),
          Text(headline,
              style: RefitTheme.body.copyWith(color: RefitTheme.ink)),
          const SizedBox(height: 8),
          Text(
            sessionsToday == 0 ? '아직 안 했어요' : '오늘 $sessionsToday회 완료',
            style: RefitTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
