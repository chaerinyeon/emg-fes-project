import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_app/monitor/monitor_broadcaster.dart';
import 'package:flutter_app/monitor/monitor_frame.dart';
import 'package:flutter_test/flutter_test.dart';

MonitorHello _hello() => const MonitorHello(
      session: '테스트',
      startedAtMs: 1000,
      mu0: 900.0,
      sd0: 45.0,
      t1: null,
      t2: null,
      t3: null,
      ticks: [],
    );

MonitorBroadcaster _make() => MonitorBroadcaster(
      pageLoader: () async => '<html><body>모니터</body></html>',
      helloBuilder: _hello,
      rng: Random(1),
    );

void main() {
  test('start 하면 엔드포인트와 토큰이 생긴다', () async {
    final b = _make();
    final ep = await b.start();
    addTearDown(b.stop);

    expect(ep, isNotNull);
    expect(ep!.port, inInclusiveRange(8080, 8090));
    expect(RegExp(r'^\d{4}$').hasMatch(ep.token), isTrue);
  });

  test('토큰이 맞으면 페이지를 준다', () async {
    final b = _make();
    final ep = (await b.start())!;
    addTearDown(b.stop);

    final client = HttpClient();
    addTearDown(client.close);
    final req = await client
        .getUrl(Uri.parse('http://127.0.0.1:${ep.port}/?k=${ep.token}'));
    final res = await req.close();

    expect(res.statusCode, 200);
    expect(await res.transform(utf8.decoder).join(), contains('모니터'));
  });

  test('토큰이 없거나 틀리면 403 이다', () async {
    final b = _make();
    final ep = (await b.start())!;
    addTearDown(b.stop);

    final client = HttpClient();
    addTearDown(client.close);

    final noToken =
        await (await client.getUrl(Uri.parse('http://127.0.0.1:${ep.port}/')))
            .close();
    expect(noToken.statusCode, 403);
    await noToken.drain<void>();

    final wrong = await (await client
            .getUrl(Uri.parse('http://127.0.0.1:${ep.port}/?k=0000x')))
        .close();
    expect(wrong.statusCode, 403);
    await wrong.drain<void>();
  });

  test('WS 로 붙으면 hello 를 먼저 받는다', () async {
    final b = _make();
    final ep = (await b.start())!;
    addTearDown(b.stop);

    final ws = await WebSocket.connect(
        'ws://127.0.0.1:${ep.port}/ws?k=${ep.token}');
    addTearDown(() => ws.close());

    final first = jsonDecode(await ws.first as String) as Map<String, dynamic>;
    expect(first['t'], 'hello');
    expect(first['session'], '테스트');
    expect(first['mu0'], 900.0);
  });

  test('포트가 점유되면 다음 포트로 넘어간다', () async {
    final blocker = await HttpServer.bind(InternetAddress.anyIPv4, 8080);
    addTearDown(() => blocker.close(force: true));

    final b = _make();
    final ep = await b.start();
    addTearDown(b.stop);

    expect(ep, isNotNull);
    expect(ep!.port, greaterThan(8080));
  });

  test('stop 하면 더 이상 접속되지 않는다', () async {
    final b = _make();
    final ep = (await b.start())!;
    await b.stop();

    expect(b.endpoint, isNull);
    await expectLater(
      HttpClient()
          .getUrl(Uri.parse('http://127.0.0.1:${ep.port}/?k=${ep.token}')),
      throwsA(isA<SocketException>()),
    );
  });
}
