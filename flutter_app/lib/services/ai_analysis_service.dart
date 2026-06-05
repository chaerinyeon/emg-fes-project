import 'dart:async';
import 'dart:convert';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

/// 신호/종합 상태 — UI 색상/배지에 매핑.
enum ReportStatus { fatigued, caution, ok, unknown }

ReportStatus parseReportStatus(Object? v) {
  final s = '$v'.toLowerCase().trim();
  if (s.contains('fatig') || s.contains('피로')) return ReportStatus.fatigued;
  if (s.contains('caution') || s.contains('warn') || s.contains('주의')) {
    return ReportStatus.caution;
  }
  if (s.contains('ok') ||
      s.contains('good') ||
      s.contains('normal') ||
      s.contains('양호') ||
      s.contains('정상')) {
    return ReportStatus.ok;
  }
  return ReportStatus.unknown;
}

/// 개별 신호(RMS/MDF/M-wave 등)의 피로 상태.
class AiSignal {
  final String name;
  final ReportStatus status;
  final String? note;
  const AiSignal({required this.name, required this.status, this.note});

  factory AiSignal.fromJson(Map<String, dynamic> j) => AiSignal(
        name: (j['name'] as String?) ?? '신호',
        status: parseReportStatus(j['status']),
        note: j['note'] as String?,
      );
}

/// 구조화된 AI 분석 리포트 (AI분석 탭용).
class AiReport {
  final ReportStatus status; // 종합 상태
  final String headline; // 한 줄 요약
  final List<AiSignal> signals; // 신호별 상태 (불일치 시각화)
  final List<String> observations; // 관찰
  final List<String> recommendations; // 권고

  const AiReport({
    required this.status,
    required this.headline,
    this.signals = const [],
    this.observations = const [],
    this.recommendations = const [],
  });

  static List<String> _strList(Object? v) =>
      (v as List?)
          ?.map((e) => '$e')
          .where((s) => s.trim().isNotEmpty)
          .toList() ??
      const <String>[];

  factory AiReport.fromJson(Map<String, dynamic> j) => AiReport(
        status: parseReportStatus(j['status']),
        headline: (j['headline'] as String?)?.trim() ?? '분석 결과',
        signals: (j['signals'] as List?)
                ?.whereType<Map>()
                .map((m) => AiSignal.fromJson(m.cast<String, dynamic>()))
                .toList() ??
            const [],
        observations: _strList(j['observations']),
        recommendations: _strList(j['recommendations']),
      );
}

/// AI 개인화 권장 결과 (운동 전 바텀시트용).
class AiRecommendation {
  final int? intensity; // 권장 강도 % (40~90)
  final List<String> reasons; // 근거 불릿
  final String? fatigueCriteria; // 개인화된 피로 판단 기준
  final String? exerciseIntensity; // 운동 강도 제안
  final String? stimulationLevel; // 자극 수준 제안
  final String? restTiming; // 휴식 타이밍 제안

  const AiRecommendation({
    this.intensity,
    this.reasons = const [],
    this.fatigueCriteria,
    this.exerciseIntensity,
    this.stimulationLevel,
    this.restTiming,
  });

  factory AiRecommendation.fromJson(Map<String, dynamic> j) {
    final raw = j['recommendedIntensity'];
    int? intensity;
    if (raw is num) intensity = raw.round().clamp(40, 90);
    final reasons = (j['reasons'] as List?)
            ?.map((e) => '$e')
            .where((s) => s.trim().isNotEmpty)
            .toList() ??
        const <String>[];
    return AiRecommendation(
      intensity: intensity,
      reasons: reasons,
      fatigueCriteria: j['fatigueCriteria'] as String?,
      exerciseIntensity: j['exerciseIntensity'] as String?,
      stimulationLevel: j['stimulationLevel'] as String?,
      restTiming: j['restTiming'] as String?,
    );
  }
}

/// OpenAI API 기반 근피로 분석 + 개인화 권장.
/// .env 의 OPENAI_API_KEY 를 사용한다.
///
/// 누적된 이전 운동 기록(세션 수, baseline, 피로 시점 slope 이력 등)을 함께
/// 전달하여, 반복 측정이 쌓일수록 사용자별 피로 패턴에 맞춘 피로 판단 기준 ·
/// 운동 강도 · 자극 수준 · 휴식 타이밍을 개인화하도록 유도한다.
class AiAnalysisService {
  static const _endpoint = 'https://api.openai.com/v1/chat/completions';
  static const _model = 'gpt-4o-mini';

  /// .env 에 키가 있는지 — UI 에서 버튼 활성/안내에 사용.
  static bool get hasKey {
    final k = dotenv.isInitialized ? dotenv.maybeGet('OPENAI_API_KEY') : null;
    return k != null && k.isNotEmpty;
  }

  String get _key {
    final k = dotenv.isInitialized ? dotenv.maybeGet('OPENAI_API_KEY') : null;
    if (k == null || k.isEmpty) {
      throw Exception('OPENAI_API_KEY 가 .env 에 없습니다.');
    }
    return k;
  }

  /// 세션/이력 지표 스냅샷 → 구조화된 분석 리포트(JSON). 실패 시 예외.
  Future<AiReport> analyze(Map<String, dynamic> data) async {
    const systemPrompt =
        '당신은 근전도(EMG) 기반 근피로 모니터링과 FES 재활을 돕는 분석 보조자입니다. '
        '입력에는 현재 세션 지표와 이 사용자의 누적 운동 기록(history)이 포함됩니다. '
        '중요: M-wave(자극 응답 EMG)와 표면 EMG(RMS/MDF)는 서로 다른 피로 기전을 반영하므로 '
        '한쪽만 피로로 나타날 수 있습니다. 각 신호의 상태를 개별적으로 판정하고, '
        '신호 간 불일치가 있으면 headline 과 observations 에 분명히 명시하세요. '
        '종합 status 는 가장 심각한 신호와 전체 맥락을 함께 고려해 정하세요. '
        '입력에 todayResult 가 있으면 이번 운동 결과를 평소와 비교해 구체적으로 서술하세요. '
        '예: timeToFatigueSec 가 usualTimeToFatigueSec 보다 작으면 "평소보다 약 N분 빨리 피로해졌어요", '
        '크면 "평소보다 오래 버텼어요"; today*SlopePct 절대값이 usual* 보다 크게 차이나면 '
        '"평소보다 큰 폭으로 피로해졌어요" 처럼 분(分) 단위로 환산해 headline 과 observations 에 넣으세요. '
        'priorSessionCount 가 0~1 이면 비교 대상이 부족하다고 명시하세요. '
        '의학적 확정 진단은 피하고, 값이 0/null 이면 측정 전이거나 데이터 부족으로 간주하세요. '
        '반드시 아래 JSON 형식으로만, 한국어로, 짧고 직관적으로 답하세요:\n'
        '{\n'
        '  "status": "fatigued | caution | ok",\n'
        '  "headline": "한 줄 핵심 요약(20자 내외)",\n'
        '  "signals": [\n'
        '    {"name": "RMS (근활성도)", "status": "fatigued|caution|ok", "note": "한 줄"},\n'
        '    {"name": "MDF (주파수)", "status": "...", "note": "한 줄"},\n'
        '    {"name": "M-wave (자극응답)", "status": "...", "note": "한 줄"}\n'
        '  ],\n'
        '  "observations": ["관찰 2~4개(누적 기록 대비 변화 포함)"],\n'
        '  "recommendations": ["권고 2~4개(강도/자극/휴식)"]\n'
        '}';

    final pretty = const JsonEncoder.withIndent('  ').convert(data);
    final content = await _chat(
      systemPrompt: systemPrompt,
      userPrompt: '다음은 현재 세션 지표와 누적 기록(JSON)입니다.\n$pretty',
      jsonMode: true,
    );
    return AiReport.fromJson(jsonDecode(content) as Map<String, dynamic>);
  }

  /// 누적 기록 + 오늘 컨디션/초기 EMG → 개인화 권장 강도(JSON).
  Future<AiRecommendation> recommend(Map<String, dynamic> data) async {
    const systemPrompt =
        '당신은 EMG 기반 재활 운동 코치입니다. 입력에는 사용자의 누적 운동 기록(history), '
        '오늘 컨디션, 초기 휴식 EMG 가 포함됩니다. 이 사용자에게 오늘 적절한 운동 강도(%)를 '
        '산출하고, 누적 데이터에서 드러나는 개인 피로 패턴에 맞춰 피로 판단 기준 · 운동 강도 · '
        '자극 수준 · 휴식 타이밍을 개인화해 제안하세요. 기록이 적으면 보수적으로 권장하세요. '
        '반드시 아래 JSON 형식으로만, 한국어로 답하세요:\n'
        '{\n'
        '  "recommendedIntensity": <40~90 사이 정수>,\n'
        '  "reasons": ["핵심 근거 2~4개"],\n'
        '  "fatigueCriteria": "개인화된 피로 판단 기준",\n'
        '  "exerciseIntensity": "운동 강도 제안",\n'
        '  "stimulationLevel": "자극 수준 제안",\n'
        '  "restTiming": "휴식 타이밍 제안"\n'
        '}';

    final pretty = const JsonEncoder.withIndent('  ').convert(data);
    final content = await _chat(
      systemPrompt: systemPrompt,
      userPrompt: '다음은 사용자 누적 기록과 오늘 입력(JSON)입니다.\n$pretty',
      jsonMode: true,
    );
    final parsed = jsonDecode(content) as Map<String, dynamic>;
    return AiRecommendation.fromJson(parsed);
  }

  // ---------- 공통 호출 ----------
  Future<String> _chat({
    required String systemPrompt,
    required String userPrompt,
    bool jsonMode = false,
  }) async {
    final body = <String, dynamic>{
      'model': _model,
      'temperature': 0.4,
      'messages': [
        {'role': 'system', 'content': systemPrompt},
        {'role': 'user', 'content': userPrompt},
      ],
      if (jsonMode) 'response_format': {'type': 'json_object'},
    };

    http.Response resp;
    try {
      resp = await http
          .post(
            Uri.parse(_endpoint),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $_key',
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 30));
    } on TimeoutException {
      throw Exception('요청 시간이 초과됐어요. 네트워크 상태를 확인한 뒤 다시 시도하세요.');
    } catch (e) {
      final s = e.toString();
      if (s.contains('SocketException') ||
          s.contains('Failed host lookup') ||
          s.contains('Network is unreachable') ||
          s.contains('Connection')) {
        throw Exception('인터넷에 연결할 수 없어요. 기기의 네트워크 연결을 확인한 뒤 다시 시도하세요.');
      }
      rethrow;
    }

    if (resp.statusCode != 200) {
      throw Exception('API 오류 ${resp.statusCode}: ${utf8.decode(resp.bodyBytes)}');
    }
    final json = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    final choices = json['choices'] as List?;
    String? content;
    if (choices != null && choices.isNotEmpty) {
      final msg = choices.first['message'];
      if (msg is Map) content = msg['content'] as String?;
    }
    if (content == null || content.trim().isEmpty) {
      throw Exception('응답이 비어 있습니다.');
    }
    return content;
  }
}
