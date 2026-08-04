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

class MonitorBroadcaster {
  MonitorBroadcaster({
    required this.pageLoader,
    required this.helloBuilder,
    required this.token,
  });

  /// HTML 본문 공급자. 앱에서는 에셋 번들, 테스트에서는 문자열 상수.
  final Future<String> Function() pageLoader;

  /// 새 클라이언트에게 보낼 hello 를 그때그때 만든다.
  final MonitorHello Function() helloBuilder;

  /// 접속 토큰. 세션 전체에서 고정 — 호출자([GameScreen])가 [makeToken] 으로
  /// 한 번만 만들어 넘긴다. 여기서 매번 새로 만들면(과거 동작) 백그라운드
  /// 복귀로 방송기가 재생성될 때마다 URL 이 바뀌어, 이미 열어 둔 브라우저
  /// 탭이 403 을 받고 치료사가 주소를 다시 입력해야 했다.
  final String token;

  HttpServer? _server;
  MonitorEndpoint? _endpoint;
  final List<_Client> _clients = [];
  Timer? _drain;

  /// 클라이언트당 대기열 상한. 10 Hz 기준 2초치.
  static const int _outboxCapacity = 20;

  MonitorEndpoint? get endpoint => _endpoint;

  int get clientCount => _clients.length;

  /// 10 Hz 관찰 프레임.
  void pushTick(MonitorTick f) => _broadcast(f.toJson());

  /// 이산 사건(수축·존 전환·피로·휴식·세션).
  void pushEvent(MonitorEvent e) => _broadcast(e.toJson());

  /// BLE 연결 상태. 웹은 이것과 소켓 끊김을 구분해서 표시한다.
  void pushLink(String state) => _broadcast({'t': 'link', 'state': state});

  /// RAW 1kHz 파형 100표본 묶음. **구독한 클라이언트에게만** 간다.
  void pushRaw(int firstSampleMs, List<int> samples) {
    if (!_clients.any((c) => c.wantsRaw)) return;
    final msg = _encode({'t': 'raw', 'i': firstSampleMs, 'v': samples});
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
        ip: await localIpv4(),
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
        req.response.write(
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
        req.response.write(body);
        await req.response.close();
        return;
      }
      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
    } catch (_) {
      try {
        await req.response.close();
      } catch (_) {}
    }
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
