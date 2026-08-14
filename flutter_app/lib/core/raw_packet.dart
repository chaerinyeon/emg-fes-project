/// BLE RAW 1kHz 파형 패킷 — 단 하나의 파싱 지점.
///
/// ## 왜 여기 하나만 두는가
///
/// [RawLogger](CSV 기록)와 [SessionController.adopt](모니터 배선)가 같은
/// 바이너리 포맷을 각자 파싱하면, 포맷이 바뀌었을 때 한쪽만 고쳐지고
/// 다른 쪽은 조용히 깨진다. 그래서 디코딩은 이 파일에만 있고 양쪽 다
/// [RawPacket.parse] 를 부른다.
library;

import 'dart:typed_data';

/// 파싱된 RAW 패킷 1건.
class RawPacket {
  const RawPacket({required this.firstSampleIndex, required this.samples});

  /// 세션 시작 후 이 패킷 첫 샘플의 **인덱스**.
  ///
  /// 밀리초가 아니다. 펌웨어가 1kHz 이던 시절에는 1샘플=1ms 라 둘이 같았고
  /// 이름도 `firstSampleMs` 였지만, 4kHz 에서는 1샘플=0.25ms 다. 이름이
  /// 거짓이면 호출부가 조용히 4배 틀린 시간축을 만든다.
  ///
  /// BLE 끊김 중에도 계속 증가한다 — 수신 측(웹)이 이 값으로 유실을 감지한다.
  final int firstSampleIndex;

  /// raw ADC 값(부호 있음, 16비트 범위).
  final List<int> samples;

  /// 펌웨어 `sendRawBatch` 포맷(little-endian) 1건을 파싱한다.
  ///
  /// `[uint32 firstSampleIndex][uint16 count][int16 raw × count]` —
  /// 6 + 2×count 바이트. 헤더가 안 들어오거나, count 가 0 이하이거나,
  /// 선언된 count 만큼의 표본이 실제로 없으면(잘린 패킷) `null` 을 돌려준다
  /// — 예외를 던지지 않는다. 호출자(BLE notify 콜백)에서 이 패킷 하나만
  /// 버리고 세션은 계속돼야 하기 때문이다.
  static RawPacket? parse(List<int> bytes) {
    if (bytes.length < 6) return null;
    final bd = ByteData.sublistView(Uint8List.fromList(bytes));
    final firstMs = bd.getUint32(0, Endian.little);
    final count = bd.getUint16(4, Endian.little);
    if (count <= 0 || bytes.length < 6 + 2 * count) return null;
    final samples = List<int>.filled(count, 0);
    for (var i = 0; i < count; i++) {
      samples[i] = bd.getInt16(6 + 2 * i, Endian.little);
    }
    return RawPacket(firstSampleIndex: firstMs, samples: samples);
  }
}
