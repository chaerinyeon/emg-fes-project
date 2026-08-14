import 'package:flutter/material.dart';

import '../../data/local/session_store.dart';
import '../app_state.dart';
import '../refit_theme.dart';
import '../session_language.dart';
import 'session_detail_screen.dart';

/// 기록 묶음 — **치료사·보호자가 보는 부분이다.**
///
/// 홈 안에 얹힌다. 화면을 따로 두지 않는 이유는 환자가 볼 것과 치료사가
/// 볼 것이 결국 **같은 하루**이기 때문이다. "오늘 어땠나"를 보려고 탭을
/// 옮겨 다녀야 하면 그 둘이 서로 다른 이야기처럼 보인다.
///
/// 여기서는 지표를 감추지 않는다. 다만 두 가지는 지킨다:
///
/// - **환자 간 절대 피로 비교와 순위를 만들지 않는다**(하드 제약 6).
///   비교는 언제나 같은 환자의 과거 자신하고만 한다. 그래서 목록은 항상
///   선택된 환자로 좁혀져 있다.
/// - **원시 파형(1kHz)은 앱에 저장하지 않는다.** 버스트 단위 요약만 남는다.
///
/// 스크롤은 부모(홈)의 것 하나뿐이다. 여기서 또 스크롤을 만들면 목록 안에
/// 목록이 생겨 손가락이 어느 쪽을 미는지 알 수 없게 된다. 세션이 수백 개로
/// 늘면 그때 부모를 `CustomScrollView` 로 바꾸고 이 묶음을 sliver 로 낸다.
class HistorySection extends StatefulWidget {
  const HistorySection({super.key});

  @override
  State<HistorySection> createState() => _HistorySectionState();
}

class _HistorySectionState extends State<HistorySection> {
  bool _calendar = false;
  DateTime _month = DateTime.now();

  @override
  Widget build(BuildContext context) {
    final sessions = gApp.patientSessions;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        RefitSectionTitle(
          '기록',
          trailing: Row(
            children: [
              _ViewToggle(
                label: '리스트',
                selected: !_calendar,
                onTap: () => setState(() => _calendar = false),
              ),
              const SizedBox(width: 8),
              _ViewToggle(
                label: '달력',
                selected: _calendar,
                onTap: () => setState(() => _calendar = true),
              ),
            ],
          ),
        ),
        // 재활에서 중요한 건 한 번의 강도가 아니라 지속이다.
        if (sessions.isNotEmpty) ...[
          const _PersistenceCard(),
          const SizedBox(height: 12),
        ],

        if (sessions.isEmpty)
          _EmptyState(onChanged: () => setState(() {}))
        else if (_calendar)
          _CalendarView(
            sessions: sessions,
            month: _month,
            onMonth: (m) => setState(() => _month = m),
          )
        else
          for (final s in sessions)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: SessionCard(session: s),
            ),
      ],
    );
  }
}

/// 지속 — 연속 수행일과 이번 주 목표.
///
/// **끊긴 날을 실패로 만들지 않는다.** 연속이 0이어도 "0일" 이라고 쓰지 않고
/// 경고색도 쓰지 않는다. 재활은 몇 년짜리 일이라 빠지는 날이 반드시 있고,
/// 그 날을 앱이 나무라기 시작하면 돌아오기가 더 어려워진다. 오늘 아직
/// 안 했다고 해서 이어지던 수를 깎지도 않는다([RefitAppState.streakDays]).
///
/// 주간 목표는 **비율이 아니라 날 수**로 말한다 — "60%" 대신 "5일 중 3일".
/// 퍼센트는 못 채운 40%를 먼저 읽게 만든다.
class _PersistenceCard extends StatelessWidget {
  const _PersistenceCard();

  @override
  Widget build(BuildContext context) {
    final streak = gApp.streakDays;
    final done = gApp.weekDoneDays;
    final goal = gApp.weekGoalDays;
    final met = done >= goal;

    return RefitCard(
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('연속', style: RefitTheme.label),
                const SizedBox(height: 8),
                Text(
                  streak == 0 ? '다시 시작해요' : '$streak일째',
                  style: streak == 0
                      ? RefitTheme.bodySmall.copyWith(color: RefitTheme.inkSoft)
                      : RefitTheme.bodySmall.copyWith(
                          color: RefitTheme.ink,
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                        ),
                ),
              ],
            ),
          ),
          Container(width: 1, height: 40, color: RefitTheme.hairline),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(left: 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text('이번 주', style: RefitTheme.label),
                      if (met) ...[
                        const SizedBox(width: 6),
                        const Icon(Icons.check_circle_rounded,
                            size: 14, color: RefitTheme.glow),
                      ],
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '$goal일 중 $done일',
                    style: RefitTheme.bodySmall.copyWith(
                      color: RefitTheme.ink,
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  _WeekDots(done: done, goal: goal),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _WeekDots extends StatelessWidget {
  const _WeekDots({required this.done, required this.goal});

  final int done;
  final int goal;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: List.generate(goal, (i) {
        final on = i < done;
        return Container(
          width: 8,
          height: 8,
          margin: const EdgeInsets.only(right: 6),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            // 못 채운 날은 비워 둘 뿐, 색으로 지적하지 않는다.
            color: on ? RefitTheme.glow : RefitTheme.panel,
          ),
        );
      }),
    );
  }
}

/// 비어 있을 때 **왜** 비었는지 말한다.
///
/// 그냥 "기록이 없어요" 로 끝내면, 훈련을 마쳤는데도 목록이 비어 있는
/// 경우(주인 없는 기록·저장소 미동작)에 사용자가 앱을 의심할 방법이 없다.
class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onChanged});

  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final orphans = gApp.unassignedSessions;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Text(
            '${gApp.patient?.name ?? '이 환자'} 님의 훈련 기록이 없어요.',
            style: RefitTheme.body,
            textAlign: TextAlign.center,
          ),
        ),
        if (!gApp.storePersistent) ...[
          const SizedBox(height: 20),
          RefitCard(
            tint: RefitTheme.alert,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('기록이 저장되지 않고 있어요',
                    style: RefitTheme.bodySmall.copyWith(
                      color: RefitTheme.ink,
                      fontWeight: FontWeight.w600,
                    )),
                const SizedBox(height: 8),
                Text(
                  '로컬 저장소를 열지 못해 이번 실행 중에만 기록이 남습니다. '
                  '설정 > 마지막 오류에서 원인을 볼 수 있어요.',
                  style: RefitTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
        if (orphans.isNotEmpty) ...[
          const SizedBox(height: 20),
          RefitCard(
            tint: RefitTheme.caution,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('환자가 지정되지 않은 기록 ${orphans.length}건',
                    style: RefitTheme.bodySmall.copyWith(
                      color: RefitTheme.ink,
                      fontWeight: FontWeight.w600,
                    )),
                const SizedBox(height: 8),
                Text(
                  '환자를 등록하기 전에 남은 기록이에요. '
                  '누구의 기록인지는 앱이 알 수 없어 그대로 두었습니다.',
                  style: RefitTheme.bodySmall,
                ),
                // 인정하더라도 **기록은 고치지 않는다.** 지금 환자의 id 를
                // 그 기록이 쓰던 id 로 옮길 뿐이다. 이미 자기 기록을 가진
                // 환자에게는 제안하지 않는다 — id 를 옮기는 순간 그쪽이
                // 주인을 잃는다.
                if (gApp.patientSessions.isEmpty) ...[
                  const SizedBox(height: 14),
                  RefitButton(
                    label: '${gApp.patient?.name ?? '이 환자'} 님의 기록이 맞아요',
                    filled: false,
                    onPressed: () async {
                      final n = await gApp.claimUnassignedSessions();
                      onChanged();
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(n > 0 ? '$n건을 이어받았어요' : '이어받지 못했어요'),
                        ),
                      );
                    },
                  ),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _ViewToggle extends StatelessWidget {
  const _ViewToggle({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: selected
                ? RefitTheme.glow.withValues(alpha: 0.16)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: selected
                  ? RefitTheme.glow.withValues(alpha: 0.5)
                  : RefitTheme.hairline,
            ),
          ),
          child: Text(
            label,
            style: RefitTheme.bodySmall.copyWith(
              fontSize: 14,
              color: selected ? RefitTheme.glow : RefitTheme.inkSoft,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
      ),
    );
  }
}

/// 세션 카드 한 장. 날짜 · 시간 · 쥔 횟수 · 신뢰도 등급 · 업로드 상태.
class SessionCard extends StatelessWidget {
  const SessionCard({super.key, required this.session});

  final SessionSummary session;

  @override
  Widget build(BuildContext context) {
    final s = session;
    final t = s.startedAt;
    return RefitCard(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => SessionDetailScreen(session: s),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '${t.month}월 ${t.day}일 '
                '${t.hour.toString().padLeft(2, '0')}:'
                '${t.minute.toString().padLeft(2, '0')}',
                style: RefitTheme.bodySmall.copyWith(
                  color: RefitTheme.ink,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              // 신뢰도 등급은 신호 품질이지 환자 성적이 아니다.
              RefitChip(
                label: '신뢰도 ${s.reliabilityGrade}',
                tone: switch (s.reliabilityGrade) {
                  'A' => RefitTheme.glow,
                  'B' => RefitTheme.caution,
                  _ => RefitTheme.tired,
                },
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Text('${s.repCount}번 · ${formatDurationKo(s.durationS)}',
                    style: RefitTheme.bodySmall),
              ),
              Icon(
                s.synced ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
                size: 18,
                color: RefitTheme.inkFaint,
              ),
              const SizedBox(width: 6),
              Text(
                s.synced ? '동기화됨' : '대기',
                style: RefitTheme.caption.copyWith(color: RefitTheme.inkFaint),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '${endReasonLabel(s.endReason)} · ${closingLineFor(s.endReason)}',
            style: RefitTheme.caption,
          ),
        ],
      ),
    );
  }
}

/// 달 단위 격자. 훈련한 날에 점이 찍힌다 — **연속 기록을 세지 않는다.**
/// 끊긴 날을 실패로 만들지 않기 위해서다.
class _CalendarView extends StatelessWidget {
  const _CalendarView({
    required this.sessions,
    required this.month,
    required this.onMonth,
  });

  final List<SessionSummary> sessions;
  final DateTime month;
  final ValueChanged<DateTime> onMonth;

  @override
  Widget build(BuildContext context) {
    final first = DateTime(month.year, month.month);
    final days = DateTime(month.year, month.month + 1, 0).day;
    // weekday: 월=1 … 일=7. 격자는 일요일부터 시작한다.
    final lead = first.weekday % 7;

    final byDay = <int, List<SessionSummary>>{};
    for (final s in sessions) {
      if (s.startedAt.year == month.year && s.startedAt.month == month.month) {
        (byDay[s.startedAt.day] ??= <SessionSummary>[]).add(s);
      }
    }

    final selectedMonth = byDay.values.expand((v) => v).toList()
      ..sort((a, b) => b.startedAt.compareTo(a.startedAt));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        RefitCard(
          child: Column(
            children: [
              Row(
                children: [
                  IconButton(
                    onPressed: () =>
                        onMonth(DateTime(month.year, month.month - 1)),
                    icon: const Icon(Icons.chevron_left_rounded),
                    color: RefitTheme.inkSoft,
                  ),
                  Expanded(
                    child: Text(
                      '${month.year}년 ${month.month}월',
                      textAlign: TextAlign.center,
                      style: RefitTheme.bodySmall.copyWith(
                        color: RefitTheme.ink,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () =>
                        onMonth(DateTime(month.year, month.month + 1)),
                    icon: const Icon(Icons.chevron_right_rounded),
                    color: RefitTheme.inkSoft,
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  for (final d in const ['일', '월', '화', '수', '목', '금', '토'])
                    Expanded(
                      child: Center(
                        child: Text(
                          d,
                          style: RefitTheme.bodySmall.copyWith(
                              fontSize: 12, color: RefitTheme.inkFaint),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate:
                    const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 7,
                  childAspectRatio: 1,
                ),
                itemCount: lead + days,
                itemBuilder: (_, i) {
                  if (i < lead) return const SizedBox.shrink();
                  final day = i - lead + 1;
                  final has = byDay.containsKey(day);
                  return Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        '$day',
                        style: RefitTheme.caption.copyWith(color: has ? RefitTheme.ink : RefitTheme.inkFaint,
                          fontWeight:
                              has ? FontWeight.w600 : FontWeight.w400),
                      ),
                      const SizedBox(height: 4),
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: has ? RefitTheme.glow : Colors.transparent,
                        ),
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
        const RefitSectionTitle('이 달의 기록'),
        if (selectedMonth.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 20),
            child: Text('이 달에는 기록이 없어요.',
                style: RefitTheme.bodySmall, textAlign: TextAlign.center),
          )
        else
          for (final s in selectedMonth)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: SessionCard(session: s),
            ),
      ],
    );
  }
}
