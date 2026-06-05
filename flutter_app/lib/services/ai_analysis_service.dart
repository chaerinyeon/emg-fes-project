import 'dart:convert';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

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

  /// 세션/이력 지표 스냅샷 → 자연어 분석 텍스트. 실패 시 예외.
  Future<String> analyze(Map<String, dynamic> data) async {
    const systemPrompt =
        '당신은 근전도(EMG) 기반 근피로 모니터링과 FES 재활을 돕는 분석 보조자입니다. '
        '입력에는 현재 세션 지표와 이 사용자의 누적 운동 기록(history)이 포함됩니다. '
        '다음을 한국어 불릿으로 간결하게 설명하세요: '
        '(1) 현재 근피로 상태 요약, '
        '(2) 누적 기록과 비교한 변화·추세(개인 baseline 대비), '
        '(3) 이 사용자에게 개인화된 권고 — 피로 판단 기준, 운동 강도, 자극 수준, 휴식 타이밍. '
        '반복 측정이 쌓일수록 더 정밀해진다는 점을 전제로 현재 데이터로 가능한 범위에서 해석하세요. '
        '의학적 확정 진단은 피하고, 값이 0/null 이면 측정 전이거나 데이터 부족으로 간주하세요.';

    final pretty = const JsonEncoder.withIndent('  ').convert(data);
    final content = await _chat(
      systemPrompt: systemPrompt,
      userPrompt: '다음은 현재 세션 지표와 누적 기록(JSON)입니다.\n$pretty',
    );
    return content.trim();
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

    final resp = await http.post(
      Uri.parse(_endpoint),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $_key',
      },
      body: jsonEncode(body),
    );

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
