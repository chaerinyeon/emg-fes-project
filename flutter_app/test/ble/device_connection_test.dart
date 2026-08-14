import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/ble/device_connection.dart';

/// 펌웨어 sendRawBatch 포맷 1건을 만든다.
/// `[uint32 firstSampleIndex][uint16 count][int16 raw × count]` little-endian.
List<int> packet(int firstMs, List<int> samples) {
  final b = ByteData(6 + 2 * samples.length);
  b.setUint32(0, firstMs, Endian.little);
  b.setUint16(4, samples.length, Endian.little);
  for (var i = 0; i < samples.length; i++) {
    b.setInt16(6 + 2 * i, samples[i], Endian.little);
  }
  return b.buffer.asUint8List();
}

void main() {
  group('rawSamples — 패킷 → 표본 스트림', () {
    test('패킷 하나를 (시각, ADC) 쌍으로 펼친다', () async {
      final out = await rawSamples(
        Stream.fromIterable([
          packet(1000, [1850, 1851, 1852])
        ]),
      ).toList();

      expect(out, [(1000, 1850), (1001, 1851), (1002, 1852)]);
    });

    test('1kHz라 표본 1개가 1ms다', () async {
      final out = await rawSamples(
        Stream.fromIterable([
          packet(0, List<int>.filled(100, 1862))
        ]),
      ).toList();

      expect(out.length, 100);
      expect(out.first.$1, 0);
      expect(out.last.$1, 99);
    });

    test('연속 패킷의 시각이 이어진다', () async {
      final out = await rawSamples(
        Stream.fromIterable([
          packet(0, [1, 2]),
          packet(2, [3, 4]),
        ]),
      ).toList();

      expect(out.map((e) => e.$1).toList(), [0, 1, 2, 3]);
    });

    test('유실 구간은 시각에 구멍으로 남는다', () async {
      // BLE 끊김 중에도 firstSampleIndex 는 계속 증가한다.
      // 시각을 새로 만들어 메우면 위상 고정이 조용히 어긋난다.
      final out = await rawSamples(
        Stream.fromIterable([
          packet(0, [1, 2]),
          packet(500, [3, 4]),
        ]),
      ).toList();

      expect(out.map((e) => e.$1).toList(), [0, 1, 500, 501]);
    });

    test('잘린 패킷 하나는 버리고 세션은 계속된다', () async {
      final out = await rawSamples(
        Stream.fromIterable([
          packet(0, [1, 2]),
          <int>[1, 2, 3], // 헤더도 안 되는 쓰레기
          packet(10, [5, 6]),
        ]),
      ).toList();

      expect(out.map((e) => e.$1).toList(), [0, 1, 10, 11]);
    });

    test('음수 ADC도 부호를 지킨다', () async {
      final out = await rawSamples(
        Stream.fromIterable([
          packet(0, [-1200, 900])
        ]),
      ).toList();

      expect(out.map((e) => e.$2).toList(), [-1200, 900]);
    });

    test('빈 스트림은 빈 결과다', () async {
      final out = await rawSamples(const Stream<List<int>>.empty()).toList();
      expect(out, isEmpty);
    });
  });

  group('ReconnectPolicy — 백오프', () {
    const p = ReconnectPolicy(
      base: Duration(seconds: 1),
      max: Duration(seconds: 30),
    );

    test('첫 시도는 base다', () {
      expect(p.delayFor(0), const Duration(seconds: 1));
    });

    test('지수적으로 늘어난다', () {
      expect(p.delayFor(1), const Duration(seconds: 2));
      expect(p.delayFor(2), const Duration(seconds: 4));
      expect(p.delayFor(3), const Duration(seconds: 8));
    });

    test('상한을 넘지 않는다', () {
      expect(p.delayFor(10), const Duration(seconds: 30));
      expect(p.delayFor(1000), const Duration(seconds: 30));
    });

    test('상한이 있어야 재연결이 영영 멀어지지 않는다', () {
      for (var i = 0; i < 50; i++) {
        expect(p.delayFor(i), lessThanOrEqualTo(const Duration(seconds: 30)));
      }
    });
  });

  group('구독 해제가 끝나야 세션 마무리가 진행된다', () {
    test('표본 스트림 구독을 취소하면 즉시 완료된다', () async {
      // ★ 여기서 막히면 세션 저장이 통째로 사라진다.
      //   _finish() 는 `await _sampleSub.cancel()` 뒤에 기록을 저장한다.
      //   취소가 완결되지 않으면 그 뒤 코드가 한 줄도 실행되지 않는다.
      final packets = StreamController<List<int>>.broadcast();
      addTearDown(packets.close);

      final sub = rawSamples(packets.stream).listen((_) {});
      packets.add(packet(1000, const [10, 20, 30]));
      await pumpEventQueue();

      await sub.cancel().timeout(
            const Duration(seconds: 2),
            onTimeout: () => fail('취소가 완결되지 않았다 — 세션 기록이 저장되지 않는다'),
          );
    });

    test('패킷이 더 오지 않아도 취소가 완결된다', () async {
      final packets = StreamController<List<int>>.broadcast();
      addTearDown(packets.close);

      final sub = rawSamples(packets.stream).listen((_) {});
      await pumpEventQueue();

      await sub.cancel().timeout(
            const Duration(seconds: 2),
            onTimeout: () => fail('취소가 완결되지 않았다'),
          );
    });
  });
}
