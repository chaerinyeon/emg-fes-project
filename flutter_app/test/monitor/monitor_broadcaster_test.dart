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

/// `toString()` 자체가 던지는 예외.
///
/// 극단적으로 보이지만, 에러 경로가 **예외의 협조에 기대면 안 된다**는 것을
/// 고정하기 위한 것이다. 실기기에서 500 은 왔는데 본문이 비어 있었고, 그때
/// 후보 중 하나가 "메시지를 만들다가 또 던졌다" 였다.
class _HostileError implements Exception {
  @override
  String toString() => throw StateError('toString 도 실패');
}

MonitorBroadcaster _make({
  String token = '8134',
  Future<String?> Function()? ipLookup,
}) =>
    MonitorBroadcaster(
      pageLoader: () async => '<html><body>모니터</body></html>',
      helloBuilder: _hello,
      token: token,
      ipLookup: ipLookup,
    );

void main() {
  group('추가 라우트', _extraRouteTests);
  group('망이 바뀌었을 때 주소 갱신', _refreshTests);

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

// ── 추가 라우트 (기록 조회) ────────────────────────────────────────────
//
// 기록 조회는 앱의 저장소를 읽어야 하는 일이라 방송기 밖(extraHandler)에
// 산다. 방송기가 SessionStore 를 직접 알게 되면 이 클래스를 하드웨어·저장소
// 없이 테스트할 수 없다.
void _extraRouteTests() {
  MonitorBroadcaster make(
    Future<MonitorPayload?> Function(Uri) handler, {
    String token = '8134',
  }) =>
      MonitorBroadcaster(
        pageLoader: () async => '<html><body>모니터</body></html>',
        helloBuilder: _hello,
        token: token,
        extraHandler: handler,
      );

  Future<HttpClientResponse> get(int port, String path) async {
    final client = HttpClient();
    addTearDown(client.close);
    return (await client.getUrl(Uri.parse('http://127.0.0.1:$port$path')))
        .close();
  }

  test('추가 라우트가 본문과 콘텐츠 타입을 그대로 낸다', () async {
    final b = make((uri) async => uri.path == '/api/sessions'
        ? const MonitorPayload('{"sessions":[]}')
        : null);
    final ep = (await b.start())!;
    addTearDown(b.stop);

    final res = await get(ep.port, '/api/sessions?k=${ep.token}');
    expect(res.statusCode, 200);
    expect(res.headers.contentType!.mimeType, 'application/json');
    expect(await res.transform(utf8.decoder).join(), contains('sessions'));
  });

  test('처리기가 null 을 주면 404 다', () async {
    final b = make((_) async => null);
    final ep = (await b.start())!;
    addTearDown(b.stop);

    final res = await get(ep.port, '/api/nope?k=${ep.token}');
    expect(res.statusCode, 404);
  });

  // 기록에는 환자 이름과 훈련 이력이 들어 있다. 라이브 화면만 막고 조회
  // 라우트가 열려 있으면 토큰이 아무 의미가 없다.
  test('토큰 없이는 추가 라우트도 열리지 않는다', () async {
    var called = false;
    final b = make((_) async {
      called = true;
      return const MonitorPayload('{}');
    });
    final ep = (await b.start())!;
    addTearDown(b.stop);

    final res = await get(ep.port, '/api/sessions');
    expect(res.statusCode, 403);
    expect(called, isFalse, reason: '토큰 검사가 처리기보다 먼저다');
  });

  test('처리기가 던져도 서버는 살아 있다', () async {
    final b = make((uri) async {
      if (uri.path == '/boom') throw StateError('boom');
      return const MonitorPayload('{"ok":true}');
    });
    final ep = (await b.start())!;
    addTearDown(b.stop);

    await get(ep.port, '/boom?k=${ep.token}');
    final after = await get(ep.port, '/api/x?k=${ep.token}');
    expect(after.statusCode, 200);
  });

  // 예전에는 catch 가 statusCode 를 안 건드리고 응답만 닫았다. HttpResponse 의
  // 기본값이 200 이라 **성공처럼 보이는 빈 응답**이 나갔고, 웹은
  // "Unexpected end of JSON input" 만 보여 줬다 — 폰에서 무엇이 터졌는지
  // 알 방법이 아예 없었다.
  test('처리기가 던지면 200 이 아니라 500 이다', () async {
    final b = make((uri) async => throw StateError('boom'));
    final ep = (await b.start())!;
    addTearDown(b.stop);

    final res = await get(ep.port, '/api/sessions?k=${ep.token}');
    expect(res.statusCode, 500);
  });

  test('500 본문에 터진 이유가 적혀 있다', () async {
    final b = make((uri) async => throw StateError('가짜 저장소 오류'));
    final ep = (await b.start())!;
    addTearDown(b.stop);

    final res = await get(ep.port, '/api/sessions?k=${ep.token}');
    final body = await res.transform(utf8.decoder).join();
    expect(body, contains('가짜 저장소 오류'));
  });

  // 실기기에서 500 은 왔는데 본문이 비어 있었다. 테스트의 StateError 는
  // 본문이 실려 나갔으므로, 기기에서만 다른 것은 **예외의 종류**다.
  // 그래서 에러 경로가 예외 종류에 기대지 않게 만든다.
  test('toString 이 던지는 예외여도 본문이 비지 않는다', () async {
    final b = make((uri) async => throw _HostileError());
    final ep = (await b.start())!;
    addTearDown(b.stop);

    final res = await get(ep.port, '/api/sessions?k=${ep.token}');
    final body = await res.transform(utf8.decoder).join();

    expect(res.statusCode, 500);
    expect(body.trim(), isNotEmpty,
        reason: '이유를 못 만들더라도 최소한 타입 이름은 나와야 한다');
    expect(body, contains('_HostileError'));
  });

  test('본문이 비ASCII 여도 그대로 전달된다', () async {
    final b = make((uri) async => throw StateError('저장소 오류 — 상자가 없음'));
    final ep = (await b.start())!;
    addTearDown(b.stop);

    final res = await get(ep.port, '/api/sessions?k=${ep.token}');
    final body = await res.transform(utf8.decoder).join();
    expect(body, contains('상자가 없음'));
  });

  // 실기기에서 터진 진짜 원인.
  //
  // MonitorPayload 의 기본 content-type 은 `application/json` 으로 **charset 이
  // 없었다.** Dart 의 HttpResponse 는 charset 이 없으면 인코딩을 latin1 로
  // 잡고, 한글(코드포인트 > 255)에서 write() 가
  //   Invalid argument (string): Contains invalid characters.
  // 를 던진다. 환자 이름이 한글인 순간 `/api/sessions` 가 통째로 죽었다.
  //
  // charset 을 명시한 경로(`/records` 의 text/html; charset=utf-8, 403 의
  // ContentType.text)만 살아남아서, "HTML 은 되는데 API 만 안 된다"로 보였다.
  test('한글 본문이 기본 content-type 으로도 그대로 전달된다', () async {
    const body = '{"patient":"연","sessions":[]}';
    final b = make((uri) async => const MonitorPayload(body));
    final ep = (await b.start())!;
    addTearDown(b.stop);

    final res = await get(ep.port, '/api/sessions?k=${ep.token}');
    expect(res.statusCode, 200);
    expect(await res.transform(utf8.decoder).join(), body);
  });

  test('기본 content-type 이 charset 을 선언한다', () async {
    final b = make((uri) async => const MonitorPayload('{"ok":true}'));
    final ep = (await b.start())!;
    addTearDown(b.stop);

    final res = await get(ep.port, '/api/x?k=${ep.token}');
    expect(res.headers.contentType?.charset, 'utf-8');
  });

  test('이모지처럼 BMP 밖 문자도 깨지지 않는다', () async {
    const body = '{"note":"환자 🙂 기록"}';
    final b = make((uri) async => const MonitorPayload(body));
    final ep = (await b.start())!;
    addTearDown(b.stop);

    final res = await get(ep.port, '/api/x?k=${ep.token}');
    expect(await res.transform(utf8.decoder).join(), body);
  });

  test('페이지 로더가 던져도 500 이다', () async {
    final b = MonitorBroadcaster(
      pageLoader: () async => throw StateError('에셋 없음'),
      helloBuilder: _hello,
      token: '8134',
    );
    final ep = (await b.start())!;
    addTearDown(b.stop);

    final res = await get(ep.port, '/?k=${ep.token}');
    expect(res.statusCode, 500);
  });
}

// 폰이 Wi-Fi 를 옮기면 화면에 적힌 IP 는 그 순간 거짓이 된다. 서버 자체는
// anyIPv4 에 붙어 있어 새 망에서도 그대로 듣고 있으므로, 재바인딩 없이
// 표시할 주소만 다시 잡으면 된다.
void _refreshTests() {
  test('IP 가 바뀌면 엔드포인트가 새 IP 를 쓴다', () async {
    var ip = '192.168.1.180';
    final b = _make(ipLookup: () async => ip);
    final first = (await b.start())!;
    addTearDown(b.stop);
    expect(first.ip, '192.168.1.180');

    ip = '172.30.1.44';
    final second = (await b.refreshAddress())!;

    expect(second.ip, '172.30.1.44');
    expect(b.endpoint!.ip, '172.30.1.44');
    expect(b.url, 'http://172.30.1.44:${first.port}/?k=8134');
  });

  // 포트와 토큰이 바뀌면 이미 열어 둔 브라우저 탭이 403 을 받는다.
  test('갱신해도 포트와 토큰은 그대로다', () async {
    var ip = '192.168.1.180';
    final b = _make(token: '9855', ipLookup: () async => ip);
    final first = (await b.start())!;
    addTearDown(b.stop);

    ip = '172.30.1.44';
    final second = (await b.refreshAddress())!;

    expect(second.port, first.port);
    expect(second.token, '9855');
  });

  test('갱신 뒤에도 서버는 같은 포트에서 계속 응답한다', () async {
    var ip = '192.168.1.180';
    final b = _make(ipLookup: () async => ip);
    final ep = (await b.start())!;
    addTearDown(b.stop);

    ip = '172.30.1.44';
    await b.refreshAddress();

    final client = HttpClient();
    addTearDown(client.close);
    final req = await client
        .getUrl(Uri.parse('http://127.0.0.1:${ep.port}/?k=${ep.token}'));
    final res = await req.close();
    expect(res.statusCode, 200);
    await res.drain<void>();
  });

  test('IP 조회가 실패하면 엔드포인트의 ip 는 null 이 된다', () async {
    var ip = '192.168.1.180';
    final b = _make(ipLookup: () async => ip.isEmpty ? null : ip);
    await b.start();
    addTearDown(b.stop);

    ip = '';
    final after = (await b.refreshAddress())!;

    expect(after.ip, isNull);
    expect(after.url, isNull);
  });

  test('서버가 안 떠 있으면 갱신은 null 을 준다', () async {
    final b = _make(ipLookup: () async => '172.30.1.44');
    expect(await b.refreshAddress(), isNull);
  });
}
