import 'dart:typed_data';

import 'package:flutter_app/core/raw_packet.dart';
import 'package:flutter_test/flutter_test.dart';

/// [RawPacket.parse] 입력용 바이트 조립 헬퍼.
/// 펌웨어 포맷: [uint32 firstSampleIndex][uint16 count][int16 raw × count],
/// 전부 little-endian.
List<int> _pack(int firstSampleIndex, List<int> samples, {int? countOverride}) {
  final count = countOverride ?? samples.length;
  final bd = ByteData(6 + 2 * samples.length);
  bd.setUint32(0, firstSampleIndex, Endian.little);
  bd.setUint16(4, count, Endian.little);
  for (var i = 0; i < samples.length; i++) {
    bd.setInt16(6 + 2 * i, samples[i], Endian.little);
  }
  return bd.buffer.asUint8List().toList(); // growable — 일부 테스트가 이어붙인다
}

void main() {
  test('정상 패킷을 파싱한다', () {
    final bytes = _pack(1000, [10, -20, 30]);
    final pkt = RawPacket.parse(bytes);

    expect(pkt, isNotNull);
    expect(pkt!.firstSampleIndex, 1000);
    expect(pkt.samples, [10, -20, 30]);
  });

  test('100표본 패킷(실제 펌웨어 배치 크기)을 파싱한다', () {
    final samples = List<int>.generate(100, (i) => i - 50);
    final bytes = _pack(500000, samples);
    final pkt = RawPacket.parse(bytes);

    expect(pkt, isNotNull);
    expect(pkt!.samples, hasLength(100));
    expect(pkt.samples.first, -50);
    expect(pkt.samples.last, 49);
  });

  test('음수 int16 왕복이 부호를 보존한다', () {
    final bytes = _pack(0, [-32768, 32767, -1]);
    final pkt = RawPacket.parse(bytes);

    expect(pkt!.samples, [-32768, 32767, -1]);
  });

  test('firstSampleIndex 는 uint32 전 범위를 담는다', () {
    // BLE 끊김 없이 오래 도는 세션에서도 인덱스가 넘치지 않아야 한다.
    final bytes = _pack(4000000000, [1]);
    final pkt = RawPacket.parse(bytes);

    expect(pkt!.firstSampleIndex, 4000000000);
  });

  test('6바이트 미만(헤더도 못 채움)은 폐기한다', () {
    expect(RawPacket.parse(const [1, 2, 3, 4, 5]), isNull);
  });

  test('빈 바이트는 폐기한다', () {
    expect(RawPacket.parse(const []), isNull);
  });

  test('count 가 0 이면 폐기한다', () {
    final bytes = _pack(0, [], countOverride: 0);
    expect(RawPacket.parse(bytes), isNull);
  });

  test('헤더는 count=100 이라 주장하지만 표본이 잘린 패킷은 폐기한다', () {
    // 실제로는 표본 10개 분량 바이트만 있는데 헤더의 count 는 100.
    final bd = ByteData(6 + 2 * 10);
    bd.setUint32(0, 0, Endian.little);
    bd.setUint16(4, 100, Endian.little); // count 를 거짓으로 부풀림
    for (var i = 0; i < 10; i++) {
      bd.setInt16(6 + 2 * i, i, Endian.little);
    }
    expect(RawPacket.parse(bd.buffer.asUint8List()), isNull);
  });

  test('표본 1개만 모자라게 잘린 패킷도 폐기한다', () {
    final full = _pack(0, List<int>.generate(5, (i) => i));
    final truncated = full.sublist(0, full.length - 1); // 마지막 1바이트 제거
    expect(RawPacket.parse(truncated), isNull);
  });

  test('여분 바이트가 있어도 count 만큼만 읽는다', () {
    // 다음 패킷이 같은 버퍼에 이미 붙어 있는 상황(과도한 청크)을 흉내낸다.
    final bytes = _pack(0, [7, 8, 9])..addAll([99, 99, 99, 99]);
    final pkt = RawPacket.parse(bytes);

    expect(pkt, isNotNull);
    expect(pkt!.samples, [7, 8, 9]);
  });
}
