import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../services/ai_analysis_service.dart';
import '../../services/profile_service.dart';

const Color _accent = Color(0xFF2E7D32); // 차분한 초록 (cRms 계열)

/// 운동 전 셋업 결과 — home_page._startSession 이 사용.
class PreWorkoutResult {
  final TodayCondition condition;
  final int? recommendedIntensity; // AI 권장 강도 % (없을 수 있음)
  const PreWorkoutResult({required this.condition, this.recommendedIntensity});
}

/// 운동 시작 전 바텀시트:
///   기록 요약 · 오늘 컨디션 · 초기 EMG · AI 권장 강도(누적 기록 개인화)
/// "운동 시작하기" 시 [PreWorkoutResult] 반환, 닫으면 null.
Future<PreWorkoutResult?> showWorkoutSetupSheet(
  BuildContext context, {
  required UserProfile? profile,
  required AppStatus status,
  required TodayCondition initial,
  required Future<AiRecommendation> Function(
    TodayCondition condition,
    double? initEmg,
  ) onRecommend,
}) {
  return showModalBottomSheet<PreWorkoutResult>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (_) => _WorkoutSetupSheet(
      profile: profile,
      status: status,
      initial: initial,
      onRecommend: onRecommend,
    ),
  );
}

class _WorkoutSetupSheet extends StatefulWidget {
  final UserProfile? profile;
  final AppStatus status;
  final TodayCondition initial;
  final Future<AiRecommendation> Function(TodayCondition, double?) onRecommend;

  const _WorkoutSetupSheet({
    required this.profile,
    required this.status,
    required this.initial,
    required this.onRecommend,
  });

  @override
  State<_WorkoutSetupSheet> createState() => _WorkoutSetupSheetState();
}

class _WorkoutSetupSheetState extends State<_WorkoutSetupSheet> {
  late TodayCondition _condition = widget.initial;

  // 초기 EMG
  bool _measuring = false;
  bool _emgMeasured = false;
  double _initEmg = 0;

  // AI 권장
  bool _recommending = false;
  AiRecommendation? _rec;
  String? _recError;

  // ---------- 계산 (기록 요약용) ----------
  double? _mean(List<double> xs) =>
      xs.isEmpty ? null : xs.reduce((a, b) => a + b) / xs.length;

  int get _recoveryPct {
    final iso = widget.profile?.lastSessionAt;
    if (iso == null) return 100;
    try {
      final h = DateTime.now().difference(DateTime.parse(iso)).inMinutes / 60.0;
      return (h / 24.0 * 100).clamp(0, 100).round();
    } catch (_) {
      return 100;
    }
  }

  String _lastRel(String iso) {
    try {
      final d = DateTime.now().difference(DateTime.parse(iso));
      if (d.inDays > 0) return '${d.inDays}일 전';
      if (d.inHours > 0) return '${d.inHours}시간 전';
      if (d.inMinutes > 0) return '${d.inMinutes}분 전';
      return '방금';
    } catch (_) {
      return '—';
    }
  }

  // ---------- 액션 ----------
  Future<void> _measureEmg() async {
    setState(() => _measuring = true);
    await Future.delayed(const Duration(seconds: 3));
    if (!mounted) return;
    final b = widget.status.baselineRms;
    setState(() {
      _initEmg = b;
      _emgMeasured = b > 0;
      _measuring = false;
    });
  }

  Future<void> _runRecommend() async {
    setState(() {
      _recommending = true;
      _recError = null;
    });
    try {
      final r = await widget.onRecommend(
        _condition,
        _emgMeasured ? _initEmg : null,
      );
      if (!mounted) return;
      setState(() {
        _rec = r;
        _recommending = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _recError = '$e';
        _recommending = false;
      });
    }
  }

  void _finish() {
    Navigator.of(context).pop(
      PreWorkoutResult(condition: _condition, recommendedIntensity: _rec?.intensity),
    );
  }

  // ============================================================
  @override
  Widget build(BuildContext context) {
    final maxH = MediaQuery.of(context).size.height * 0.9;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxH),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('오늘 운동 시작',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              const Text('운동 전 상태를 확인해볼까요?',
                  style: TextStyle(color: Colors.black54, fontSize: 13)),
              const SizedBox(height: 16),

              _sectionLabel('지난 기록'),
              const SizedBox(height: 8),
              _recordSummary(),

              const SizedBox(height: 18),
              _sectionLabel('오늘 컨디션'),
              const SizedBox(height: 8),
              Row(
                children: TodayCondition.values
                    .map((c) => Expanded(child: _conditionChip(c)))
                    .toList(),
              ),

              const SizedBox(height: 18),
              _sectionLabel('초기 EMG'),
              const SizedBox(height: 8),
              _emgRow(),

              const SizedBox(height: 18),
              _sectionLabel('AI 권장 강도'),
              const SizedBox(height: 8),
              _recommendSection(),

              const SizedBox(height: 20),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: _accent,
                  minimumSize: const Size.fromHeight(50),
                ),
                onPressed: _finish,
                child: const Text('운동 시작하기',
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------- 기록 요약 ----------
  Widget _recordSummary() {
    final p = widget.profile;
    final slope = p == null ? null : _mean(p.recentFatigueRmsSlopes);
    final pct = _recoveryPct;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          children: [
            _statRow(Icons.bar_chart, '이전 운동',
                p?.lastSessionAt == null
                    ? '기록 없음'
                    : '${_lastRel(p!.lastSessionAt!)} · 누적 ${p.sessionCount}회'),
            const Divider(height: 18, color: Colors.black12),
            _statRow(Icons.show_chart, '최근 추세',
                slope == null ? '데이터 없음' : '피로 RMS slope +${slope.toStringAsFixed(0)}%'),
            const Divider(height: 18, color: Colors.black12),
            _statRow(Icons.health_and_safety_outlined, '회복 상태',
                '$pct% (${pct >= 80 ? '양호' : (pct >= 50 ? '보통' : '주의')})'),
          ],
        ),
      ),
    );
  }

  Widget _statRow(IconData icon, String k, String v) => Row(
        children: [
          Icon(icon, size: 18, color: _accent),
          const SizedBox(width: 10),
          Expanded(
            child: Text(k,
                style: const TextStyle(fontSize: 13, color: Colors.black87)),
          ),
          Text(v,
              style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Colors.black87)),
        ],
      );

  // ---------- 초기 EMG ----------
  Widget _emgRow() {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Expanded(
              child: Text(
                _measuring
                    ? '측정 중… (휴식 상태 유지)'
                    : _emgMeasured
                        ? '휴식 RMS ${_initEmg.toStringAsFixed(1)}'
                        : '휴식 상태 EMG 를 측정합니다',
                style: const TextStyle(fontSize: 12, color: Colors.black54),
              ),
            ),
            const SizedBox(width: 8),
            _measuring
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2.2),
                  )
                : OutlinedButton.icon(
                    onPressed: _measureEmg,
                    icon: Icon(_emgMeasured ? Icons.refresh : Icons.sensors,
                        size: 16),
                    label: Text(_emgMeasured ? '재측정' : 'EMG 측정'),
                  ),
          ],
        ),
      ),
    );
  }

  // ---------- AI 권장 강도 ----------
  Widget _recommendSection() {
    final rec = _rec;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (rec?.intensity != null) ...[
          Center(child: _gauge(rec!.intensity!)),
          const SizedBox(height: 12),
        ],
        if (rec != null) ...[
          _personalCard(rec),
          const SizedBox(height: 10),
        ],
        if (_recError != null) ...[
          Card(
            margin: EdgeInsets.zero,
            color: Colors.red.shade50,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text('분석 실패\n$_recError',
                  style:
                      TextStyle(color: Colors.red.shade700, fontSize: 12)),
            ),
          ),
          const SizedBox(height: 10),
        ],
        OutlinedButton.icon(
          onPressed: (_recommending || !AiAnalysisService.hasKey)
              ? null
              : _runRecommend,
          icon: _recommending
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.auto_awesome, size: 18),
          label: Text(_recommending
              ? '누적 기록 분석 중…'
              : (rec == null ? 'AI 권장 강도 분석' : '다시 분석')),
        ),
        if (!AiAnalysisService.hasKey)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('.env 에 OPENAI_API_KEY 가 없어 AI 권장을 사용할 수 없습니다.',
                style: TextStyle(color: Colors.orange.shade800, fontSize: 11)),
          ),
      ],
    );
  }

  Widget _personalCard(AiRecommendation r) {
    final items = <(String, String?)>[
      ('피로 판단 기준', r.fatigueCriteria),
      ('운동 강도', r.exerciseIntensity),
      ('자극 수준', r.stimulationLevel),
      ('휴식 타이밍', r.restTiming),
    ].where((e) => e.$2 != null && e.$2!.trim().isNotEmpty).toList();

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('개인화 권고',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            const SizedBox(height: 8),
            for (final reason in r.reasons)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.check, size: 16, color: _accent),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(reason,
                          style: const TextStyle(
                              fontSize: 12, color: Colors.black87)),
                    ),
                  ],
                ),
              ),
            if (items.isNotEmpty) ...[
              const Divider(height: 16, color: Colors.black12),
              for (final e in items)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(e.$1,
                          style: TextStyle(
                              color: _accent,
                              fontSize: 11,
                              fontWeight: FontWeight.w600)),
                      const SizedBox(height: 1),
                      Text(e.$2!,
                          style: const TextStyle(
                              fontSize: 12, color: Colors.black87)),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  // ---------- 공통 빌더 ----------
  Widget _sectionLabel(String t) => Text(t,
      style: const TextStyle(
          color: Colors.black54, fontSize: 12, fontWeight: FontWeight.w600));

  Widget _conditionChip(TodayCondition c) {
    final selected = _condition == c;
    return GestureDetector(
      onTap: () => setState(() => _condition = c),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        margin: const EdgeInsets.symmetric(horizontal: 4),
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: selected ? _accent.withValues(alpha: 0.12) : Colors.black12,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? _accent : Colors.black26,
            width: selected ? 1.6 : 1,
          ),
        ),
        child: Center(
          child: Text(
            c.label,
            style: TextStyle(
              color: selected ? _accent : Colors.black54,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }

  Widget _gauge(int pct) => SizedBox(
        width: 150,
        height: 150,
        child: Stack(
          alignment: Alignment.center,
          children: [
            SizedBox(
              width: 150,
              height: 150,
              child: CircularProgressIndicator(
                value: pct / 100,
                strokeWidth: 11,
                backgroundColor: _accent.withValues(alpha: 0.15),
                color: _accent,
                strokeCap: StrokeCap.round,
              ),
            ),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('권장 강도',
                    style: TextStyle(color: Colors.black54, fontSize: 12)),
                Text('$pct%',
                    style: const TextStyle(
                        fontSize: 36, fontWeight: FontWeight.bold)),
              ],
            ),
          ],
        ),
      );
}
