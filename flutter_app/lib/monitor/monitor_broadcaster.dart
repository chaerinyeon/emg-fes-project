/// 폰이 띄우는 로컬 관찰 서버.
///
/// `GET /`   → 단일 HTML 페이지
/// `GET /ws` → WebSocket. 접속 즉시 hello, 이후 tick/event/link/raw.
///
/// ## 모니터가 죽어도 세션은 죽지 않는다
///
/// 이 클래스의 모든 예외는 여기서 삼킨다. 포트가 없든 Wi-Fi 가 끊겼든 게임과
/// 자극 경로에는 아무 영향이 없어야 한다. 실패는 [start] 가 null 을 돌려주는
/// 것으로만 드러난다.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'monitor_address.dart';
import 'monitor_frame.dart';

/// 시도할 포트 범위(양끝 포함).
const int kMonitorPortFirst = 8080;
const int kMonitorPortLast = 8090;

/// 클라이언트별 송신 대기열.
///
/// ## 왜 오래된 것부터 버리는가
///
/// 실시간 관찰 화면에 밀린 과거 프레임은 가치가 음수다. 치료사는 "지금"을
/// 봐야 하는데, 큐가 밀리면 화면이 과거를 현재인 척 그린다. 그래서 넘치면
/// 최신을 남기고 오래된 것을 버린다.
class Outbox {
  Outbox(this.capacity) : assert(capacity > 0);

  final int capacity;
  final List<String> _q = [];
  int _dropped = 0;

  /// 넘쳐서 버린 누적 개수 — 진단용.
  int get dropped => _dropped;

  int get length => _q.length;

  void add(String msg) {
    _q.add(msg);
    while (_q.length > capacity) {
      _q.removeAt(0);
      _dropped++;
    }
  }

  /// 다음 메시지. 없으면 null.
  String? next() => _q.isEmpty ? null : _q.removeAt(0);
}

/// 접속 정보. [ip] 는 조회 실패 시 null 이지만 서버 자체는 떠 있다.
class MonitorEndpoint {
  const MonitorEndpoint({required this.ip, required this.port, required this.token});

  final String? ip;
  final int port;
  final String token;

  /// 브라우저에 입력할 주소. IP 를 못 찾았으면 null.
  String? get url =>
      ip == null ? null : monitorUrl(ip: ip!, port: port, token: token);
}

/// `/` · `/ws` 밖의 경로가 돌려주는 것.
class MonitorPayload {
  /// [contentType] 기본값에 **charset 이 반드시 들어간다.**
  ///
  /// 예전 기본값은 `application/json` 이었다. charset 이 없으면 Dart 의
  /// [HttpResponse] 가 인코딩을 `latin1` 로 잡고, 코드포인트 255 를 넘는 문자
  /// — 즉 한글 한 글자 — 에서 `write()` 가
  /// `Invalid argument (string): Contains invalid characters.` 를 던진다.
  ///
  /// 환자 이름이 한글인 순간 `/api/sessions` 가 통째로 죽었다. charset 을
  /// 명시한 경로(`/records` 의 `text/html; charset=utf-8`, 403 응답의
  /// [ContentType.text])만 살아남아 "HTML 은 되는데 API 만 안 된다"로 보였다.
  const MonitorPayload(
    this.body, {
    this.contentType = 'application/json; charset=utf-8',
  });

  final String body;
  final String contentType;
}

class MonitorBroadcaster {
  MonitorBroadcaster({
    required this.pageLoader,
    required this.helloBuilder,
    required this.token,
    this.extraHandler,
    this.onError,
    Future<String?> Function()? ipLookup,
  }) : _ipLookup = ipLookup ?? localIpv4;

  /// 요청 처리 중 예외가 났을 때 불린다. **응답과 별개의 경로**다.
  ///
  /// 500 본문만으로는 부족하다 — 브라우저가 옛 페이지를 캐시하고 있거나
  /// 응답이 중간에 끊기면 그 한 줄이 아무 데도 도달하지 않는다. 그러면
  /// "폰 안에서 무언가 터졌다"는 사실만 남고 무엇인지는 영영 모른다.
  final void Function(Uri uri, Object error)? onError;

  /// HTML 본문 공급자. 앱에서는 에셋 번들, 테스트에서는 문자열 상수.
  final Future<String> Function() pageLoader;

  /// 새 클라이언트에게 보낼 hello 를 그때그때 만든다.
  final MonitorHello Function() helloBuilder;

  /// `/` · `/ws` 가 아닌 경로 처리기. null 을 돌려주면 404.
  ///
  /// 기록 조회처럼 **앱의 저장소를 읽어야 하는 것**을 여기로 뺀다. 방송기는
  /// 소켓과 프레임만 알아야 한다 — [SessionStore] 를 직접 알게 되면 이
  /// 클래스를 하드웨어·저장소 없이 테스트할 수 없다.
  ///
  /// 토큰 검사는 이 콜백이 불리기 전에 이미 끝나 있다.
  final Future<MonitorPayload?> Function(Uri uri)? extraHandler;

  /// 접속 토큰. 세션 전체에서 고정 — 호출자([GameScreen])가 [makeToken] 으로
  /// 한 번만 만들어 넘긴다. 여기서 매번 새로 만들면(과거 동작) 백그라운드
  /// 복귀로 방송기가 재생성될 때마다 URL 이 바뀌어, 이미 열어 둔 브라우저
  /// 탭이 403 을 받고 치료사가 주소를 다시 입력해야 했다.
  final String token;

  /// 표시할 IP 를 구하는 방법. 테스트에서 망 변경을 흉내내려고 갈아끼운다.
  final Future<String?> Function() _ipLookup;

  HttpServer? _server;
  MonitorEndpoint? _endpoint;
  final List<_Client> _clients = [];
  Timer? _drain;

  /// 클라이언트당 대기열 상한. 10 Hz 기준 2초치.
  static const int _outboxCapacity = 20;

  MonitorEndpoint? get endpoint => _endpoint;

  /// 브라우저에 입력할 주소. 서버가 없거나 IP 를 못 찾았으면 null.
  String? get url => _endpoint?.url;

  int get clientCount => _clients.length;

  /// 10 Hz 관찰 프레임.
  void pushTick(MonitorTick f) => _broadcast(f.toJson());

  /// 이산 사건(수축·존 전환·피로·휴식·세션).
  void pushEvent(MonitorEvent e) => _broadcast(e.toJson());

  /// BLE 연결 상태. 웹은 이것과 소켓 끊김을 구분해서 표시한다.
  void pushLink(String state) => _broadcast({'t': 'link', 'state': state});

  /// RAW 1kHz 파형 100표본 묶음. **구독한 클라이언트에게만** 간다.
  void pushRaw(int firstSampleIndex, List<int> samples) {
    if (!_clients.any((c) => c.wantsRaw)) return;
    final msg = _encode({'t': 'raw', 'i': firstSampleIndex, 'v': samples});
    if (msg == null) return;
    for (final c in _clients) {
      if (c.wantsRaw) c.outbox.add(msg);
    }
  }

  void _broadcast(Map<String, dynamic> json) {
    final msg = _encode(json);
    if (msg == null) return;
    for (final c in _clients) {
      c.outbox.add(msg);
    }
  }

  /// 인코딩 실패(EMG 값이 NaN·Infinity 등 비정상일 때)는 이 프레임 하나만
  /// 버린다. 세션·자극 경로로 예외를 흘려보내지 않는다 — 웹은 tick 이 끊긴
  /// 걸로 보고 알아서 회색으로 죽는다.
  String? _encode(Map<String, dynamic> json) {
    try {
      return jsonEncode(json);
    } catch (_) {
      return null;
    }
  }

  /// 서버를 띄운다. 실패하면 null — 호출자는 배너만 띄우고 세션을 계속한다.
  Future<MonitorEndpoint?> start() async {
    if (_server != null) return _endpoint;

    HttpServer? server;
    for (var port = kMonitorPortFirst; port <= kMonitorPortLast; port++) {
      try {
        server = await HttpServer.bind(InternetAddress.anyIPv4, port);
        break;
      } on SocketException {
        continue; // 점유된 포트 — 다음으로
      } catch (_) {
        return null;
      }
    }
    if (server == null) return null;

    try {
      final endpoint = MonitorEndpoint(
        ip: await _ipLookup(),
        port: server.port,
        token: token,
      );
      _server = server;
      _endpoint = endpoint;
      server.listen(_handle, onError: (_) {}, cancelOnError: false);
      return _endpoint;
    } catch (_) {
      // 엔드포인트 구성이나 리스닝이 실패해도 이미 바인딩된 소켓을 남기지
      // 않는다 — 남기면 idempotent 체크가 그 좀비 서버를 영원히 돌려준다.
      try {
        await server.close(force: true);
      } catch (_) {}
      _server = null;
      _endpoint = null;
      return null;
    }
  }

  /// 표시할 주소를 **지금 망 기준으로** 다시 잡는다. 서버는 건드리지 않는다.
  ///
  /// ## 왜 재바인딩하지 않는가
  ///
  /// 서버는 [InternetAddress.anyIPv4] 에 붙어 있으므로 폰이 Wi-Fi 를 옮겨도
  /// 새 망에서 그대로 듣고 있다. 거짓이 되는 것은 화면에 적힌 IP 문자열
  /// 하나뿐이다. 소켓을 다시 열면 포트가 바뀔 수 있고 — 포트가 바뀌면 이미
  /// 열어 둔 브라우저 탭이 죽는다. 그래서 [MonitorEndpoint] 의 ip 만 갈아끼운다.
  ///
  /// 서버가 안 떠 있으면 null.
  Future<MonitorEndpoint?> refreshAddress() async {
    final server = _server;
    if (server == null) return null;
    String? ip;
    try {
      ip = await _ipLookup();
    } catch (_) {
      return _endpoint; // 조회 실패는 옛 주소를 그대로 두는 것으로 삼킨다
    }
    if (ip == _endpoint?.ip) return _endpoint;
    _endpoint = MonitorEndpoint(ip: ip, port: server.port, token: token);
    return _endpoint;
  }

  Future<void> stop() async {
    _drain?.cancel();
    _drain = null;
    for (final c in List<_Client>.from(_clients)) {
      try {
        await c.socket.close();
      } catch (_) {}
    }
    _clients.clear();
    try {
      await _server?.close(force: true);
    } catch (_) {}
    _server = null;
    _endpoint = null;
  }

  // ── 요청 처리 ────────────────────────────────────────────────────
  Future<void> _handle(HttpRequest req) async {
    try {
      if (!_tokenOk(req)) {
        // 예전엔 본문이 그냥 "forbidden" 이었다 — host:port 만 입력하면
        // 이 응답만 보이고 왜 막혔는지, 뭘 더 넣어야 하는지 알 길이
        // 없었다(Important 7). 접속 URL 자체가 이미 `?k=<코드>` 를 담고
        // 있으므로(폰 화면의 MonitorAddressCard), 정상 경로로는 이 분기를
        // 탈 일이 드물지만 — host:port 만 따로 옮겨 적었을 때를 위해 설명한다.
        req.response.statusCode = HttpStatus.forbidden;
        req.response.headers.contentType = ContentType.text;
        _writeUtf8(
          req.response,
          'forbidden — 접속 코드가 없거나 틀렸습니다. '
          'URL 끝에 ?k=<4자리 접속코드> 를 붙여서 다시 접속하세요.\n'
          '예) http://<이 주소>:<포트>/?k=1234',
        );
        await req.response.close();
        return;
      }
      if (req.uri.path == '/ws') {
        await _upgrade(req);
        return;
      }
      if (req.uri.path == '/' || req.uri.path == '/index.html') {
        final body = await pageLoader();
        req.response.headers.contentType = ContentType.html;
        req.response.headers.set('Cache-Control', 'no-store');
        _writeUtf8(req.response, body);
        await req.response.close();
        return;
      }
      final extra = await extraHandler?.call(req.uri);
      if (extra != null) {
        req.response.headers.contentType = ContentType.parse(extra.contentType);
        req.response.headers.set('Cache-Control', 'no-store');
        _writeUtf8(req.response, extra.body);
        await req.response.close();
        return;
      }

      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
    } catch (e) {
      // ## 왜 500 을 굳이 만들어 보내는가
      //
      // 예전에는 여기서 응답을 그냥 닫았다. [HttpResponse.statusCode] 의
      // 기본값이 200 이라 **성공처럼 보이는 빈 응답**이 나갔고, 웹은
      // `Unexpected end of JSON input` 만 띄웠다. 폰 안에서 무엇이 터졌는지
      // 알 방법이 브라우저 쪽에는 아예 없었다 — 치료사도 개발자도 눈이 먼다.
      //
      // 이 서버는 접속 코드가 걸린 로컬 네트워크 전용이고, 여기 실리는 것은
      // 스택 트레이스가 아니라 예외 한 줄이다. 진단 불가로 시간을 태우는
      // 쪽이 훨씬 비싸다.
      // 폰 자신의 로그에도 남긴다. 브라우저가 옛 페이지를 들고 있거나 응답이
      // 중간에 끊기면 웹 경로 하나만으로는 원인을 영영 못 본다.
      // 콜백이 던지면 이 catch 를 뚫고 나가 응답이 영영 닫히지 않는다 —
      // 클라이언트는 오류 대신 무한 대기를 본다. 진단 경로가 장애를 키우면 안 된다.
      try {
        onError?.call(req.uri, e);
      } catch (_) {}

      // ## 이유 문자열을 만드는 것도 실패할 수 있다
      //
      // 예외의 `toString()` 이 다시 던지면 여기서 통째로 빠져나가 본문이
      // 비고, 클라이언트에는 **500 만 남고 이유는 사라진다.** 실기기에서
      // 정확히 그 일이 일어났다 — 브라우저는 자기 오류 페이지를 띄웠고
      // 폰 안에서 무엇이 터졌는지 아무도 알 수 없었다.
      //
      // 에러 경로는 예외의 협조에 기대면 안 된다. 최소한 타입 이름은 남긴다.
      String reason;
      try {
        reason = e.toString();
      } catch (_) {
        try {
          reason = e.runtimeType.toString();
        } catch (_) {
          reason = '알 수 없는 오류';
        }
      }

      try {
        req.response.statusCode = HttpStatus.internalServerError;
        req.response.headers.contentType = ContentType.text;
        // 인코딩 협상(charset)에 기대지 않고 바이트로 직접 넣는다.
        req.response.add(utf8.encode('서버 오류 — $reason'));
      } catch (_) {
        // 헤더가 이미 나갔거나(부분 전송) 소켓이 죽었다. 상태 코드를 바꿀 수
        // 없으니 조용히 닫는 것 말고 할 수 있는 일이 없다.
      }
      try {
        await req.response.close();
      } catch (_) {}
    }
  }

  /// 본문을 **UTF-8 바이트로 직접** 넣는다.
  ///
  /// [HttpResponse.write] 는 헤더의 charset 을 보고 인코딩을 고르고, charset 이
  /// 없으면 latin1 로 떨어진다 — 한글 한 글자에 던진다. 호출부가 charset 을
  /// 빠뜨렸는지에 결과가 좌우되면 안 되므로, 협상을 아예 건너뛴다.
  static void _writeUtf8(HttpResponse res, String body) {
    res.add(utf8.encode(body));
  }

  bool _tokenOk(HttpRequest req) {
    final expected = _endpoint?.token;
    if (expected == null) return false;
    return req.uri.queryParameters['k'] == expected;
  }

  Future<void> _upgrade(HttpRequest req) async {
    final ws = await WebSocketTransformer.upgrade(req);
    final client = _Client(ws, Outbox(_outboxCapacity));
    _clients.add(client);

    // hello 는 대기열을 거치지 않고 즉시 보낸다 — 첫 메시지여야 하기 때문이다.
    try {
      ws.add(jsonEncode(helloBuilder().toJson()));
    } catch (_) {
      _clients.remove(client);
      return;
    }

    ws.listen(
      (msg) => _onClientMessage(client, msg),
      onDone: () => _clients.remove(client),
      onError: (_) => _clients.remove(client),
      cancelOnError: true,
    );
    _startDrain();
  }

  /// 웹에서 오는 메시지 화이트리스트.
  ///
  /// 받아들이는 것은 `{"t":"sub","raw":<bool>}` 하나뿐이다. 이것은 제어가 아니라
  /// 구독이다 — 자극·세션·강도에 손대지 않는다. 그 외 모든 입력은 조용히 버린다.
  void _onClientMessage(_Client c, dynamic msg) {
    if (msg is! String) return;
    try {
      final j = jsonDecode(msg);
      if (j is! Map) return;
      if (j['t'] != 'sub') return;
      c.wantsRaw = j['raw'] == true;
    } catch (_) {
      // 파싱 실패는 무시한다. 웹은 신뢰 경계 밖이다.
    }
  }

  void _startDrain() {
    _drain ??= Timer.periodic(const Duration(milliseconds: 16), (_) {
      for (final c in List<_Client>.from(_clients)) {
        // 한 틱에 최대 4개까지만 흘려 한 클라이언트가 루프를 독점하지 않게 한다.
        for (var i = 0; i < 4; i++) {
          final msg = c.outbox.next();
          if (msg == null) break;
          try {
            c.socket.add(msg);
          } catch (_) {
            _clients.remove(c);
            break;
          }
        }
      }
    });
  }
}

class _Client {
  _Client(this.socket, this.outbox);

  final WebSocket socket;
  final Outbox outbox;

  /// 진단 패널을 펼친 클라이언트만 RAW 를 받는다.
  bool wantsRaw = false;
}
