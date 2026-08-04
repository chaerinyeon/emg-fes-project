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
import 'dart:math';

import 'monitor_address.dart';
import 'monitor_frame.dart';

/// 시도할 포트 범위(양끝 포함).
const int kMonitorPortFirst = 8080;
const int kMonitorPortLast = 8090;

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
    Random? rng,
  }) : _rng = rng ?? Random();

  /// HTML 본문 공급자. 앱에서는 에셋 번들, 테스트에서는 문자열 상수.
  final Future<String> Function() pageLoader;

  /// 새 클라이언트에게 보낼 hello 를 그때그때 만든다.
  final MonitorHello Function() helloBuilder;

  final Random _rng;

  HttpServer? _server;
  MonitorEndpoint? _endpoint;
  final List<WebSocket> _clients = [];

  MonitorEndpoint? get endpoint => _endpoint;

  int get clientCount => _clients.length;

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
        token: makeToken(_rng),
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
    for (final ws in List<WebSocket>.from(_clients)) {
      try {
        await ws.close();
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
        req.response.statusCode = HttpStatus.forbidden;
        req.response.write('forbidden');
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
    _clients.add(ws);
    _send(ws, jsonEncode(helloBuilder().toJson()));
    ws.listen(
      (_) {},
      onDone: () => _clients.remove(ws),
      onError: (_) => _clients.remove(ws),
      cancelOnError: true,
    );
  }

  void _send(WebSocket ws, String msg) {
    try {
      ws.add(msg);
    } catch (_) {
      _clients.remove(ws);
    }
  }
}
