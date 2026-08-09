import 'package:flutter/material.dart';

import '../../data/local/session_store.dart';
import '../app_state.dart';
import '../patients/patient_select_screen.dart';
import '../refit_theme.dart';
import '../session_language.dart';

/// 홈 — **오늘 무엇을 할지 3초 안에 알려 준다.**
///
/// 정보를 늘어놓는 화면이 아니다. 그래서 여기 있는 것은 넷뿐이다:
/// 누가 훈련하는가 · 오늘 몸 상태가 어떤가 · 어제까지 뭘 했는가 · 시작.
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
    final recent = gApp.patientSessions.isEmpty
        ? null
        : gApp.patientSessions.first;
    final status = gApp.todayStatus;

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

              const RefitSectionTitle('오늘'),
              _TodayCard(status: status, sessionsToday: today.length),

              if (recent != null) ...[
                const RefitSectionTitle('최근 운동'),
                _RecentCard(session: recent),
              ],
            ],
          ),
        ),

        // 큰 버튼은 늘 화면 하단 ⅓ 안에 있다. 한 손으로 닿아야 한다.
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

class _RecentCard extends StatelessWidget {
  const _RecentCard({required this.session});

  final SessionSummary session;

  @override
  Widget build(BuildContext context) {
    final s = session;
    return RefitCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${s.startedAt.month}월 ${s.startedAt.day}일',
              style: RefitTheme.label),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: _Stat(value: '${s.repCount}', unit: '번 쥐었어요'),
              ),
              Expanded(
                child: _Stat(
                  value: formatDurationKo(s.durationS),
                  unit: '함께했어요',
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(closingLineFor(s.endReason), style: RefitTheme.bodySmall),
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
