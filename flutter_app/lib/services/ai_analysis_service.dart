import 'dart:convert';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

/// OpenAI API 기반 근피로 세션 분석.
/// .env 의 OPENAI_API_KEY 를 사용한다.
class AiAnalysisService {
  static const _endpoint = 'https://api.openai.com/v1/chat/completions';
  static const _model = 'gpt-4o-mini';

  /// .env 에 키가 있는지 — UI 에서 버튼 활성/안내에 사용.
  static bool get hasKey {
    final k = dotenv.isInitialized ? dotenv.maybeGet('OPENAI_API_KEY') : null;
    return k != null && k.isNotEmpty;
  }

  /// [data] 는 home_page 가 만든 세션 지표 스냅샷.
  /// 자연어 분석 텍스트를 반환. 실패 시 예외를 던진다.
  Future<String> analyze(Map<String, dynamic> data) async {
    final key = dotenv.isInitialized ? dotenv.maybeGet('OPENAI_API_KEY') : null;
    if (key == null || key.isEmpty) {
      throw Exception('OPENAI_API_KEY 가 .env 에 없습니다.');
    }

    const systemPrompt =
        '당신은 근전도(EMG) 기반 근피로 모니터링 데이터를 해석하는 재활의학 분석 보조자입니다. '
        '주어진 세션 지표를 바탕으로 (1) 현재 근피로 상태 요약, (2) 주요 근거(RMS/MDF/slope/M-wave/관리도), '
        '(3) FES 자극·휴식에 대한 권고를 한국어로 간결하게 항목별(불릿)로 설명하세요. '
        '의학적 확정 진단은 피하고 관찰 데이터에 근거한 해석임을 전제로 하세요. '
        '값이 0이거나 null 이면 아직 측정 전이거나 데이터가 부족하다는 의미입니다.';

    final pretty = const JsonEncoder.withIndent('  ').convert(data);

    final resp = await http.post(
      Uri.parse(_endpoint),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $key',
      },
      body: jsonEncode({
        'model': _model,
        'temperature': 0.4,
        'messages': [
          {'role': 'system', 'content': systemPrompt},
          {
            'role': 'user',
            'content': '다음은 현재 측정 세션의 지표(JSON)입니다.\n$pretty',
          },
        ],
      }),
    );

    if (resp.statusCode != 200) {
      final body = utf8.decode(resp.bodyBytes);
      throw Exception('API 오류 ${resp.statusCode}: $body');
    }

    final json = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    final choices = json['choices'] as List?;
    if (choices == null || choices.isEmpty) {
      throw Exception('응답이 비어 있습니다.');
    }
    final content = choices.first['message']?['content'] as String?;
    if (content == null || content.trim().isEmpty) {
      throw Exception('응답 본문이 비어 있습니다.');
    }
    return content.trim();
  }
}
