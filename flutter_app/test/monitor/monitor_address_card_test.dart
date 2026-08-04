import 'package:flutter/material.dart';
import 'package:flutter_app/monitor/monitor_broadcaster.dart';
import 'package:flutter_app/widgets/monitor/monitor_address_card.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('주소와 토큰을 보여준다', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: MonitorAddressCard(
          endpoint: MonitorEndpoint(ip: '192.168.0.12', port: 8080, token: '8134'),
        ),
      ),
    ));

    expect(find.textContaining('192.168.0.12:8080'), findsOneWidget);
    expect(find.textContaining('8134'), findsOneWidget);
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
