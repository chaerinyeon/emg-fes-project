import 'package:flutter/material.dart';

import '../../services/ai_analysis_service.dart';

/// AI 분석 탭 본문. 버튼 → 로딩 → 결과/에러 표시.
/// 실제 데이터 수집/호출은 [onRequest] 콜백(home_page)이 담당.
class AiAnalysisPanel extends StatefulWidget {
  /// 세션 스냅샷을 만들어 AI 분석 결과(자연어)를 반환한다.
  final Future<String> Function() onRequest;

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
  String? _result;
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
                      : '현재까지의 RMS·MDF·slope·M-wave·관리도·수축 지표를 OpenAI로 보내 '
                          '자연어 해석과 권고를 받습니다.',
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
                      : (_postWorkout ? '다시 분석' : 'AI 분석 요청')),
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
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: SelectableText(
                _result!,
                style: const TextStyle(
                  fontSize: 13,
                  height: 1.5,
                  color: Colors.black87,
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}
