import 'package:flutter/material.dart';

import '../../services/ai_analysis_service.dart';

/// AI 분석 탭 본문. 버튼/자동 → 로딩 → 구조화된 리포트/에러 표시.
/// 실제 데이터 수집/호출은 [onRequest] 콜백(home_page)이 담당.
class AiAnalysisPanel extends StatefulWidget {
  /// 세션 스냅샷을 만들어 구조화된 AI 리포트를 반환한다.
  final Future<AiReport> Function() onRequest;

  /// 값이 바뀌면(운동 종료 등) 자동으로 분석을 1회 실행한다. 0 이면 자동 실행 없음.
  final int autoRunTrigger;

  const AiAnalysisPanel({
    super.key,
    required this.onRequest,
    this.autoRunTrigger = 0,
  });

  @override
  State<AiAnalysisPanel> createState() => _AiAnalysisPanelState();
}

class _AiAnalysisPanelState extends State<AiAnalysisPanel> {
  bool _loading = false;
  AiReport? _result;
  String? _error;
  bool _postWorkout = false; // 운동 종료 자동 분석 여부 → 헤더 문구

  @override
  void didUpdateWidget(AiAnalysisPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 운동 종료 트리거 → 오늘의 운동 자동 분석.
    if (widget.autoRunTrigger != oldWidget.autoRunTrigger &&
        widget.autoRunTrigger > 0 &&
        AiAnalysisService.hasKey) {
      _postWorkout = true;
      _run();
    }
  }

  Future<void> _run() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await widget.onRequest();
      if (!mounted) return;
      setState(() {
        _result = r;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  // ---------- 상태 → 색/라벨/아이콘 ----------
  Color _color(ReportStatus s) => switch (s) {
        ReportStatus.fatigued => Colors.red.shade600,
        ReportStatus.caution => Colors.amber.shade800,
        ReportStatus.ok => Colors.green.shade700,
        ReportStatus.unknown => Colors.black45,
      };

  String _label(ReportStatus s) => switch (s) {
        ReportStatus.fatigued => '피로',
        ReportStatus.caution => '주의',
        ReportStatus.ok => '양호',
        ReportStatus.unknown => '—',
      };

  IconData _icon(ReportStatus s) => switch (s) {
        ReportStatus.fatigued => Icons.error_outline,
        ReportStatus.caution => Icons.warning_amber_rounded,
        ReportStatus.ok => Icons.check_circle_outline,
        ReportStatus.unknown => Icons.help_outline,
      };

  @override
  Widget build(BuildContext context) {
    final hasKey = AiAnalysisService.hasKey;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.auto_awesome,
                        size: 18, color: Colors.green.shade700),
                    const SizedBox(width: 6),
                    Text(
                      _postWorkout ? '오늘의 운동 분석' : 'AI 세션 분석',
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 14),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  _postWorkout
                      ? '운동이 종료되어 오늘 세션 데이터를 누적 기록과 함께 자동 분석했어요.'
                      : 'RMS·MDF·M-wave·관리도·수축 지표를 OpenAI로 보내 '
                          '신호별 상태와 권고를 받습니다.',
                  style: const TextStyle(color: Colors.black54, fontSize: 12),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: (_loading || !hasKey) ? null : _run,
                  icon: _loading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.psychology),
                  label: Text(_loading
                      ? '분석 중…'
                      : (_result != null ? '다시 분석' : 'AI 분석 요청')),
                ),
                if (!hasKey) ...[
                  const SizedBox(height: 8),
                  Text(
                    '.env 에 OPENAI_API_KEY 가 없어 분석을 사용할 수 없습니다.',
                    style:
                        TextStyle(color: Colors.orange.shade800, fontSize: 11),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Card(
            margin: EdgeInsets.zero,
            color: Colors.red.shade50,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                '분석 실패\n$_error',
                style: TextStyle(color: Colors.red.shade700, fontSize: 12),
              ),
            ),
          ),
        ],
        if (_result != null) ...[
          const SizedBox(height: 12),
          _reportView(_result!),
        ],
      ],
    );
  }

  // ---------- 구조화된 리포트 ----------
  Widget _reportView(AiReport r) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 종합 상태 헤더
        Card(
          margin: EdgeInsets.zero,
          color: _color(r.status).withValues(alpha: 0.10),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Icon(_icon(r.status), color: _color(r.status), size: 30),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '종합 — ${_label(r.status)}',
                        style: TextStyle(
                          color: _color(r.status),
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        r.headline,
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),

        // 신호별 상태 (RMS/MDF/M-wave 불일치가 한눈에)
        if (r.signals.isNotEmpty) ...[
          const SizedBox(height: 10),
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              child: Column(
                children: [
                  for (final s in r.signals) _signalRow(s),
                ],
              ),
            ),
          ),
        ],

        // 관찰
        if (r.observations.isNotEmpty) ...[
          const SizedBox(height: 10),
          _bulletCard('관찰', Icons.visibility_outlined, r.observations),
        ],

        // 권고
        if (r.recommendations.isNotEmpty) ...[
          const SizedBox(height: 10),
          _bulletCard('권고', Icons.tips_and_updates_outlined, r.recommendations),
        ],
      ],
    );
  }

  Widget _signalRow(AiSignal s) {
    final c = _color(s.status);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 10,
            height: 10,
            margin: const EdgeInsets.only(top: 3),
            decoration: BoxDecoration(color: c, shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(s.name,
                          style: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w600)),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: c.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(_label(s.status),
                          style: TextStyle(
                              color: c,
                              fontSize: 11,
                              fontWeight: FontWeight.w600)),
                    ),
                  ],
                ),
                if (s.note != null && s.note!.trim().isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(s.note!,
                      style: const TextStyle(
                          color: Colors.black54, fontSize: 12)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _bulletCard(String title, IconData icon, List<String> items) => Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, size: 16, color: Colors.black54),
                  const SizedBox(width: 6),
                  Text(title,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 13)),
                ],
              ),
              const SizedBox(height: 8),
              for (final it in items)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('· ',
                          style: TextStyle(
                              fontSize: 13, color: Colors.black54)),
                      Expanded(
                        child: Text(it,
                            style: const TextStyle(
                                fontSize: 13,
                                height: 1.4,
                                color: Colors.black87)),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      );
}
