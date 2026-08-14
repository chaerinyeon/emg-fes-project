/// 치료사가 노트북에 입력할 접속 주소를 만든다.
library;

import 'dart:io';
import 'dart:math';

/// 인터페이스 하나에 붙은 IPv4 후보.
///
/// [name] 은 OS 가 준 인터페이스 이름(`en0`, `pdp_ip0`, `utun3`, `bridge100` …).
typedef LanCandidate = ({String name, String address});

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
    return pickLanAddress([
      for (final iface in ifaces)
        for (final addr in iface.addresses)
          (name: iface.name, address: addr.address),
    ]);
  } catch (_) {
    // 네트워크 조회 실패는 모니터 비활성 사유일 뿐, 세션을 막지 않는다.
    return null;
  }
}

/// 후보 중 **노트북에서 접속할 가능성이 가장 높은** 주소. 없으면 null.
///
/// ## 왜 "첫 번째 비루프백" 으로는 안 되는가
///
/// 폰에는 IPv4 가 여러 개 붙는다 — Wi-Fi(`en0`), 셀룰러(`pdp_ip0`),
/// VPN(`utun*`), 핫스팟(`bridge100`). 인터페이스 순서는 보장되지 않으므로,
/// 앞에서부터 집으면 **노트북에서 절대 닿을 수 없는 주소**(셀룰러 사설 IP,
/// VPN 터널 주소)를 치료사 화면에 띄우게 된다. 그 주소로는 브라우저가
/// `ERR_CONNECTION_TIMED_OUT` 만 낸다.
///
/// 그래서 인터페이스 종류를 1순위, 주소 대역을 2순위로 줄을 세운다. 버리지는
/// 않고 순위만 매긴다 — 셀룰러밖에 없는 상황이라면 그거라도 보여주는 편이
/// "주소를 찾지 못했어요" 보다 낫다.
String? pickLanAddress(Iterable<LanCandidate> candidates) {
  final usable = <LanCandidate>[];
  for (final c in candidates) {
    if (_isLoopback(c.address) || _isLinkLocal(c.address)) continue;
    usable.add(c);
  }
  if (usable.isEmpty) return null;

  final ranked = [
    for (var i = 0; i < usable.length; i++) (index: i, c: usable[i]),
  ];
  ranked.sort((a, b) {
    final byIface =
        _interfaceRank(a.c.name).compareTo(_interfaceRank(b.c.name));
    if (byIface != 0) return byIface;
    final byAddr = _addressRank(a.c.address).compareTo(_addressRank(b.c.address));
    if (byAddr != 0) return byAddr;
    return a.index.compareTo(b.index); // 동점이면 OS 가 준 순서를 지킨다
  });
  return ranked.first.c.address;
}

/// 인터페이스 종류 순위. 낮을수록 노트북에서 닿을 가능성이 높다.
int _interfaceRank(String name) {
  if (name.startsWith('en')) return 0; // Wi-Fi / 이더넷
  if (name.startsWith('bridge')) return 1; // 개인용 핫스팟 — 테더링한 기기는 닿는다
  if (name.startsWith('utun') ||
      name.startsWith('ipsec') ||
      name.startsWith('ppp') ||
      name.startsWith('tun') ||
      name.startsWith('tap')) {
    return 3; // VPN 터널 — 같은 VPN 에 없으면 못 닿는다
  }
  if (name.startsWith('pdp_ip')) return 4; // 셀룰러 — 통신사 NAT 안쪽
  if (name.startsWith('awdl') || name.startsWith('llw')) {
    return 5; // AirDrop 등 Apple 피어투피어
  }
  return 2; // 모르는 것은 VPN·셀룰러보다는 낫다고 본다
}

/// 주소 대역 순위. 낮을수록 가정·병원 LAN 일 가능성이 높다.
int _addressRank(String ip) {
  final o = _octets(ip);
  if (o == null) return 3;
  if (o[0] == 192 && o[1] == 168) return 0;
  if (o[0] == 172 && o[1] >= 16 && o[1] <= 31) return 1;
  if (o[0] == 100 && o[1] >= 64 && o[1] <= 127) return 4; // CGNAT — 통신사 공유 NAT
  if (o[0] == 10) return 2;
  return 3; // 공인 IP 등
}

bool _isLoopback(String ip) => ip.startsWith('127.');

bool _isLinkLocal(String ip) => ip.startsWith('169.254.');

List<int>? _octets(String ip) {
  final parts = ip.split('.');
  if (parts.length != 4) return null;
  final out = <int>[];
  for (final p in parts) {
    final v = int.tryParse(p);
    if (v == null || v < 0 || v > 255) return null;
    out.add(v);
  }
  return out;
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
