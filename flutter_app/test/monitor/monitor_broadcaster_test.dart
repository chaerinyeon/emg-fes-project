import 'dart:convert';
import 'dart:io';

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
      link: null,
      ticks: [],
    );

MonitorBroadcaster _make({String token = '8134'}) => MonitorBroadcaster(
      pageLoader: () async => '<html><body>모니터</body></html>',
      helloBuilder: _hello,
      token: token,
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

  // 토큰은 호출자([GameScreen])가 makeToken() 으로 한 번만 만들어 넘긴다.
  // 여기서 다시 만들면 안 된다 — 백그라운드 복귀로 방송기가 재생성될 때마다
  // URL 이 바뀌어 치료사의 브라우저 탭이 403을 받는다 (Finding 5).
  test('전달받은 토큰을 그대로 쓰고 새로 만들지 않는다', () async {
    final b = _make(token: '4242');
    final ep = await b.start();
    addTearDown(b.stop);

    expect(ep!.token, '4242');
    expect(b.endpoint!.token, '4242');
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

  test('토큰이 없거나 틀리면 403 이고, 본문이 접속 코드 넣는 법을 알려준다 '
      '(Important 7)', () async {
    final b = _make();
    final ep = (await b.start())!;
    addTearDown(b.stop);

    final client = HttpClient();
    addTearDown(client.close);

    final noToken =
        await (await client.getUrl(Uri.parse('http://127.0.0.1:${ep.port}/')))
            .close();
    expect(noToken.statusCode, 403);
    final noTokenBody = await noToken.transform(utf8.decoder).join();
    expect(noTokenBody, contains('?k='),
        reason: '예전엔 본문이 그냥 "forbidden" 이었다 — host:port 만 입력한 '
            '치료사는 왜 막혔는지, 뭘 더 넣어야 하는지 알 길이 없었다');

    final wrong = await (await client
            .getUrl(Uri.parse('http://127.0.0.1:${ep.port}/?k=0000x')))
        .close();
    expect(wrong.statusCode, 403);
    final wrongBody = await wrong.transform(utf8.decoder).join();
    expect(wrongBody, contains('?k='));
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
    final client = HttpClient();
    addTearDown(client.close);
    await expectLater(
      client.getUrl(Uri.parse('http://127.0.0.1:${ep.port}/?k=${ep.token}')),
      throwsA(isA<SocketException>()),
    );
  });

  test('pushTick 이 접속한 클라이언트에게 전달된다', () async {
    final b = _make();
    final ep = (await b.start())!;
    addTearDown(b.stop);

    final ws = await WebSocket.connect(
        'ws://127.0.0.1:${ep.port}/ws?k=${ep.token}');
    addTearDown(() => ws.close());

    final got = <Map<String, dynamic>>[];
    final sub = ws.listen(
        (m) => got.add(jsonDecode(m as String) as Map<String, dynamic>));
    addTearDown(sub.cancel);

    await Future<void>.delayed(const Duration(milliseconds: 100));
    b.pushTick(const MonitorTick(
      t: 3.0, sigma: 1.2, sigmaPredicted: null,
      env: 1, rms: 2, mdf: 3, contractions: 4,
    ));
    await Future<void>.delayed(const Duration(milliseconds: 150));

    expect(got.first['t'], 'hello');
    expect(got.any((m) => m['t'] == 'tick' && m['ts'] == 3.0), isTrue);
  });

  test('raw 는 구독 전에는 안 가고 구독 후에 간다', () async {
    final b = _make();
    final ep = (await b.start())!;
    addTearDown(b.stop);

    final ws = await WebSocket.connect(
        'ws://127.0.0.1:${ep.port}/ws?k=${ep.token}');
    addTearDown(() => ws.close());

    final got = <Map<String, dynamic>>[];
    final sub = ws.listen(
        (m) => got.add(jsonDecode(m as String) as Map<String, dynamic>));
    addTearDown(sub.cancel);

    await Future<void>.delayed(const Duration(milliseconds: 100));
    b.pushRaw(0, const [1, 2, 3]);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(got.any((m) => m['t'] == 'raw'), isFalse);

    ws.add(jsonEncode({'t': 'sub', 'raw': true}));
    await Future<void>.delayed(const Duration(milliseconds: 150));
    b.pushRaw(100, const [4, 5, 6]);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(got.any((m) => m['t'] == 'raw' && m['i'] == 100), isTrue);
  });

  test('sub 외의 웹 메시지는 무시된다', () async {
    final b = _make();
    final ep = (await b.start())!;
    addTearDown(b.stop);

    final ws = await WebSocket.connect(
        'ws://127.0.0.1:${ep.port}/ws?k=${ep.token}');
    addTearDown(() => ws.close());

    final got = <Map<String, dynamic>>[];
    final sub = ws.listen(
        (m) => got.add(jsonDecode(m as String) as Map<String, dynamic>));
    addTearDown(sub.cancel);

    await Future<void>.delayed(const Duration(milliseconds: 100));
    // 제어를 시도하는 메시지 — 폰은 반응하지 않아야 한다.
    ws.add(jsonEncode({'t': 'cmd', 'cmd': 'stop'}));
    ws.add('쓰레기 문자열');
    await Future<void>.delayed(const Duration(milliseconds: 150));

    // 서버가 살아 있고 클라이언트도 유지된다.
    expect(b.clientCount, 1);
    b.pushEvent(const MonitorEvent('session_stop', 9.0));
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(got.any((m) => m['t'] == 'event' && m['kind'] == 'session_stop'),
        isTrue);
  });
}
