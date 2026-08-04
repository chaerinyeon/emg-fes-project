# 모니터링 웹 분리 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 폰이 로컬 Wi-Fi로 단일 HTML 관찰 화면을 서빙하고 세션 데이터를 WebSocket으로 실시간 방송해, 치료사가 노트북 브라우저에서 같은 세션을 볼 수 있게 한다.

**Architecture:** `SessionController`(BLE) → `LiveFatigueFeed`(σ 계산) 까지는 기존 파이프라인 그대로. 거기에 `MonitorSource`(어댑터) → `MonitorBroadcaster`(dart:io HttpServer + WebSocket)를 두 번째 소비자로 붙인다. 웹은 폰이 계산한 σ·존·스태미나를 받아 **그리기만** 한다.

**Tech Stack:** Dart/Flutter (`dart:io` HttpServer·WebSocketTransformer — 외부 패키지 0), 단일 정적 HTML/JS(라이브러리 없음), `flutter_test`.

**설계 문서:** [2026-08-04-web-monitor-separation-design.md](../specs/2026-08-04-web-monitor-separation-design.md)

## Global Constraints

- **패키지 추가 금지.** `pubspec.yaml` 의 `dependencies` 에 아무것도 더하지 않는다. 서버는 `dart:io`, 웹은 순수 JS.
- **웹은 판정하지 않는다.** σ·존·스태미나·t1/t2/t3 는 전부 폰이 계산해 보내고, JS 는 받은 값을 그린다. `monitor.html` 에 SPC 규칙을 새로 구현하지 않는다.
- **웹은 보기 전용.** 폰이 웹에서 받아들이는 메시지는 `{"t":"sub", ...}` 하나뿐이고 나머지는 전부 무시한다(화이트리스트).
- **모니터 실패가 세션을 죽이지 않는다.** 방송기의 모든 예외는 방송기 안에서 삼킨다. 게임·자극 경로에 예외를 전파하지 않는다.
- 포트: 8080부터 8090까지 순차 시도.
- 토큰: 방송기가 시작될 때마다 새로 발급하는 랜덤 4자리 숫자. `GET /`·`GET /ws` 모두 `?k=` 로 검증, 불일치 시 403.
- 링버퍼: `tick` 프레임만 600개(10 Hz × 60초). `raw` 는 담지 않는다.
- 패키지 임포트 경로는 `package:flutter_app/...` 이다.
- 테스트 실행은 `flutter_app/` 디렉터리에서 한다.
- 한국어 주석·문구를 쓴다(기존 코드 관례).

---

## File Structure

| 파일 | 책임 | 태스크 |
|---|---|---|
| `lib/monitor/monitor_frame.dart` | 프레임 모델(`MonitorTick`/`MonitorEvent`/`MonitorHello`) + JSON + `FrameRing` | 1 |
| `lib/monitor/monitor_address.dart` | 로컬 IPv4 조회, 토큰 발급, 접속 URL 조립 | 2 |
| `lib/monitor/monitor_broadcaster.dart` | HTTP 서버·WS 업그레이드·토큰 검증·`Outbox` 백프레셔·구독 | 3, 4 |
| `lib/monitor/monitor_source.dart` | `LiveFatigueFeed`·`SessionController` → 프레임 어댑터 | 5 |
| `lib/services/session_controller.dart` | `adopt()` 추가 (BLE 단일 소유권) | 6 |
| `lib/screens/home_page.dart` | 게임 진입 시 세션 주입 + 방송기 기동 | 7 |
| `lib/widgets/monitor/monitor_address_card.dart` | 폰에 접속 주소·토큰 표시 | 7 |
| `assets/web/monitor.html` | 관찰 화면 — 라이브 + 재생 겸용 | 8, 9 |

`FrameRing` 을 `monitor_frame.dart` 에 같이 두는 이유: 링은 `MonitorTick` 만 알면 되고, 프레임의 정의와 보관은 함께 바뀐다. 파일을 하나 더 만들 만큼 독립적이지 않다.

---

### Task 1: MonitorTick · MonitorEvent · MonitorHello · FrameRing

프레임 모델과 링버퍼. 순수 Dart라 서버·소켓·Flutter 없이 테스트된다.

**Files:**
- Create: `flutter_app/lib/monitor/monitor_frame.dart`
- Test: `flutter_app/test/monitor/monitor_frame_test.dart`

**Interfaces:**
- Consumes: `package:flutter_app/game/model/zone.dart` 의 `FatigueZone`, `zoneOf(double)`, `staminaPercent(double)`
- Produces:
  - `class MonitorTick` — 생성자 `MonitorTick({required double t, double? sigma, double? sigmaPredicted, required double env, required double rms, required double mdf, required int contractions})`, `Map<String, dynamic> toJson()`, `factory MonitorTick.fromJson(Map<String, dynamic>)`, getter `FatigueZone? zone`, `double? stamina`
  - `class MonitorEvent` — `const MonitorEvent(String kind, double t, {int? zone})`, `Map<String, dynamic> toJson()`
  - `class MonitorHello` — `const MonitorHello({required String session, required int startedAtMs, required double? mu0, required double? sd0, required double? t1, required double? t2, required double? t3, required List<MonitorTick> ticks})`, `Map<String, dynamic> toJson()`
  - `class FrameRing` — `FrameRing(int capacity)`, `void add(MonitorTick)`, `List<MonitorTick> get frames`, `int get length`, `void clear()`

- [ ] **Step 1: 실패하는 테스트를 작성한다**

`flutter_app/test/monitor/monitor_frame_test.dart`:

```dart
import 'package:flutter_app/game/model/zone.dart';
import 'package:flutter_app/monitor/monitor_frame.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MonitorTick', () {
    test('JSON 왕복에서 값이 보존된다', () {
      const tick = MonitorTick(
        t: 12.5,
        sigma: 1.4,
        sigmaPredicted: 1.9,
        env: 120.0,
        rms: 210.5,
        mdf: 88.25,
        contractions: 7,
      );
      final back = MonitorTick.fromJson(tick.toJson());
      expect(back.t, 12.5);
      expect(back.sigma, 1.4);
      expect(back.sigmaPredicted, 1.9);
      expect(back.env, 120.0);
      expect(back.rms, 210.5);
      expect(back.mdf, 88.25);
      expect(back.contractions, 7);
    });

    test('태그가 tick 이다', () {
      const tick = MonitorTick(
        t: 0, sigma: null, sigmaPredicted: null,
        env: 0, rms: 0, mdf: 0, contractions: 0,
      );
      expect(tick.toJson()['t'], 'tick');
    });

    test('σ 가 null 이면 존과 스태미나도 null 이다', () {
      const tick = MonitorTick(
        t: 1, sigma: null, sigmaPredicted: null,
        env: 0, rms: 0, mdf: 0, contractions: 0,
      );
      expect(tick.zone, isNull);
      expect(tick.stamina, isNull);
      expect(tick.toJson().containsKey('zone'), isFalse);
    });

    test('존·스태미나는 zone.dart 규칙을 그대로 쓴다', () {
      const tick = MonitorTick(
        t: 1, sigma: 2.5, sigmaPredicted: null,
        env: 0, rms: 0, mdf: 0, contractions: 0,
      );
      expect(tick.zone, FatigueZone.warning);
      expect(tick.stamina, closeTo(staminaPercent(2.5), 1e-9));
      expect(tick.toJson()['zone'], FatigueZone.warning.index);
    });
  });

  group('MonitorEvent', () {
    test('kind·시각·존이 실린다', () {
      final e = MonitorEvent('fatigue', 42.0, zone: FatigueZone.danger.index);
      final j = e.toJson();
      expect(j['t'], 'event');
      expect(j['kind'], 'fatigue');
      expect(j['ts'], 42.0);
      expect(j['zone'], FatigueZone.danger.index);
    });
  });

  group('MonitorHello', () {
    test('링버퍼 프레임과 baseline 을 함께 싣는다', () {
      const tick = MonitorTick(
        t: 1, sigma: 0.5, sigmaPredicted: null,
        env: 0, rms: 0, mdf: 0, contractions: 1,
      );
      final hello = MonitorHello(
        session: '홍길동',
        startedAtMs: 1000,
        mu0: 900.0,
        sd0: 45.0,
        t1: 30.0,
        t2: null,
        t3: null,
        ticks: const [tick],
      );
      final j = hello.toJson();
      expect(j['t'], 'hello');
      expect(j['session'], '홍길동');
      expect(j['mu0'], 900.0);
      expect(j['t1'], 30.0);
      expect(j['t2'], isNull);
      expect((j['ticks'] as List).length, 1);
      expect((j['ticks'] as List).first['ts'], 1);
    });
  });

  group('FrameRing', () {
    test('용량을 넘으면 오래된 것부터 버린다', () {
      final ring = FrameRing(3);
      for (var i = 0; i < 5; i++) {
        ring.add(MonitorTick(
          t: i.toDouble(), sigma: null, sigmaPredicted: null,
          env: 0, rms: 0, mdf: 0, contractions: 0,
        ));
      }
      expect(ring.length, 3);
      expect(ring.frames.map((f) => f.t), [2.0, 3.0, 4.0]);
    });

    test('용량 이하면 전부 보존한다', () {
      final ring = FrameRing(600);
      ring.add(const MonitorTick(
        t: 1, sigma: null, sigmaPredicted: null,
        env: 0, rms: 0, mdf: 0, contractions: 0,
      ));
      expect(ring.length, 1);
    });
  });
}
```

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

Run: `cd flutter_app && flutter test test/monitor/monitor_frame_test.dart`
Expected: FAIL — `Target of URI doesn't exist: 'package:flutter_app/monitor/monitor_frame.dart'`

- [ ] **Step 3: 구현한다**

`flutter_app/lib/monitor/monitor_frame.dart`:

```dart
/// 웹 모니터로 보내는 프레임 정의.
///
/// ## 웹은 판정하지 않는다
///
/// σ·존·스태미나를 여기서 확정해 보낸다. `monitor.html` 은 SPC 규칙을 모른다.
/// 그래야 폰 게임과 웹 모니터가 같은 σ를 다른 존으로 표시하는 사고가 구조적으로
/// 불가능해진다. 존 경계를 바꾸려면 [FatigueZone] 한 곳만 고치면 된다.
library;

import 'dart:collection';

import '../game/model/zone.dart';

/// 10 Hz 로 흐르는 관찰 프레임 1개.
class MonitorTick {
  const MonitorTick({
    required this.t,
    required this.sigma,
    required this.sigmaPredicted,
    required this.env,
    required this.rms,
    required this.mdf,
    required this.contractions,
  });

  /// 세션 시작 기준 초.
  final double t;

  /// 현재 σ. baseline 확정 전이면 null — "정상"으로 단정하지 않는다.
  final double? sigma;

  /// 예측 σ (선제 경고용). 없으면 null.
  final double? sigmaPredicted;

  final double env;
  final double rms;
  final double mdf;

  /// 지금까지 관측된 수축(버스트) 수.
  final int contractions;

  /// σ 로부터의 존. σ 가 없으면 null.
  FatigueZone? get zone {
    final z = sigma;
    return z == null ? null : zoneOf(z);
  }

  /// 스태미나 %. σ 가 없으면 null.
  double? get stamina {
    final z = sigma;
    return z == null ? null : staminaPercent(z);
  }

  Map<String, dynamic> toJson() {
    final z = zone;
    return {
      't': 'tick',
      'ts': t,
      if (sigma != null) 'z': sigma,
      if (sigmaPredicted != null) 'zp': sigmaPredicted,
      if (z != null) 'zone': z.index,
      if (stamina != null) 'stam': stamina,
      'env': env,
      'rms': rms,
      'mdf': mdf,
      'n': contractions,
    };
  }

  factory MonitorTick.fromJson(Map<String, dynamic> j) => MonitorTick(
        t: (j['ts'] as num).toDouble(),
        sigma: (j['z'] as num?)?.toDouble(),
        sigmaPredicted: (j['zp'] as num?)?.toDouble(),
        env: (j['env'] as num).toDouble(),
        rms: (j['rms'] as num).toDouble(),
        mdf: (j['mdf'] as num).toDouble(),
        contractions: (j['n'] as num).toInt(),
      );
}

/// 이산 사건. kind 는 다음 중 하나다:
/// `session_start` `session_stop` `contraction` `zone` `fatigue`
/// `rest_start` `rest_end`
class MonitorEvent {
  const MonitorEvent(this.kind, this.t, {this.zone});

  final String kind;
  final double t;

  /// 존 전환·피로 사건에서의 [FatigueZone.index]. 그 외엔 null.
  final int? zone;

  Map<String, dynamic> toJson() => {
        't': 'event',
        'kind': kind,
        'ts': t,
        if (zone != null) 'zone': zone,
      };
}

/// 접속 직후 1회. 세션 메타 + baseline + 직전 60초 맥락.
///
/// 치료사가 세션 도중에 붙어도 빈 화면을 보지 않게 하는 것이 목적이다.
class MonitorHello {
  const MonitorHello({
    required this.session,
    required this.startedAtMs,
    required this.mu0,
    required this.sd0,
    required this.t1,
    required this.t2,
    required this.t3,
    required this.ticks,
  });

  final String session;
  final int startedAtMs;

  /// baseline 중앙값·견고 표준편차. 확정 전이면 null.
  final double? mu0;
  final double? sd0;

  /// 1σ/2σ/3σ 지속 도달 시각(초). 아직이면 null.
  final double? t1;
  final double? t2;
  final double? t3;

  final List<MonitorTick> ticks;

  Map<String, dynamic> toJson() => {
        't': 'hello',
        'session': session,
        'startedAtMs': startedAtMs,
        'mu0': mu0,
        'sd0': sd0,
        't1': t1,
        't2': t2,
        't3': t3,
        'ticks': [for (final f in ticks) f.toJson()],
      };
}

/// 고정 용량 링버퍼. 넘치면 오래된 것부터 버린다.
class FrameRing {
  FrameRing(this.capacity) : assert(capacity > 0);

  final int capacity;
  final Queue<MonitorTick> _q = Queue<MonitorTick>();

  void add(MonitorTick f) {
    _q.addLast(f);
    while (_q.length > capacity) {
      _q.removeFirst();
    }
  }

  List<MonitorTick> get frames => List.unmodifiable(_q);

  int get length => _q.length;

  void clear() => _q.clear();
}
```

- [ ] **Step 4: 테스트가 통과하는지 확인한다**

Run: `cd flutter_app && flutter test test/monitor/monitor_frame_test.dart`
Expected: PASS — All tests passed.

- [ ] **Step 5: 커밋한다**

```bash
git add flutter_app/lib/monitor/monitor_frame.dart flutter_app/test/monitor/monitor_frame_test.dart
git commit -m "feat(monitor): 관찰 프레임 모델 + 60초 링버퍼

웹은 판정하지 않는다 — σ·존·스태미나를 폰에서 확정해 실어보낸다."
```

---

### Task 2: MonitorAddress — 로컬 IPv4 · 토큰 · 접속 URL

치료사가 노트북에 입력할 주소를 만든다.

**Files:**
- Create: `flutter_app/lib/monitor/monitor_address.dart`
- Test: `flutter_app/test/monitor/monitor_address_test.dart`

**Interfaces:**
- Produces:
  - `Future<String?> localIpv4()` — 사설망 IPv4 하나. 없으면 null
  - `String makeToken([Random? rng])` — 4자리 숫자 문자열(앞자리 0 허용)
  - `String monitorUrl({required String ip, required int port, required String token})` → `http://<ip>:<port>/?k=<token>`

- [ ] **Step 1: 실패하는 테스트를 작성한다**

`flutter_app/test/monitor/monitor_address_test.dart`:

```dart
import 'dart:math';

import 'package:flutter_app/monitor/monitor_address.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('makeToken', () {
    test('항상 4자리 숫자다', () {
      for (var seed = 0; seed < 50; seed++) {
        final t = makeToken(Random(seed));
        expect(t.length, 4, reason: 'seed=$seed 에서 $t');
        expect(RegExp(r'^\d{4}$').hasMatch(t), isTrue, reason: t);
      }
    });

    test('같은 시드는 같은 토큰을 준다 (테스트 재현성)', () {
      expect(makeToken(Random(7)), makeToken(Random(7)));
    });
  });

  group('monitorUrl', () {
    test('토큰이 쿼리로 붙는다', () {
      expect(
        monitorUrl(ip: '192.168.0.12', port: 8080, token: '8134'),
        'http://192.168.0.12:8080/?k=8134',
      );
    });
  });

  group('localIpv4', () {
    test('결과가 null 이거나 점 3개짜리 IPv4 다', () async {
      final ip = await localIpv4();
      if (ip != null) {
        expect(ip.split('.').length, 4, reason: ip);
      }
    });
  });
}
```

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

Run: `cd flutter_app && flutter test test/monitor/monitor_address_test.dart`
Expected: FAIL — `Target of URI doesn't exist: 'package:flutter_app/monitor/monitor_address.dart'`

- [ ] **Step 3: 구현한다**

`flutter_app/lib/monitor/monitor_address.dart`:

```dart
/// 치료사가 노트북에 입력할 접속 주소를 만든다.
library;

import 'dart:io';
import 'dart:math';

/// 이 기기의 사설망 IPv4 주소. 없으면 null.
///
/// 루프백은 제외한다 — 다른 기기에서 접속할 주소여야 한다.
Future<String?> localIpv4() async {
  try {
    final ifaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
      includeLinkLocal: false,
    );
    for (final iface in ifaces) {
      for (final addr in iface.addresses) {
        if (!addr.isLoopback) return addr.address;
      }
    }
  } catch (_) {
    // 네트워크 조회 실패는 모니터 비활성 사유일 뿐, 세션을 막지 않는다.
  }
  return null;
}

/// 랜덤 4자리 토큰.
///
/// 암호학적 방어가 아니다. 로컬 네트워크 한정이라는 전제 위에서 같은 Wi-Fi 의
/// 다른 사람이 우발적으로 열어보는 것만 막는다.
String makeToken([Random? rng]) {
  final r = rng ?? Random();
  return r.nextInt(10000).toString().padLeft(4, '0');
}

/// 브라우저에 입력할 전체 주소.
String monitorUrl({
  required String ip,
  required int port,
  required String token,
}) =>
    'http://$ip:$port/?k=$token';
```

- [ ] **Step 4: 테스트가 통과하는지 확인한다**

Run: `cd flutter_app && flutter test test/monitor/monitor_address_test.dart`
Expected: PASS — All tests passed.

- [ ] **Step 5: 커밋한다**

```bash
git add flutter_app/lib/monitor/monitor_address.dart flutter_app/test/monitor/monitor_address_test.dart
git commit -m "feat(monitor): 접속 주소·세션 토큰 생성"
```

---

### Task 3: MonitorBroadcaster — 서버 수명주기 · 토큰 · 페이지 서빙 · hello

서버를 띄우고 끄는 것, 포트 폴백, 토큰 403, `GET /` 페이지 서빙, `GET /ws` 접속 시 `hello` 전송까지.

**Files:**
- Create: `flutter_app/lib/monitor/monitor_broadcaster.dart`
- Test: `flutter_app/test/monitor/monitor_broadcaster_test.dart`

**Interfaces:**
- Consumes: Task 1 의 `MonitorTick`/`MonitorHello`/`FrameRing`, Task 2 의 `makeToken`
- Produces:
  - `class MonitorEndpoint` — `final String? ip; final int port; final String token; String? get url`
  - `class MonitorBroadcaster`
    - 생성자: `MonitorBroadcaster({required Future<String> Function() pageLoader, required MonitorHello Function() helloBuilder, Random? rng})`
    - `Future<MonitorEndpoint?> start()` — 실패 시 null
    - `Future<void> stop()`
    - `MonitorEndpoint? get endpoint`
    - `int get clientCount`

`pageLoader` 를 주입하는 이유: 테스트에서 Flutter 에셋 번들 없이 HTML 문자열을 넣을 수 있어야 한다.

- [ ] **Step 1: 실패하는 테스트를 작성한다**

`flutter_app/test/monitor/monitor_broadcaster_test.dart`:

```dart
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
```

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

Run: `cd flutter_app && flutter test test/monitor/monitor_broadcaster_test.dart`
Expected: FAIL — `Target of URI doesn't exist: 'package:flutter_app/monitor/monitor_broadcaster.dart'`

- [ ] **Step 3: 구현한다**

`flutter_app/lib/monitor/monitor_broadcaster.dart`:

```dart
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

    _server = server;
    _endpoint = MonitorEndpoint(
      ip: await localIpv4(),
      port: server.port,
      token: makeToken(_rng),
    );

    server.listen(_handle, onError: (_) {}, cancelOnError: false);
    return _endpoint;
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
```

- [ ] **Step 4: 테스트가 통과하는지 확인한다**

Run: `cd flutter_app && flutter test test/monitor/monitor_broadcaster_test.dart`
Expected: PASS — All tests passed.

- [ ] **Step 5: 커밋한다**

```bash
git add flutter_app/lib/monitor/monitor_broadcaster.dart flutter_app/test/monitor/monitor_broadcaster_test.dart
git commit -m "feat(monitor): 로컬 HTTP/WS 서버 — 포트 폴백·토큰 403·hello

모니터 실패는 start()가 null 을 주는 것으로만 드러난다. 세션에 예외를 전파하지 않는다."
```

---

### Task 4: Outbox 백프레셔 · tick/event/link/raw 방송 · sub 화이트리스트

느린 클라이언트가 폰의 메모리를 먹지 않게 하고, RAW 구독을 켠 클라이언트에게만 파형을 보낸다.

**Files:**
- Modify: `flutter_app/lib/monitor/monitor_broadcaster.dart`
- Test: `flutter_app/test/monitor/monitor_outbox_test.dart`
- Test: `flutter_app/test/monitor/monitor_broadcaster_test.dart` (테스트 추가)

**Interfaces:**
- Produces:
  - `class Outbox` — `Outbox(int capacity)`, `void add(String msg)`, `String? next()`, `int get length`, `int get dropped`
  - `MonitorBroadcaster` 에 추가: `void pushTick(MonitorTick)`, `void pushEvent(MonitorEvent)`, `void pushLink(String state)`, `void pushRaw(int firstSampleMs, List<int> samples)`

- [ ] **Step 1: Outbox 실패 테스트를 작성한다**

`flutter_app/test/monitor/monitor_outbox_test.dart`:

```dart
import 'package:flutter_app/monitor/monitor_broadcaster.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Outbox', () {
    test('넣은 순서대로 나온다', () {
      final box = Outbox(4);
      box.add('a');
      box.add('b');
      expect(box.next(), 'a');
      expect(box.next(), 'b');
      expect(box.next(), isNull);
    });

    test('용량을 넘으면 오래된 것부터 버린다', () {
      final box = Outbox(2);
      box.add('a');
      box.add('b');
      box.add('c');
      expect(box.length, 2);
      expect(box.next(), 'b');
      expect(box.next(), 'c');
    });

    test('버린 개수를 센다', () {
      final box = Outbox(1);
      box.add('a');
      box.add('b');
      box.add('c');
      expect(box.dropped, 2);
    });
  });
}
```

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

Run: `cd flutter_app && flutter test test/monitor/monitor_outbox_test.dart`
Expected: FAIL — `Undefined class 'Outbox'`

- [ ] **Step 3: Outbox 를 구현한다**

`flutter_app/lib/monitor/monitor_broadcaster.dart` 의 `import` 블록 바로 아래에 추가한다:

```dart
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
```

- [ ] **Step 4: Outbox 테스트가 통과하는지 확인한다**

Run: `cd flutter_app && flutter test test/monitor/monitor_outbox_test.dart`
Expected: PASS — All tests passed.

- [ ] **Step 5: 방송 API 실패 테스트를 작성한다**

`flutter_app/test/monitor/monitor_broadcaster_test.dart` 의 `main()` 안 마지막에 추가한다:

```dart
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
```

- [ ] **Step 6: 테스트가 실패하는지 확인한다**

Run: `cd flutter_app && flutter test test/monitor/monitor_broadcaster_test.dart`
Expected: FAIL — `The method 'pushTick' isn't defined for the type 'MonitorBroadcaster'`

- [ ] **Step 7: 방송 API 를 구현한다**

`monitor_broadcaster.dart` 에서 `_clients` 필드를 클라이언트 상태 객체 목록으로 바꾸고 방송 API 를 추가한다. 아래 세 곳을 수정한다.

(1) `final List<WebSocket> _clients = [];` 를 다음으로 교체:

```dart
  final List<_Client> _clients = [];
  Timer? _drain;

  /// 클라이언트당 대기열 상한. 10 Hz 기준 2초치.
  static const int _outboxCapacity = 20;
```

(2) `clientCount` 아래에 방송 API 를 추가:

```dart
  /// 10 Hz 관찰 프레임.
  void pushTick(MonitorTick f) => _broadcast(jsonEncode(f.toJson()));

  /// 이산 사건(수축·존 전환·피로·휴식·세션).
  void pushEvent(MonitorEvent e) => _broadcast(jsonEncode(e.toJson()));

  /// BLE 연결 상태. 웹은 이것과 소켓 끊김을 구분해서 표시한다.
  void pushLink(String state) =>
      _broadcast(jsonEncode({'t': 'link', 'state': state}));

  /// RAW 1kHz 파형 100표본 묶음. **구독한 클라이언트에게만** 간다.
  void pushRaw(int firstSampleMs, List<int> samples) {
    if (_clients.isEmpty) return;
    final msg = jsonEncode({'t': 'raw', 'i': firstSampleMs, 'v': samples});
    for (final c in _clients) {
      if (c.wantsRaw) c.outbox.add(msg);
    }
  }

  void _broadcast(String msg) {
    for (final c in _clients) {
      c.outbox.add(msg);
    }
  }
```

(3) `stop()` 과 `_upgrade()` 와 `_send()` 를 다음으로 교체:

```dart
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
```

(4) 파일 맨 아래에 클라이언트 상태 클래스를 추가:

```dart
class _Client {
  _Client(this.socket, this.outbox);

  final WebSocket socket;
  final Outbox outbox;

  /// 진단 패널을 펼친 클라이언트만 RAW 를 받는다.
  bool wantsRaw = false;
}
```

- [ ] **Step 8: 전체 모니터 테스트가 통과하는지 확인한다**

Run: `cd flutter_app && flutter test test/monitor/`
Expected: PASS — All tests passed.

- [ ] **Step 9: 커밋한다**

```bash
git add flutter_app/lib/monitor/monitor_broadcaster.dart flutter_app/test/monitor/
git commit -m "feat(monitor): 백프레셔 drop-oldest + 구독 화이트리스트

밀린 프레임은 버린다 — 실시간 화면에 과거는 가치가 음수다.
웹에서 받는 메시지는 sub 하나뿐. 제어는 폰에서만."
```

---

### Task 5: MonitorSource — 파이프라인을 프레임으로

`SessionController` 와 `LiveFatigueFeed` 를 구독해 10 Hz 로 `pushTick`, 사건마다 `pushEvent` 를 부른다.

**Files:**
- Create: `flutter_app/lib/monitor/monitor_source.dart`
- Test: `flutter_app/test/monitor/monitor_source_test.dart`

**Interfaces:**
- Consumes: `SessionController`(`st.mwCount`, `envLast`, `rmsLast`, `mdfLast`, `connState`, `st.fatigueDetected`), `LiveFatigueFeed`(`tracker`, `contractionCount`, `nowSec`, `sigmaNow`), Task 1·4 의 타입
- Produces:
  - `class MonitorSink` — `void tick(MonitorTick)`, `void event(MonitorEvent)`, `void link(String)` 만 요구하는 추상 인터페이스. `MonitorBroadcaster` 를 감싸는 어댑터 `BroadcasterSink` 도 같은 파일에 둔다
  - `class MonitorSource` — `MonitorSource({required SessionController session, required LiveFatigueFeed feed, required MonitorSink sink})`, `void start()`, `void stop()`, `MonitorHello buildHello(String sessionLabel)`

`MonitorSink` 를 두는 이유: 소스 테스트에 서버가 필요 없어야 한다.

- [ ] **Step 1: 실패하는 테스트를 작성한다**

`flutter_app/test/monitor/monitor_source_test.dart`:

```dart
import 'package:flutter_app/game/data/live_fatigue_feed.dart';
import 'package:flutter_app/monitor/monitor_frame.dart';
import 'package:flutter_app/monitor/monitor_source.dart';
import 'package:flutter_app/services/session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeSink implements MonitorSink {
  final ticks = <MonitorTick>[];
  final events = <MonitorEvent>[];
  final links = <String>[];

  @override
  void tick(MonitorTick f) => ticks.add(f);

  @override
  void event(MonitorEvent e) => events.add(e);

  @override
  void link(String state) => links.add(state);
}

void main() {
  test('세션 값이 tick 으로 옮겨진다', () async {
    final session = SessionController();
    addTearDown(session.dispose);
    final feed = LiveFatigueFeed(session: session);
    addTearDown(feed.dispose);
    final sink = _FakeSink();
    final source = MonitorSource(session: session, feed: feed, sink: sink);

    await feed.start();
    source.start();
    addTearDown(source.stop);

    session.envLast = 120.0;
    session.rmsLast = 210.0;
    session.mdfLast = 88.0;
    source.emitTick();

    expect(sink.ticks, hasLength(1));
    expect(sink.ticks.single.env, 120.0);
    expect(sink.ticks.single.rms, 210.0);
    expect(sink.ticks.single.mdf, 88.0);
    // baseline 전이므로 σ 는 없다 — "정상"으로 단정하지 않는다.
    expect(sink.ticks.single.sigma, isNull);
  });

  test('연결 상태가 바뀌면 link 를 보낸다', () async {
    final session = SessionController();
    addTearDown(session.dispose);
    final feed = LiveFatigueFeed(session: session);
    addTearDown(feed.dispose);
    final sink = _FakeSink();
    final source = MonitorSource(session: session, feed: feed, sink: sink);

    await feed.start();
    source.start();
    addTearDown(source.stop);

    // notifyListeners 는 @protected 라 분석기가 경고한다. 테스트에서 상태 변화를
    // 직접 흘려보내기 위한 의도된 사용이므로 억제한다.
    session.connState = 'connected';
    // ignore: invalid_use_of_protected_member
    session.notifyListeners();
    session.connState = 'connected';
    // ignore: invalid_use_of_protected_member
    session.notifyListeners();
    session.connState = 'disconnected';
    // ignore: invalid_use_of_protected_member
    session.notifyListeners();

    // 같은 상태가 이어지면 중복 전송하지 않는다.
    expect(sink.links, ['connected', 'disconnected']);
  });

  test('buildHello 가 링버퍼와 baseline 을 담는다', () async {
    final session = SessionController();
    addTearDown(session.dispose);
    final feed = LiveFatigueFeed(session: session);
    addTearDown(feed.dispose);
    final sink = _FakeSink();
    final source = MonitorSource(session: session, feed: feed, sink: sink);

    await feed.start();
    source.start();
    addTearDown(source.stop);

    source.emitTick();
    source.emitTick();

    final hello = source.buildHello('홍길동');
    expect(hello.session, '홍길동');
    expect(hello.ticks, hasLength(2));
    expect(hello.mu0, feed.tracker.mu0);
    expect(hello.t1, feed.tracker.t1);
  });
}
```

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

Run: `cd flutter_app && flutter test test/monitor/monitor_source_test.dart`
Expected: FAIL — `Target of URI doesn't exist: 'package:flutter_app/monitor/monitor_source.dart'`

- [ ] **Step 3: 구현한다**

`flutter_app/lib/monitor/monitor_source.dart`:

```dart
/// 기존 파이프라인을 관찰 프레임으로 옮기는 어댑터.
///
/// ## 계산하지 않는다
///
/// σ·존은 [LiveFatigueFeed] 의 [SigmaTracker] 가 이미 확정한 값을 읽어 옮길
/// 뿐이다. 여기서 다시 계산하면 게임과 웹이 갈라진다.
library;

import 'dart:async';

import '../game/data/fatigue_feed.dart';
import '../game/data/live_fatigue_feed.dart';
import '../game/model/zone.dart';
import '../services/session_controller.dart';
import 'monitor_broadcaster.dart';
import 'monitor_frame.dart';

/// 프레임을 받아가는 쪽. 테스트에서 서버 없이 갈아끼우기 위한 경계다.
abstract class MonitorSink {
  void tick(MonitorTick f);
  void event(MonitorEvent e);
  void link(String state);
}

/// [MonitorBroadcaster] 를 [MonitorSink] 로 감싼다.
///
/// [broadcaster] 가 `final` 이 아닌 것은 의도다. 앱이 백그라운드에 다녀오면 서버를
/// 새로 띄워야 하는데, 그때 [MonitorSource] 까지 다시 만들면 세션 시계와 링버퍼가
/// 초기화된다. 소스는 그대로 두고 방송기만 갈아끼운다.
class BroadcasterSink implements MonitorSink {
  BroadcasterSink(this.broadcaster);

  MonitorBroadcaster broadcaster;

  @override
  void tick(MonitorTick f) => broadcaster.pushTick(f);

  @override
  void event(MonitorEvent e) => broadcaster.pushEvent(e);

  @override
  void link(String state) => broadcaster.pushLink(state);
}

/// tick 주기(ms). 설계 문서의 10 Hz.
const int kMonitorTickMs = 100;

/// 링버퍼 용량 — 10 Hz × 60초.
const int kMonitorRingCapacity = 600;

class MonitorSource {
  MonitorSource({
    required this.session,
    required this.feed,
    required this.sink,
  });

  final SessionController session;
  final LiveFatigueFeed feed;
  final MonitorSink sink;

  final FrameRing ring = FrameRing(kMonitorRingCapacity);

  Timer? _timer;
  StreamSubscription<ContractionEvent>? _contractionSub;
  StreamSubscription<double>? _predictedSub;
  String? _lastLink;
  FatigueZone? _lastZone;
  bool _lastFatigue = false;

  /// 마지막으로 받은 예측 σ. 예측은 버스트마다 갱신되고 tick 은 10 Hz 라
  /// 최신값을 들고 있다가 실어보낸다.
  double? _lastPredicted;

  void start() {
    _lastLink = null;
    _lastZone = null;
    _lastFatigue = false;
    _lastPredicted = null;
    session.addListener(_onSession);
    _contractionSub = feed.contractions.listen((c) {
      sink.event(MonitorEvent('contraction', c.t));
    });
    _predictedSub = feed.sigmaPredicted.listen((z) => _lastPredicted = z);
    _timer = Timer.periodic(
      const Duration(milliseconds: kMonitorTickMs),
      (_) => emitTick(),
    );
    sink.event(MonitorEvent('session_start', feed.nowSec));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _contractionSub?.cancel();
    _contractionSub = null;
    _predictedSub?.cancel();
    _predictedSub = null;
    session.removeListener(_onSession);
    sink.event(MonitorEvent('session_stop', feed.nowSec));
  }

  /// 프레임 1개를 만들어 링버퍼에 넣고 내보낸다.
  ///
  /// 타이머가 부르지만 테스트에서 직접 부를 수 있게 공개해 둔다 — 그래야
  /// 100ms 를 기다리지 않고 검증한다.
  void emitTick() {
    final f = MonitorTick(
      t: feed.nowSec,
      sigma: feed.tracker.currentSigma,
      sigmaPredicted: _lastPredicted,
      env: session.envLast,
      rms: session.rmsLast,
      mdf: session.mdfLast,
      contractions: feed.contractionCount,
    );
    ring.add(f);
    sink.tick(f);

    final zone = f.zone;
    if (zone != null && zone != _lastZone) {
      _lastZone = zone;
      sink.event(MonitorEvent('zone', f.t, zone: zone.index));
    }
  }

  void _onSession() {
    final state = session.connState;
    if (state != _lastLink) {
      _lastLink = state;
      sink.link(state);
    }
    final fatigued = session.st.fatigueDetected;
    if (fatigued && !_lastFatigue) {
      sink.event(MonitorEvent('fatigue', feed.nowSec,
          zone: feed.tracker.currentZone?.index));
    }
    _lastFatigue = fatigued;
  }

  /// 새 클라이언트에게 보낼 hello.
  MonitorHello buildHello(String sessionLabel) => MonitorHello(
        session: sessionLabel,
        startedAtMs: DateTime.now().millisecondsSinceEpoch,
        mu0: feed.tracker.mu0,
        sd0: feed.tracker.sd0,
        t1: feed.tracker.t1,
        t2: feed.tracker.t2,
        t3: feed.tracker.t3,
        ticks: ring.frames,
      );
}
```

- [ ] **Step 4: 테스트가 통과하는지 확인한다**

Run: `cd flutter_app && flutter test test/monitor/monitor_source_test.dart`
Expected: PASS — All tests passed.

- [ ] **Step 5: 종단 통합 테스트를 작성한다**

파이프라인부터 브라우저 소켓까지 한 줄로 이어지는지 본다. 시뮬레이터로 데이터를 만들어
실제 서버에 붙은 WS 클라이언트가 `hello` 와 `tick` 을 받는지 확인한다.

`flutter_app/test/monitor/monitor_e2e_test.dart`:

```dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_app/game/data/live_fatigue_feed.dart';
import 'package:flutter_app/monitor/monitor_broadcaster.dart';
import 'package:flutter_app/monitor/monitor_source.dart';
import 'package:flutter_app/services/session_controller.dart';
import 'package:flutter_app/services/simulator_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('시뮬레이터 → 소스 → 방송기 → WS 클라이언트', () async {
    final session = SessionController();
    addTearDown(session.dispose);
    final feed = LiveFatigueFeed(session: session);
    addTearDown(feed.dispose);

    late final MonitorSource source;
    final broadcaster = MonitorBroadcaster(
      pageLoader: () async => '<html></html>',
      helloBuilder: () => source.buildHello('시뮬레이터'),
    );
    source = MonitorSource(
      session: session,
      feed: feed,
      sink: BroadcasterSink(broadcaster),
    );

    final ep = await broadcaster.start();
    expect(ep, isNotNull);
    addTearDown(broadcaster.stop);

    await feed.start();
    source.start();
    addTearDown(source.stop);
    await session.startSimulator(SimScenario.continuousFatigue);
    addTearDown(session.stopSimulator);

    final ws = await WebSocket.connect(
        'ws://127.0.0.1:${ep!.port}/ws?k=${ep.token}');
    addTearDown(() => ws.close());

    final got = <Map<String, dynamic>>[];
    final sub = ws.listen(
        (m) => got.add(jsonDecode(m as String) as Map<String, dynamic>));
    addTearDown(sub.cancel);

    await Future<void>.delayed(const Duration(milliseconds: 600));

    expect(got.first['t'], 'hello');
    expect(got.first['session'], '시뮬레이터');
    expect(got.where((m) => m['t'] == 'tick').length, greaterThan(2),
        reason: '10 Hz 이므로 600ms 안에 여러 개가 와야 한다');
  });
}
```

- [ ] **Step 6: 종단 테스트가 통과하는지 확인한다**

Run: `cd flutter_app && flutter test test/monitor/monitor_e2e_test.dart`
Expected: PASS — All tests passed.

- [ ] **Step 7: 커밋한다**

```bash
git add flutter_app/lib/monitor/monitor_source.dart flutter_app/test/monitor/monitor_source_test.dart \
        flutter_app/test/monitor/monitor_e2e_test.dart
git commit -m "feat(monitor): 파이프라인 → 프레임 어댑터

σ는 SigmaTracker 가 확정한 값을 옮기기만 한다. 여기서 다시 계산하지 않는다."
```

---

### Task 6: SessionController.adopt() — BLE 단일 소유권

`home_page` 가 이미 연 characteristic 을 `SessionController` 가 함께 구독한다. 재스캔·재연결이 없다.

**Files:**
- Modify: `flutter_app/lib/services/session_controller.dart`
- Test: `flutter_app/test/monitor/session_adopt_test.dart`

**Interfaces:**
- Produces: `SessionController.adopt({required Stream<List<int>> dataStream, BluetoothCharacteristic? cmdChar, String label})` → `void`, 그리고 `void release()`

`adopt` 가 `BluetoothDevice` 가 아니라 `Stream<List<int>>` 를 받는 이유: 실제 BLE 기기 없이 테스트할 수 있고, `home_page` 는 `dataChar.lastValueStream` 을 그대로 넘기면 된다. `lastValueStream` 은 브로드캐스트라 `home_page` 의 기존 구독과 공존한다.

- [ ] **Step 1: 실패하는 테스트를 작성한다**

`flutter_app/test/monitor/session_adopt_test.dart`:

```dart
import 'dart:async';
import 'dart:convert';

import 'package:flutter_app/services/session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('adopt 한 스트림의 패킷이 파싱된다', () async {
    final ctrl = StreamController<List<int>>.broadcast();
    addTearDown(ctrl.close);
    final session = SessionController();
    addTearDown(session.dispose);

    session.adopt(dataStream: ctrl.stream, label: 'EMG-FES-01');
    expect(session.connState, 'connected');
    expect(session.deviceLabel, 'EMG-FES-01');

    ctrl.add(utf8.encode(jsonEncode({
      'ts': 1000,
      'env': 120.0,
      'rms': 210.0,
      'mdf': 88.0,
      'v': true,
      'run': true,
      'stim': true,
      'fd': false,
    })));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(session.envLast, 120.0);
    expect(session.rmsLast, 210.0);
    expect(session.mdfLast, 88.0);
  });

  test('release 하면 더 이상 받지 않는다', () async {
    final ctrl = StreamController<List<int>>.broadcast();
    addTearDown(ctrl.close);
    final session = SessionController();
    addTearDown(session.dispose);

    session.adopt(dataStream: ctrl.stream, label: 'EMG-FES-01');
    session.release();
    expect(session.connState, 'disconnected');

    ctrl.add(utf8.encode(jsonEncode({
      'ts': 2000, 'env': 999.0, 'rms': 999.0, 'mdf': 999.0,
      'v': true, 'run': true, 'stim': true, 'fd': false,
    })));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(session.envLast, isNot(999.0));
  });

  test('원래 구독자와 공존한다 (브로드캐스트)', () async {
    final ctrl = StreamController<List<int>>.broadcast();
    addTearDown(ctrl.close);
    final session = SessionController();
    addTearDown(session.dispose);

    final seenByHomePage = <List<int>>[];
    final sub = ctrl.stream.listen(seenByHomePage.add);
    addTearDown(sub.cancel);

    session.adopt(dataStream: ctrl.stream, label: 'EMG-FES-01');

    ctrl.add(utf8.encode(jsonEncode({
      'ts': 3000, 'env': 5.0, 'rms': 6.0, 'mdf': 7.0,
      'v': true, 'run': true, 'stim': true, 'fd': false,
    })));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(seenByHomePage, hasLength(1));
    expect(session.envLast, 5.0);
  });
}
```

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

Run: `cd flutter_app && flutter test test/monitor/session_adopt_test.dart`
Expected: FAIL — `The method 'adopt' isn't defined for the type 'SessionController'`

- [ ] **Step 3: 구현한다**

`flutter_app/lib/services/session_controller.dart` 의 `disconnect()` 메서드 **바로 앞**에 다음을 추가한다:

```dart
  // ============================================================
  // 이미 열린 BLE 연결 넘겨받기 (adopt)
  // ============================================================
  /// 다른 화면이 이미 연 characteristic 스트림을 함께 구독한다.
  ///
  /// ## 왜 재스캔하지 않는가
  ///
  /// 같은 기기에 두 번 연결할 수는 없다. `home_page` 가 BLE 를 쥔 채 게임에
  /// 들어가면 이 컨트롤러가 다시 스캔·연결할 방법이 없고, 끊었다 다시 잡으면
  /// 세션이 끊기고 수 초가 날아간다. `lastValueStream` 은 브로드캐스트라
  /// 두 구독자가 같은 패킷을 함께 받는다 — 연결은 하나, 소비자는 둘이다.
  ///
  /// [cmdChar] 는 넘겨주면 이 컨트롤러도 명령을 보낼 수 있고, 생략하면
  /// 수신 전용이 된다.
  void adopt({
    required Stream<List<int>> dataStream,
    BluetoothCharacteristic? cmdChar,
    String label = kDeviceName,
  }) {
    _adoptedSub?.cancel();
    _adoptedSub = dataStream.listen(_onCharData);
    _cmdChar = cmdChar;
    deviceLabel = label;
    connState = 'connected';
    lastError = null;
    notifyListeners();
  }

  /// [adopt] 로 받은 구독을 놓는다. 원래 소유자의 연결은 건드리지 않는다.
  void release() {
    _adoptedSub?.cancel();
    _adoptedSub = null;
    _cmdChar = null;
    connState = 'disconnected';
    deviceLabel = '';
    notifyListeners();
  }

```

같은 파일의 BLE 필드 블록(`StreamSubscription<List<ScanResult>>? _scanSub;` 아래)에 필드를 추가한다:

```dart
  /// 다른 화면에서 넘겨받은 데이터 구독. [adopt] 참고.
  StreamSubscription<List<int>>? _adoptedSub;
```

그리고 `dispose()` 에서 정리되도록, `_device?.disconnect();` 줄 **앞**에 다음을 추가한다:

```dart
    _adoptedSub?.cancel();
```

- [ ] **Step 4: 테스트가 통과하는지 확인한다**

Run: `cd flutter_app && flutter test test/monitor/session_adopt_test.dart`
Expected: PASS — All tests passed.

- [ ] **Step 5: 회귀가 없는지 확인한다**

Run: `cd flutter_app && flutter test`
Expected: PASS — 기존 game 테스트 포함 전부 통과.

- [ ] **Step 6: 커밋한다**

```bash
git add flutter_app/lib/services/session_controller.dart flutter_app/test/monitor/session_adopt_test.dart
git commit -m "feat(session): adopt() — 이미 열린 BLE 스트림 함께 구독

같은 기기에 두 번 연결할 수 없어 재스캔이 불가능하다. lastValueStream 이
브로드캐스트라 연결 하나에 소비자 둘이 붙는다."
```

---

### Task 7: 게임 진입 시 세션 주입 + 방송기 기동 + 주소 카드

지금 `home_page` 가 `const GameScreen()` 을 세션 없이 띄워 게임이 목 데이터로 돈다. 이걸 고치면서 방송기를 함께 올린다.

**Files:**
- Modify: `flutter_app/lib/screens/home_page.dart:1275-1285` (게임 진입 지점)
- Create: `flutter_app/lib/widgets/monitor/monitor_address_card.dart`
- Modify: `flutter_app/lib/game/ui/game_screen.dart`
- Modify: `flutter_app/pubspec.yaml:71-74` (assets 에 `assets/web/` 추가)
- Test: `flutter_app/test/monitor/monitor_address_card_test.dart`

**Interfaces:**
- Consumes: Task 2 의 `MonitorEndpoint`, Task 3·4 의 `MonitorBroadcaster`, Task 5 의 `MonitorSource`·`BroadcasterSink`, Task 6 의 `SessionController.adopt`
- Produces: `class MonitorAddressCard extends StatelessWidget` — `const MonitorAddressCard({super.key, required this.endpoint})`

- [ ] **Step 1: 주소 카드 실패 테스트를 작성한다**

`flutter_app/test/monitor/monitor_address_card_test.dart`:

```dart
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
```

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

Run: `cd flutter_app && flutter test test/monitor/monitor_address_card_test.dart`
Expected: FAIL — `Target of URI doesn't exist: 'package:flutter_app/widgets/monitor/monitor_address_card.dart'`

- [ ] **Step 3: 주소 카드를 구현한다**

`flutter_app/lib/widgets/monitor/monitor_address_card.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../monitor/monitor_broadcaster.dart';

/// 치료사가 노트북에 입력할 주소를 폰에 띄운다.
///
/// 모니터가 못 떴을 때도 화면은 뜬다 — 모니터 실패가 세션을 막지 않기 때문이다.
class MonitorAddressCard extends StatelessWidget {
  const MonitorAddressCard({super.key, required this.endpoint});

  final MonitorEndpoint? endpoint;

  @override
  Widget build(BuildContext context) {
    final ep = endpoint;
    final theme = Theme.of(context);

    String message;
    String? copyTarget;
    if (ep == null) {
      message = '모니터 비활성 — 관찰 화면 없이 세션은 그대로 진행됩니다';
    } else if (ep.url == null) {
      message = 'Wi-Fi 에 연결되어 있지 않아 주소를 만들 수 없습니다';
    } else {
      message = '${ep.ip}:${ep.port}  ·  접속코드 ${ep.token}';
      copyTarget = ep.url;
    }

    return Card(
      margin: const EdgeInsets.all(12),
      child: ListTile(
        leading: const Icon(Icons.monitor_outlined),
        title: const Text('관찰 화면 주소'),
        subtitle: Text(message, style: theme.textTheme.bodyMedium),
        trailing: copyTarget == null
            ? null
            : IconButton(
                icon: const Icon(Icons.copy),
                tooltip: '주소 복사',
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: copyTarget!));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('주소를 복사했습니다')),
                  );
                },
              ),
      ),
    );
  }
}
```

- [ ] **Step 4: 주소 카드 테스트가 통과하는지 확인한다**

Run: `cd flutter_app && flutter test test/monitor/monitor_address_card_test.dart`
Expected: PASS — All tests passed.

- [ ] **Step 5: pubspec 에 웹 에셋을 등록한다**

`flutter_app/pubspec.yaml` 의 `assets:` 블록을 다음으로 바꾼다:

```yaml
  assets:
    - .env
    # 게임 에셋(배경·글러브·투수 스프라이트). 비어 있어도 코드 드로잉으로 동작한다.
    - assets/game/
    # 웹 관찰 화면. 폰이 이 파일을 그대로 서빙한다.
    - assets/web/
```

- [ ] **Step 6: home_page 에서 세션을 주입하고 방송기를 올린다**

`flutter_app/lib/screens/home_page.dart` 의 상단 import 블록에 추가한다:

```dart
import '../monitor/monitor_broadcaster.dart';
import '../monitor/monitor_source.dart';
import '../services/session_controller.dart';
```

같은 파일에서 `MaterialPageRoute(builder: (_) => const GameScreen()),` 를 찾아 그 `onPressed`/`onTap` 콜백 전체를 다음 메서드 호출로 바꾸고, 메서드를 `_HomePageState` 안에 추가한다:

```dart
  /// 게임 화면으로 이동하면서 BLE 스트림을 세션 컨트롤러에 넘기고 관찰 서버를 올린다.
  ///
  /// 여기가 "게임이 목 데이터로 돌던" 문제의 수정 지점이다. dataChar 가 없으면
  /// (미연결) 세션을 넘기지 않고, GameScreen 이 기존대로 목 피드로 떨어진다.
  Future<void> _openGame() async {
    final dataChar = _adoptableDataChar;
    if (dataChar == null) {
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const GameScreen()),
      );
      return;
    }

    final session = SessionController();
    session.adopt(
      dataStream: dataChar.lastValueStream,
      cmdChar: _cmdChar,
      label: _device?.platformName ?? kDeviceName,
    );

    if (!mounted) {
      session.dispose();
      return;
    }
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => GameScreen(session: session)),
    );
    session.release();
    session.dispose();
  }
```

`_adoptableDataChar` 를 만들기 위해, 같은 파일에서 `_dataSub = dataChar.lastValueStream.listen(_onCharData);` 줄 **바로 아래**에 다음을 추가한다:

```dart
      _dataChar = dataChar;   // 게임/모니터에 넘겨줄 스트림 원본
```

그리고 `BluetoothCharacteristic? _cmdChar;` 필드 아래에 추가한다:

```dart
  BluetoothCharacteristic? _dataChar;

  /// adopt 로 넘겨줄 수 있는 데이터 characteristic. 미연결이면 null.
  BluetoothCharacteristic? get _adoptableDataChar =>
      _connState == 'connected' ? _dataChar : null;
```

`_device = null; _cmdChar = null;` 이 나오는 두 곳(연결 해제 처리) 각각에 `_dataChar = null;` 을 함께 추가한다.

- [ ] **Step 7: GameScreen 이 방송기를 띄우게 한다**

`flutter_app/lib/game/ui/game_screen.dart` 의 import 에 추가한다:

```dart
import 'package:flutter/services.dart' show rootBundle;

import '../../monitor/monitor_broadcaster.dart';
import '../../monitor/monitor_frame.dart';
import '../../monitor/monitor_source.dart';
import '../../widgets/monitor/monitor_address_card.dart';
```

`_GameScreenState` 에 필드와 수명주기를 추가한다. `late final FatigueFeed _feed;` 아래에 필드를 넣는다:

```dart
  MonitorBroadcaster? _broadcaster;
  MonitorSource? _monitorSource;
  BroadcasterSink? _monitorSink;
  MonitorEndpoint? _monitorEndpoint;
```

`initState()` 의 `_game = BaseballGame(feed: _feed)..onCatch = _onCatch;` 줄 **아래**에 추가한다:

```dart
    _startMonitor();
```

그리고 `_GameScreenState` 에 메서드를 추가한다:

```dart
  /// 관찰 서버를 올린다. 실패해도 게임은 그대로 진행된다.
  ///
  /// 두 번째 이후 호출(백그라운드 복귀)에서는 **방송기만** 새로 만들고 소스는
  /// 그대로 둔다. 소스를 다시 만들면 세션 시계와 링버퍼가 초기화된다.
  Future<void> _startMonitor() async {
    final session = widget.session;
    final feed = _feed;
    if (session == null || feed is! LiveFatigueFeed) return; // 목 피드는 방송하지 않는다
    if (_broadcaster?.endpoint != null) return; // 이미 떠 있다

    late final MonitorBroadcaster broadcaster;
    broadcaster = MonitorBroadcaster(
      pageLoader: () => rootBundle.loadString('assets/web/monitor.html'),
      helloBuilder: () =>
          _monitorSource!.buildHello(_sessionLabel()),
    );

    var source = _monitorSource;
    if (source == null) {
      final sink = BroadcasterSink(broadcaster);
      source = MonitorSource(session: session, feed: feed, sink: sink);
      _monitorSink = sink;
      _monitorSource = source;
      source.start();
    } else {
      _monitorSink!.broadcaster = broadcaster; // 소스는 유지, 방송기만 교체
    }

    final ep = await broadcaster.start();
    if (!mounted) {
      await broadcaster.stop();
      return;
    }
    setState(() {
      _broadcaster = broadcaster;
      _monitorEndpoint = ep;
    });
  }

  String _sessionLabel() {
    final f = _feed;
    return f is MockFatigueFeed ? '재생: ${f.sessionName}' : '실측 세션';
  }
```

`dispose()` 안, `_feed.dispose();` 앞에 추가한다:

```dart
    _monitorSource?.stop();
    _broadcaster?.stop();
```

마지막으로 화면에 주소 카드를 띄운다. `SessionHud(` 를 담고 있는 `Column`/`Stack` 자식 목록 맨 아래에 추가한다:

```dart
                  if (_monitorEndpoint != null || _broadcaster != null)
                    MonitorAddressCard(endpoint: _monitorEndpoint),
```

- [ ] **Step 8: 앱이 백그라운드로 가면 소켓을 정리한다**

iOS 는 앱이 백그라운드로 가면 소켓을 살려두지 않는다. 그대로 두면 웹은 "연결됨"인 채로
멈춘 화면을 보게 된다 — 치료사가 과거를 현재로 착각하는 바로 그 실패다. 그래서 배경으로
갈 때 명시적으로 알리고 닫는다.

`_GameScreenState` 의 `class _GameScreenState extends State<GameScreen>` 선언에
`with WidgetsBindingObserver` 를 더한다:

```dart
class _GameScreenState extends State<GameScreen> with WidgetsBindingObserver {
```

`initState()` 의 `_startMonitor();` 아래에 추가한다:

```dart
    WidgetsBinding.instance.addObserver(this);
```

`dispose()` 의 `_monitorSource?.stop();` **앞**에 추가한다:

```dart
    WidgetsBinding.instance.removeObserver(this);
```

그리고 `_GameScreenState` 에 메서드를 추가한다:

```dart
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final b = _broadcaster;
    if (b == null) return;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      // 폰 화면이 꺼지면 소켓이 죽는다. 웹이 "멈춘 화면"을 현재로 오해하지 않도록
      // 먼저 알리고 닫는다. 웹은 소켓 종료를 보고 stale 로 넘어간다.
      b.pushEvent(MonitorEvent('phone_background', _game.feedNowSec));
      b.stop();
      if (mounted) setState(() => _monitorEndpoint = null);
    } else if (state == AppLifecycleState.resumed && b.endpoint == null) {
      // 소스는 살아 있으므로 방송기만 다시 올라온다 (_startMonitor 참고).
      _startMonitor();
    }
  }
```

- [ ] **Step 9: 전체 테스트가 통과하는지 확인한다**

Run: `cd flutter_app && flutter test`
Expected: PASS — All tests passed.

- [ ] **Step 10: 정적 분석을 확인한다**

Run: `cd flutter_app && flutter analyze`
Expected: `No issues found!`

- [ ] **Step 11: 커밋한다**

```bash
git add flutter_app/lib/screens/home_page.dart flutter_app/lib/game/ui/game_screen.dart \
        flutter_app/lib/widgets/monitor/ flutter_app/test/monitor/monitor_address_card_test.dart \
        flutter_app/pubspec.yaml
git commit -m "feat(monitor): 게임에 실 세션 주입 + 관찰 서버 기동

home_page 가 GameScreen 을 세션 없이 띄워 게임이 목 데이터로 돌고 있었다.
adopt 로 BLE 스트림을 넘겨 게임·모니터가 같은 실 데이터 줄기에서 돈다."
```

---

### Task 8: monitor.html 라이브 모드 — 재생 기능은 유지

기존 `docs/spc_stamina_monitor.html` 을 에셋으로 옮기고 WebSocket 소스를 더한다. 재생 모드는 그대로 둔다 — 장비 없이 렌더링 회귀를 보고 데모에도 쓴다.

**Files:**
- Create: `flutter_app/assets/web/monitor.html` (기존 `docs/spc_stamina_monitor.html` 복사 후 수정)
- Test: 수동 — 브라우저에서 확인 (JS 단위 테스트 도구를 새로 들이지 않는다)

**Interfaces:**
- Consumes: Task 1 의 JSON 형식 — `hello`(`session`,`t1`,`t2`,`t3`,`ticks[]`), `tick`(`ts`,`z`,`zone`,`stam`), `event`(`kind`,`ts`), `link`(`state`)
- Produces: 없음 (종단 화면)

- [ ] **Step 1: 파일을 에셋으로 복사한다**

```bash
cd /Users/yeonchaerin/Developer/emg-fes-project
mkdir -p flutter_app/assets/web
cp docs/spc_stamina_monitor.html flutter_app/assets/web/monitor.html
```

- [ ] **Step 2: 라이브 소스를 추가한다**

`flutter_app/assets/web/monitor.html` 에서 `/* ═══ ... 이벤트 ... ═══ */` 주석 블록 **바로 앞**(즉 `function load(data) { ... }` 정의 다음)에 아래를 통째로 삽입한다:

```javascript
/* ══════════════════════════════════════════════════════════════════════
   라이브 소스 — 폰이 WebSocket 으로 밀어주는 세션

   이 블록은 판정하지 않는다. σ·존·스태미나·t1/t2/t3 는 전부 폰이 계산해서
   보낸 값이고 여기서는 D 에 넣고 다시 그릴 뿐이다. SPC 규칙을 여기에 옮겨
   적으면 폰 게임과 웹이 갈라진다.
   ════════════════════════════════════════════════════════════════════ */
let live = false;              // 라이브 모드인가
let ws = null;
let retry = 500;               // 재연결 백오프(ms)
let lastTickAt = 0;            // 마지막 tick 수신 시각(performance.now)
let linkState = "unknown";     // 폰↔ESP32 BLE 상태
let staleTimer = null;

const STALE_MS = 2000;         // 10 Hz 기준 20프레임 누락이면 못 믿는다

function setBanner(text, tone) {
  let el = document.getElementById("liveBanner");
  if (!el) {
    el = htmlEl("div", { id: "liveBanner" });
    el.style.cssText =
      "position:fixed;left:0;right:0;top:0;z-index:99;padding:8px 12px;" +
      "font-weight:700;text-align:center;font-size:14px";
    document.body.appendChild(el);
  }
  if (!text) { el.style.display = "none"; return; }
  el.style.display = "block";
  el.textContent = text;
  el.style.background = tone === "bad" ? "#7f1d1d" : "#78350f";
  el.style.color = "#fff";
}

/** 화면 전체를 흐리게 — 오래된 값을 현재값인 척 그리지 않는다. */
function setStale(on) {
  document.body.style.opacity = on ? "0.45" : "1";
  document.body.style.filter = on ? "grayscale(1)" : "none";
}

function liveInit(sessionLabel) {
  D = { session: sessionLabel, t: [0], z: [0], t1: null, t2: null, t3: null };
  idx = 0;
  $("sessLabel").textContent = sessionLabel;
  $("scrub").disabled = true;
  $("btnPlay").disabled = true;
  $("btnReset").disabled = true;
  drawTimeline();
  renderStats();
  render();
}

function livePush(ts, z) {
  if (!D) return;
  D.t.push(ts);
  D.z.push(z);
  idx = D.t.length - 1;
  $("scrub").max = D.t.length - 1;
  $("scrub").value = idx;
  $("tEnd").textContent = fmtTime(ts);
  drawTimeline();
  renderStats();
  render();
}

function onMessage(msg) {
  let m;
  try { m = JSON.parse(msg); } catch (e) { return; }

  if (m.t === "hello") {
    live = true;
    liveInit(m.session || "실측 세션");
    D.t1 = m.t1; D.t2 = m.t2; D.t3 = m.t3;
    for (const f of (m.ticks || [])) {
      if (typeof f.z === "number") { D.t.push(f.ts); D.z.push(f.z); }
    }
    idx = D.t.length - 1;
    drawTimeline(); renderStats(); render();
    lastTickAt = performance.now();
    setStale(false);
    setBanner("", null);
    return;
  }

  if (m.t === "tick") {
    lastTickAt = performance.now();
    setStale(false);
    if (linkState === "connected" || linkState === "unknown") setBanner("", null);
    // σ 가 없으면(baseline 전) 게이지는 직전 값을 유지하고 타임라인만 늘리지 않는다.
    if (typeof m.z === "number") livePush(m.ts, m.z);
    return;
  }

  if (m.t === "event") {
    if (m.kind === "session_stop") setBanner("세션 종료", null);
    if (m.kind === "rest_start")  setBanner("휴식 중", null);
    if (m.kind === "rest_end")    setBanner("", null);
    if (m.kind === "phone_background") {
      // 폰 화면이 꺼졌다. 곧 소켓도 닫힌다 — 멈춘 화면을 현재로 보이게 두지 않는다.
      setStale(true);
      setBanner("폰 화면 꺼짐 — 폰을 깨우면 다시 이어집니다", "bad");
    }
    return;
  }

  if (m.t === "link") {
    linkState = m.state;
    if (m.state !== "connected") {
      setBanner("센서 끊김 (" + m.state + ") — 전극·기기를 확인하세요", "bad");
    } else {
      setBanner("", null);
    }
    return;
  }

  if (m.t === "raw") { onRawPacket(m); return; }
}

function connect() {
  const url = (location.protocol === "https:" ? "wss://" : "ws://") +
              location.host + "/ws" + location.search;
  try { ws = new WebSocket(url); } catch (e) { scheduleRetry(); return; }

  ws.onopen = () => { retry = 500; };
  ws.onmessage = ev => onMessage(ev.data);
  ws.onclose = () => { ws = null; setStale(true);
    setBanner("연결 끊김 · 재연결 중", "bad"); scheduleRetry(); };
  ws.onerror = () => { try { ws.close(); } catch (e) {} };
}

function scheduleRetry() {
  setTimeout(connect, retry);
  retry = Math.min(retry * 2, 5000);   // 지수 백오프, 상한 5초
}

/* tick 이 끊긴 것도 잡는다 — 소켓은 살아 있는데 데이터만 안 오는 경우가 있다. */
staleTimer = setInterval(() => {
  if (!live || !lastTickAt) return;
  if (performance.now() - lastTickAt > STALE_MS) {
    setStale(true);
    setBanner("데이터 끊김 — 화면이 갱신되지 않고 있습니다", "bad");
  }
}, 500);

/* 폰이 서빙한 페이지면 라이브로 붙는다. 파일을 직접 열었으면 재생 모드다. */
if (location.protocol === "http:" || location.protocol === "https:") {
  connect();
}
```

- [ ] **Step 3: RAW 패킷 수신 자리를 만든다 (Task 9 에서 채운다)**

같은 파일, 위 블록 바로 아래에 추가한다:

```javascript
/* RAW 파형 — 진단 패널이 열려 있을 때만 온다. Task 9 에서 그린다. */
function onRawPacket(m) {
  if (typeof pushRawSamples === "function") pushRawSamples(m.i, m.v);
}
```

- [ ] **Step 4: 앱을 빌드해 페이지가 서빙되는지 확인한다**

Run: `cd flutter_app && flutter build ios --simulator --debug`
Expected: 빌드 성공. (에셋 등록 확인 목적이므로 실기기 설치는 Task 9 이후에 한다)

- [ ] **Step 5: 재생 모드 회귀를 확인한다**

`flutter_app/assets/web/monitor.html` 을 브라우저에서 **파일로 직접 연다**(`file://`). 기존처럼 샘플 세션이 재생되고 게이지·타임라인이 그려져야 한다. `connect()` 는 `file:` 프로토콜에서 호출되지 않는다.

Expected: 재생·일시정지·스크럽·속도 버튼이 모두 이전과 동일하게 동작.

- [ ] **Step 6: 커밋한다**

```bash
git add flutter_app/assets/web/monitor.html
git commit -m "feat(monitor): 관찰 화면 라이브 모드 — WebSocket 소스

재생 모드는 유지한다(장비 없는 회귀 확인·데모용).
stale 을 두 경로로 잡는다: 소켓 끊김과 tick 2초 무수신.
소켓이 살아 있어도 데이터가 안 오면 화면을 회색으로 죽인다 —
치료사가 과거 σ를 현재로 착각하는 것이 최악의 실패다."
```

---

### Task 9: 접이식 진단 패널 — RAW 파형 · 연결 배지

평소엔 접혀 있고, 신호가 의심스러울 때만 펼친다. 펼치는 순간 `sub` 를 보내 RAW 구독을 켠다.

**Files:**
- Modify: `flutter_app/assets/web/monitor.html`
- Test: 수동 — 실기기

**Interfaces:**
- Consumes: Task 4 의 `{"t":"raw","i":<firstSampleMs>,"v":[...]}`, `{"t":"sub","raw":true}`
- Produces: 없음

- [ ] **Step 1: 진단 패널 마크업을 추가한다**

`flutter_app/assets/web/monitor.html` 의 `</body>` 바로 앞에 추가한다:

```html
<details id="diag" style="margin:16px;padding:12px;border-radius:12px;background:#111a28;color:#e5e7eb">
  <summary style="cursor:pointer;font-weight:700">신호 진단 — RAW 파형 · 연결 상태</summary>
  <div style="margin-top:10px;font-size:13px" id="diagLink">센서: 확인 중</div>
  <canvas id="rawCanvas" width="800" height="160"
          style="width:100%;height:160px;margin-top:10px;background:#0b1220;border-radius:8px"></canvas>
  <div style="margin-top:6px;font-size:12px;opacity:.7">
    최근 2초(2000표본). 자극 아티팩트가 주기적으로 보이면 정상이다.
  </div>
</details>
```

- [ ] **Step 2: RAW 링버퍼와 그리기를 추가한다**

`onRawPacket` 정의를 다음으로 **교체**한다:

```javascript
/* ── RAW 파형 (진단 패널) ─────────────────────────────────────────────
   최근 2초만 들고 그린다. 판정에 쓰지 않는다 — "신호를 믿어도 되나"에만
   답하는 화면이다. */
const RAW_KEEP = 2000;             // 표본 (1kHz × 2초)
const rawBuf = new Int16Array(RAW_KEEP);
let rawFill = 0;                   // 다음 기록 위치
let rawSeen = 0;                   // 누적 표본 수

function pushRawSamples(firstIdx, values) {
  for (let i = 0; i < values.length; i++) {
    rawBuf[rawFill] = values[i];
    rawFill = (rawFill + 1) % RAW_KEEP;
    rawSeen++;
  }
  drawRaw();
}

function onRawPacket(m) {
  if (Array.isArray(m.v)) pushRawSamples(m.i, m.v);
}

function drawRaw() {
  const cv = document.getElementById("rawCanvas");
  if (!cv || !document.getElementById("diag").open) return;
  const g = cv.getContext("2d");
  const W = cv.width, H = cv.height;
  g.clearRect(0, 0, W, H);

  const n = Math.min(rawSeen, RAW_KEEP);
  if (n < 2) return;

  // 표시 구간의 min/max 로 세로 스케일을 잡는다 — DC 오프셋이 달라도 보인다.
  let mn = 32767, mx = -32768;
  for (let i = 0; i < n; i++) {
    const v = rawBuf[(rawFill - n + i + RAW_KEEP) % RAW_KEEP];
    if (v < mn) mn = v;
    if (v > mx) mx = v;
  }
  const span = Math.max(1, mx - mn);

  g.strokeStyle = "#39d353";
  g.lineWidth = 1;
  g.beginPath();
  for (let i = 0; i < n; i++) {
    const v = rawBuf[(rawFill - n + i + RAW_KEEP) % RAW_KEEP];
    const x = (i / (n - 1)) * W;
    const y = H - ((v - mn) / span) * H;
    if (i === 0) g.moveTo(x, y); else g.lineTo(x, y);
  }
  g.stroke();
}
```

- [ ] **Step 3: 패널 열림에 구독을 연동한다**

같은 파일, `connect()` 정의 **아래**에 추가한다:

```javascript
/* 패널을 펼칠 때만 RAW 를 구독한다 — 접혀 있으면 대역폭도 안 쓴다.
   이것은 제어가 아니라 구독이다. 자극·세션에는 손대지 않는다. */
function sendSub(on) {
  if (ws && ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify({ t: "sub", raw: !!on }));
  }
}

document.getElementById("diag").addEventListener("toggle", ev => {
  sendSub(ev.target.open);
  if (ev.target.open) drawRaw();
});
```

그리고 `ws.onopen = () => { retry = 500; };` 을 다음으로 교체한다(재연결 후에도 구독이 유지되게):

```javascript
  ws.onopen = () => {
    retry = 500;
    const d = document.getElementById("diag");
    if (d && d.open) sendSub(true);
  };
```

- [ ] **Step 4: 연결 배지를 패널에 반영한다**

`onMessage` 의 `if (m.t === "link")` 블록에서 `linkState = m.state;` 바로 아래에 추가한다:

```javascript
    const dl = document.getElementById("diagLink");
    if (dl) {
      dl.textContent = "센서(BLE): " + m.state +
        "  ·  관찰 연결(Wi-Fi): " + (ws ? "연결됨" : "끊김");
    }
```

- [ ] **Step 5: 앱을 빌드해 실기기에 올린다**

Run: `cd flutter_app && flutter build ios --debug`
Expected: 빌드 성공.

빌드 후 iPhone (2) 에 설치·실행한다(이 저장소의 관례 — `flutter run` 은 이 환경에서 동작하지 않는다):

```bash
xcrun devicectl device install app --device "iPhone (2)" \
  flutter_app/build/ios/iphoneos/Runner.app
xcrun devicectl device process launch --device "iPhone (2)" \
  com.example.flutterApp
```

- [ ] **Step 6: 종단 수동 검증**

폰과 노트북을 같은 Wi-Fi 에 두고 다음을 확인한다.

1. ESP32 에 BLE 연결 → 게임 진입 → 폰 하단에 접속 주소와 4자리 코드가 뜬다
2. 노트북 브라우저에 그 주소 입력 → 게이지가 폰과 **같은 σ·같은 존**을 보인다
3. 주소에서 `?k=` 를 지우고 접속 → 403
4. 폰을 Wi-Fi 에서 끊음 → 웹이 회색으로 죽고 "연결 끊김 · 재연결 중" 배너, 다시 붙이면 자동 복구
5. ESP32 전원을 끔 → "센서 끊김" 배너 (Wi-Fi 끊김과 문구가 다르다)
6. 진단 패널을 펼침 → RAW 파형이 그려지고, 접으면 멈춘다
7. 브라우저 탭을 닫아도 폰 게임은 멈추지 않는다

- [ ] **Step 7: 커밋한다**

```bash
git add flutter_app/assets/web/monitor.html
git commit -m "feat(monitor): 접이식 진단 패널 — RAW 파형·연결 배지

기본 화면은 σ·존·스태미나만 본다. 오실로스코프를 상시 띄우면 판단이 아니라
노이즈가 는다. 펼칠 때만 구독하므로 접혀 있으면 대역폭도 쓰지 않는다.
BLE 끊김과 Wi-Fi 끊김을 구분해 표시한다 — 조치가 다르기 때문이다."
```

---

## 완료 확인

전부 끝나면 다음을 실행해 통과를 확인한다.

```bash
cd flutter_app
flutter analyze
flutter test
```

Expected: `No issues found!` + `All tests passed!`
