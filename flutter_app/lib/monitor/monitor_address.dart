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
