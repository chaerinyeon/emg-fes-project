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
