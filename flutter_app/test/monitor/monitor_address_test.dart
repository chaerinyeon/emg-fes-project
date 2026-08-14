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

  // 폰에는 IPv4 가 여러 개 붙는다 — Wi-Fi(en0), 셀룰러(pdp_ip0), VPN(utun3),
  // 핫스팟(bridge100). "비루프백 중 첫 번째"를 그냥 쓰면 노트북에서 절대
  // 닿을 수 없는 주소를 치료사에게 보여주게 된다.
  group('pickLanAddress', () {
    test('후보가 없으면 null', () {
      expect(pickLanAddress([]), isNull);
    });

    test('셀룰러(pdp_ip0)보다 Wi-Fi(en0)를 고른다', () {
      expect(
        pickLanAddress([
          (name: 'pdp_ip0', address: '10.62.114.8'),
          (name: 'en0', address: '172.30.1.44'),
        ]),
        '172.30.1.44',
      );
    });

    test('인터페이스 순서가 반대여도 결과는 같다', () {
      expect(
        pickLanAddress([
          (name: 'en0', address: '172.30.1.44'),
          (name: 'pdp_ip0', address: '10.62.114.8'),
        ]),
        '172.30.1.44',
      );
    });

    test('VPN(utun)은 고르지 않는다', () {
      expect(
        pickLanAddress([
          (name: 'utun3', address: '10.2.0.7'),
          (name: 'en0', address: '192.168.1.180'),
        ]),
        '192.168.1.180',
      );
    });

    test('링크로컬(169.254)과 루프백은 제외한다', () {
      expect(
        pickLanAddress([
          (name: 'lo0', address: '127.0.0.1'),
          (name: 'en1', address: '169.254.232.84'),
          (name: 'en0', address: '192.168.0.5'),
        ]),
        '192.168.0.5',
      );
    });

    test('CGNAT(100.64/10)은 셀룰러라 제외한다', () {
      expect(
        pickLanAddress([
          (name: 'en2', address: '100.83.4.19'),
          (name: 'en0', address: '172.20.10.3'),
        ]),
        '172.20.10.3',
      );
    });

    // 핫스팟을 켠 폰은 bridge100 에 172.20.10.1 을 갖는다. 테더링한
    // 노트북에서는 이 주소로 닿으므로 버리지는 않되, 진짜 Wi-Fi 가 있으면
    // 그쪽이 낫다.
    test('en0 과 bridge100 이 함께 있으면 en0 을 고른다', () {
      expect(
        pickLanAddress([
          (name: 'bridge100', address: '172.20.10.1'),
          (name: 'en0', address: '192.168.1.7'),
        ]),
        '192.168.1.7',
      );
    });

    test('쓸 만한 것이 bridge100 뿐이면 그것을 고른다', () {
      expect(
        pickLanAddress([
          (name: 'lo0', address: '127.0.0.1'),
          (name: 'bridge100', address: '172.20.10.1'),
        ]),
        '172.20.10.1',
      );
    });

    test('셀룰러밖에 없으면 그것이라도 준다', () {
      expect(
        pickLanAddress([(name: 'pdp_ip0', address: '10.62.114.8')]),
        '10.62.114.8',
      );
    });

    test('제외 대상만 있으면 null', () {
      expect(
        pickLanAddress([
          (name: 'lo0', address: '127.0.0.1'),
          (name: 'en1', address: '169.254.232.84'),
        ]),
        isNull,
      );
    });
  });
}
