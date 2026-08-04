import 'package:flutter/material.dart';
import 'package:flutter_app/monitor/monitor_broadcaster.dart';
import 'package:flutter_app/widgets/monitor/monitor_address_card.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('작동하는 전체 URL(?k= 포함)을 주 텍스트로 보여준다 (Important 7)',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: MonitorAddressCard(
          endpoint: MonitorEndpoint(ip: '192.168.0.12', port: 8080, token: '8134'),
        ),
      ),
    ));

    // host:port 만으로는 본문 설명 없는 403 만 돌아온다 — 실제로 접속되는
    // 건 ?k= 가 붙은 전체 URL 이다. 그 문자열이 그대로 화면에 보여야
    // 치료사가 노트북 주소창에 타이핑(또는 복사)해서 바로 붙을 수 있다.
    expect(
      find.textContaining('http://192.168.0.12:8080/?k=8134'),
      findsOneWidget,
    );
  });

  testWidgets('IP 를 못 찾으면 비활성 문구를 보여준다', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: MonitorAddressCard(
          endpoint: MonitorEndpoint(ip: null, port: 8080, token: '8134'),
        ),
      ),
    ));

    expect(find.textContaining('Wi-Fi'), findsOneWidget);
  });

  testWidgets('endpoint 가 null 이면 모니터 비활성이다', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: MonitorAddressCard(endpoint: null)),
    ));

    expect(find.textContaining('모니터 비활성'), findsOneWidget);
  });
}
