import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../services/profile_service.dart';

/// 세션 시작 전 개인화 셋업 다이얼로그.
/// - 활성 프로파일의 과거 기록 요약 표시
/// - 오늘 컨디션 선택 (좋음/보통/피곤함) → 관리도 sigma 배수 조정
/// - 확인 시 [TodayCondition] 반환, 취소 시 null
Future<TodayCondition?> showSessionSetupDialog(
  BuildContext context, {
  required UserProfile? profile,
  TodayCondition initial = TodayCondition.normal,
}) {
  return showDialog<TodayCondition>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _SessionSetupDialog(profile: profile, initial: initial),
  );
}

class _SessionSetupDialog extends StatefulWidget {
  final UserProfile? profile;
  final TodayCondition initial;
  const _SessionSetupDialog({required this.profile, required this.initial});

  @override
  State<_SessionSetupDialog> createState() => _SessionSetupDialogState();
}

class _SessionSetupDialogState extends State<_SessionSetupDialog> {
  late TodayCondition _condition;

  @override
  void initState() {
    super.initState();
    _condition = widget.initial;
  }

  String _fmt(double? v, [int frac = 1]) =>
      v == null ? '—' : v.toStringAsFixed(frac);

  String _lastSessionRel(String? iso) {
    if (iso == null) return '없음';
    try {
      final dt = DateTime.parse(iso);
      final d = DateTime.now().difference(dt);
      if (d.inDays > 0) return '${d.inDays}일 전';
      if (d.inHours > 0) return '${d.inHours}시간 전';
      if (d.inMinutes > 0) return '${d.inMinutes}분 전';
      return '방금';
    } catch (_) {
      return '—';
    }
  }

  double? _mean(List<double> xs) =>
      xs.isEmpty ? null : xs.reduce((a, b) => a + b) / xs.length;

  @override
  Widget build(BuildContext context) {
    final p = widget.profile;
    final lastRmsSlope = p == null ? null : _mean(p.recentFatigueRmsSlopes);
    final lastMdfSlope = p == null ? null : _mean(p.recentFatigueMdfSlopes);

    return AlertDialog(
      icon: Icon(
        Icons.tune,
        size: 32,
        color: Colors.blue.shade600,
      ),
      title: const Text(
        '오늘 세션 셋업',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
      contentPadding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ---- 환자 ----
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black12,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Icon(Icons.person_outline, size: 16, color: Colors.black54),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      p?.name ?? '프로파일 없음',
                      style: const TextStyle(
                          color: Colors.black87, fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                  ),
                  if (p?.category != null)
                    Text(
                      p!.category!.label,
                      style: const TextStyle(color: Colors.black45, fontSize: 11),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            // ---- 과거 기록 요약 ----
            const Text(
              '지난 기록',
              style: TextStyle(color: Colors.black54, fontSize: 11),
            ),
            const SizedBox(height: 4),
            _statRow('세션 횟수', '${p?.sessionCount ?? 0}회'),
            _statRow('마지막 세션', _lastSessionRel(p?.lastSessionAt)),
            _statRow('휴식 RMS 평균', _fmt(p?.restingRms)),
            _statRow('MDF baseline', '${_fmt(p?.mdfBaseline)} Hz'),
            _statRow('MVC RMS', _fmt(p?.mvcRms)),
            _statRow('평균 피로 시점 RMS slope',
                lastRmsSlope == null ? '—' : '+${lastRmsSlope.toStringAsFixed(1)}%'),
            _statRow('평균 피로 시점 MDF slope',
                lastMdfSlope == null ? '—' : '${lastMdfSlope.toStringAsFixed(1)}%'),

            const Divider(height: 22, color: Colors.black26),

            // ---- 오늘 컨디션 ----
            const Text(
              '오늘 컨디션',
              style: TextStyle(color: Colors.black54, fontSize: 11),
            ),
            const SizedBox(height: 6),
            Row(
              children: TodayCondition.values
                  .map((c) => Expanded(child: _conditionChip(c)))
                  .toList(),
            ),
            const SizedBox(height: 10),

            // ---- 오늘 적용 설정 미리보기 ----
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.blue.shade600.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                    color: Colors.blue.shade600.withValues(alpha: 0.3)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '오늘 적용 측정 설정',
                    style: TextStyle(
                        color: Colors.blue.shade600,
                        fontSize: 11,
                        fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  _statRow('관리도 폭', 'mean ± 2σ (5초 지속)'),
                  _statRow('거짓 경보율', '약 4.6% (1/22), 5초 지속으로 억제'),
                  _statRow('초기 학습 표본', '8점 (자극 중 RMS/MDF)'),
                  _statRow('판정 방식', 'RMS > UCL  AND  MDF < LCL'),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_condition),
          child: const Text('세션 시작'),
        ),
      ],
    );
  }

  Widget _statRow(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            Expanded(
              child: Text(k,
                  style: const TextStyle(color: Colors.black54, fontSize: 11)),
            ),
            Text(v,
                style: const TextStyle(
                    color: Colors.black87,
                    fontSize: 12,
                    fontWeight: FontWeight.w600)),
          ],
        ),
      );

  Widget _conditionChip(TodayCondition c) {
    final selected = _condition == c;
    return GestureDetector(
      onTap: () => setState(() => _condition = c),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 3),
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: selected
              ? Colors.blue.shade600.withValues(alpha: 0.2)
              : Colors.black12,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected
                ? Colors.blue.shade600
                : Colors.black26,
            width: selected ? 1.6 : 1,
          ),
        ),
        child: Center(
          child: Text(
            c.label,
            style: TextStyle(
              color: selected ? Colors.blue.shade600 : Colors.black54,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}
