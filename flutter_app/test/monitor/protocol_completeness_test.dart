// 프로토콜 완전성 — MonitorSource 가 낼 수 있는 이벤트 kind 전부를
// monitor.html 이 알고 있는지 정적으로 대조한다.
//
// Finding 3(fatigue 가 조용히 버려짐)와 Finding 4(rest_start/rest_end 를
// 아무도 안 보냄)는 둘 다 같은 모양의 버그였다 — Dart 쪽(MonitorSource)엔
// kind 가 있는데 웹(monitor.html)이 그 문자열을 모른다. 그리고 이전에
// `MonitorBroadcaster.pushRaw` 가 실제로는 아무도 안 부르는 채로 남아 있던
// 것도 같은 계열의 "배선이 끊긴 줄 아무도 모른다" 사고였다.
//
// 이 테스트는 그 클래스의 재발을 정적으로 막는다: monitor_source.dart 안의
// `MonitorEvent('kind', ...)` 리터럴 전부를 정규식으로 모으고, monitor.html
// 의 `m.kind === "kind"` 분기 전부를 모아 두 집합이 같은지 비교한다. 실제
// 브라우저나 소켓 없이 텍스트만 본다 — 새 kind 를 추가하고 웹 쪽 분기를
// 깜빡하면(또는 그 반대) 이 테스트가 코드 리뷰 없이도 즉시, 정확한 이름과
// 함께 실패한다.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('MonitorSource 가 emit 하는 event kind 전부를 monitor.html 이 처리한다',
      () {
    final sourceFile = File('lib/monitor/monitor_source.dart');
    final htmlFile = File('assets/web/monitor.html');
    expect(sourceFile.existsSync(), isTrue,
        reason: '${sourceFile.path} 를 찾지 못했다 — 작업 디렉터리가 '
            'flutter_app/ 인지 확인하라.');
    expect(htmlFile.existsSync(), isTrue, reason: htmlFile.path);

    final sourceText = sourceFile.readAsStringSync();
    final htmlText = htmlFile.readAsStringSync();

    // Dart 쪽 — sink.event(MonitorEvent('kind', ...)) 리터럴 전부.
    final emitted = RegExp(r"MonitorEvent\('([a-z_]+)'")
        .allMatches(sourceText)
        .map((m) => m.group(1)!)
        .toSet();

    // 웹 쪽 — onMessage() 의 event 분기가 명시적으로 비교하는 kind 전부.
    final handled = RegExp(r'm\.kind\s*===\s*"([a-z_]+)"')
        .allMatches(htmlText)
        .map((m) => m.group(1)!)
        .toSet();

    // 정규식 자체가 무력화(예: 리팩터로 리터럴 표기가 바뀜)되지 않았는지
    // 확인한다 — 그렇지 않으면 이 테스트는 두 집합이 우연히 둘 다 비어서
    // 항상 통과하는 죽은 테스트가 된다.
    expect(emitted, isNotEmpty,
        reason: 'monitor_source.dart 에서 MonitorEvent(\'kind\', ...) 리터럴을 '
            '하나도 못 찾았다 — 정규식이 코드 형태 변화를 못 따라가고 있을 '
            '수 있다.');
    expect(handled, isNotEmpty,
        reason: 'monitor.html 에서 m.kind === "..." 분기를 하나도 못 찾았다 — '
            '정규식이 코드 형태 변화를 못 따라가고 있을 수 있다.');

    final missingInHtml = emitted.difference(handled);
    final extraInHtml = handled.difference(emitted);

    expect(missingInHtml, isEmpty,
        reason: 'monitor.html 이 처리하지 않는 kind: $missingInHtml — '
            'MonitorSource 는 이 kind 를 내보내지만 웹은 조용히 버린다. '
            'Finding 3·4 와 같은 모양의 버그다.');
    expect(extraInHtml, isEmpty,
        reason: 'monitor.html 이 MonitorSource 가 절대 내보내지 않는 kind 를 '
            '처리하고 있다: $extraInHtml — 오타이거나 이미 이름이 바뀐 죽은 '
            '코드일 가능성이 높다.');
  });
}
