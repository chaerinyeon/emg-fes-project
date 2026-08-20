// RE:FIT BLE 바이너리 프로토콜 v0.2 코덱.
//
// 계약 원문: docs/RE-FIT_BLE_Protocol_v0.2.md
// 펌웨어:    firmware/emg_fes_controller/emg_fes_controller.ino
//
// Flutter 의존성 없는 순수 Dart — BLE 전송 계층과 분리해 두면 CSV 재생·테스트에서
// 그대로 재사용할 수 있다. 여기서는 바이트만 다루고 상태는 갖지 않는다(seq 제외).
import 'dart:typed_data';

// ===== 프로토콜 상수 =====
const int kRefitProtoVersion = 0x02;

// msg_type (업링크 0x0X / 다운링크 0x1X)
const int kMsgEpoch = 0x01;
const int kMsgStatus = 0x02;
const int kMsgEvent = 0x03;
const int kMsgJudgment = 0x11;
const int kMsgHeartbeat = 0x12;
const int kMsgSessionControl = 0x14;

// SESSION_CONTROL cmd — START/STOP 은 '기록', STIM_* 은 '자극'. 분리돼 있다.
const int kScRequestStart = 1;
const int kScRequestStop = 2;
const int kScStimEnable = 3;
const int kScStimDisable = 4;

// JUDGMENT action
const int kActHold = 0;
const int kActDecrease = 1;
const int kActIncrease = 2;
const int kActStop = 3;

// reliability
const int kRelHigh = 0;
const int kRelMed = 1;
const int kRelLow = 2;

// EVENT id
const int kEvSessionStart = 1;
const int kEvRestEnd = 2;
const int kEvSessionStop = 3;
const int kEvFault = 4;
const int kEvCalibDone = 5;

const List<String> kMcuStateNames = [
  'IDLE',
  'CALIBRATING',
  'RUNNING',
  'SAFE_HOLD',
  'STIM_OFF',
  'FAULT',
];

String mcuStateName(int s) =>
    (s >= 0 && s < kMcuStateNames.length) ? kMcuStateNames[s] : 'STATE_$s';

String eventName(int id) => switch (id) {
  kEvSessionStart => 'SESSION_START',
  kEvRestEnd => 'REST_END',
  kEvSessionStop => 'SESSION_STOP',
  kEvFault => 'FAULT',
  kEvCalibDone => 'CALIB_DONE',
  _ => 'EVENT_$id',
};

/// CRC8 — poly 0x07, init 0x00, 반사 없음, 최종 XOR 없음.
/// 펌웨어 crc8() 과 동일. [len] 미지정 시 [data] 전체.
int refitCrc8(List<int> data, [int? len]) {
  var c = 0;
  final n = len ?? data.length;
  for (var i = 0; i < n; i++) {
    c ^= data[i] & 0xFF;
    for (var b = 0; b < 8; b++) {
      c = (c & 0x80) != 0 ? ((c << 1) ^ 0x07) & 0xFF : (c << 1) & 0xFF;
    }
  }
  return c;
}

// ===== 업링크 메시지 =====

sealed class RefitMessage {
  final int seq;
  final int sessionId;
  const RefitMessage(this.seq, this.sessionId);
}

/// 자극 1회당 1건. 판정에 쓰는 유일한 데이터.
class EpochMsg extends RefitMessage {
  final int stimIndex; // 세션 누적 자극 번호, 1부터. 결번 = 에폭 유실
  final int tMs; // 자극 onset 의 실제 millis()
  final int sampleIndex; // 자극 onset 의 샘플 인덱스 (세션 시작 시 0)
  final int spike; // 자극 스파이크 진폭 (onset ~ +2ms 구간에서만 측정)
  final int p2p; // M-wave 창의 peak-to-peak
  final int flags; // bit0 valid · bit1 창 포화 · bit2 스파이크 포화
  final Int16List samples; // DC 제거된 ADC, +2 ~ +15ms

  const EpochMsg({
    required int seq,
    required int sessionId,
    required this.stimIndex,
    required this.tMs,
    required this.sampleIndex,
    required this.spike,
    required this.p2p,
    required this.flags,
    required this.samples,
  }) : super(seq, sessionId);

  bool get valid => (flags & 0x01) != 0;

  /// M-wave 창 표본이 ADC 레일에 닿았다 → 면적이 실제보다 작게 나온다.
  bool get windowSaturated => (flags & 0x02) != 0;

  /// 자극 스파이크가 레일에 닿았다 → R 의 분모가 "레일"이라는 상수가 되어
  /// 정규화가 아무 일도 하지 않는다. 전극 드리프트 상쇄가 사라진다.
  bool get spikeSaturated => (flags & 0x04) != 0;

  bool get saturated => windowSaturated || spikeSaturated;

  /// 추세에 넣어도 되는 에폭인가. 포화된 것은 값이 잘려 있어 R 을 믿을 수 없다.
  bool get usableForTrend => valid && !saturated;

  /// M-wave 면적 = Σ|표본|. 정규화 전 원시량.
  int get area {
    var a = 0;
    for (final v in samples) {
      a += v.abs();
    }
    return a;
  }

  /// 검증된 피로 지표 R = 면적 ÷ 자극 스파이크.
  /// 전극 드리프트는 분자·분모를 함께 움직여 상쇄되고 근육 피로만 남는다.
  /// 정규화 없는 생 M-wave 는 전극이 밀린 것만으로 위양성이 난다.
  double get r {
    final s = spike.abs();
    return s == 0 ? 0 : area / s;
  }
}

class StatusMsg extends RefitMessage {
  final int tMs; // millis()
  final int state; // 0 IDLE · 1 CALIBRATING · 2 RUNNING · 3 SAFE_HOLD · 4 STIM_OFF · 5 FAULT
  final int level; // 개루프 추정치 — 기기 세기를 읽을 수 없다
  final bool stimOn;
  final int health; // bit0 watchdog · bit1 hardlimit · bit2 batt · bit3 sensor
  final int lastCmdSeqAck; // 보낸 seq 를 따라오지 않으면 그 명령은 거부된 것
  final int sampleRate;
  final int winStartMs;
  final int winEndMs;
  final int maxLevel;

  const StatusMsg({
    required int seq,
    required int sessionId,
    required this.tMs,
    required this.state,
    required this.level,
    required this.stimOn,
    required this.health,
    required this.lastCmdSeqAck,
    required this.sampleRate,
    required this.winStartMs,
    required this.winEndMs,
    required this.maxLevel,
  }) : super(seq, sessionId);

  String get stateName => mcuStateName(state);

  List<String> get healthFlags => [
    if (health & 0x01 != 0) 'WATCHDOG',
    if (health & 0x02 != 0) 'HARDLIMIT',
    if (health & 0x04 != 0) 'BATT',
    if (health & 0x08 != 0) 'SENSOR',
  ];
}

class EventMsg extends RefitMessage {
  final int tMs;
  final int eventId;
  final int detail;

  const EventMsg({
    required int seq,
    required int sessionId,
    required this.tMs,
    required this.eventId,
    required this.detail,
  }) : super(seq, sessionId);

  String get name => eventName(eventId);
}

/// 업링크 패킷 1건 디코드. 계약 위반(길이·버전·CRC)이면 null — 조용히 버린다.
RefitMessage? decodeRefit(List<int> raw) {
  if (raw.length < 7) return null;
  final b = Uint8List.fromList(raw);
  if (b[0] != kRefitProtoVersion) return null;
  if (refitCrc8(b, b.length - 1) != b[b.length - 1]) return null;

  final d = ByteData.sublistView(b);
  final type = b[1];
  final seq = d.getUint16(2, Endian.little);
  final sess = d.getUint16(4, Endian.little);

  switch (type) {
    case kMsgEpoch:
      // 헤더6 | stim4 | t_ms4 | sample4 | spike2 | p2p2 | flags1 | n1 | 표본2n | crc1
      if (b.length < 25) return null;
      final n = b[23];
      if (24 + 2 * n + 1 > b.length) return null;
      final samples = Int16List(n);
      for (var i = 0; i < n; i++) {
        samples[i] = d.getInt16(24 + 2 * i, Endian.little);
      }
      return EpochMsg(
        seq: seq,
        sessionId: sess,
        stimIndex: d.getUint32(6, Endian.little),
        tMs: d.getUint32(10, Endian.little),
        sampleIndex: d.getUint32(14, Endian.little),
        spike: d.getInt16(18, Endian.little),
        p2p: d.getInt16(20, Endian.little),
        flags: b[22],
        samples: samples,
      );

    case kMsgStatus:
      if (b.length < 22) return null;
      return StatusMsg(
        seq: seq,
        sessionId: sess,
        tMs: d.getUint32(6, Endian.little),
        state: b[10],
        level: b[11],
        stimOn: (b[12] & 0x01) != 0,
        health: b[13],
        lastCmdSeqAck: d.getUint16(14, Endian.little),
        sampleRate: d.getUint16(16, Endian.little),
        winStartMs: d.getInt8(18),
        winEndMs: d.getInt8(19),
        maxLevel: b[20],
      );

    case kMsgEvent:
      if (b.length < 13) return null;
      return EventMsg(
        seq: seq,
        sessionId: sess,
        tMs: d.getUint32(6, Endian.little),
        eventId: b[10],
        detail: b[11],
      );

    default:
      return null;
  }
}

// ===== 다운링크 인코더 =====

Uint8List _header(int type, int seq, int sessionId) {
  final b = Uint8List(6);
  final d = ByteData.sublistView(b);
  b[0] = kRefitProtoVersion;
  b[1] = type;
  d.setUint16(2, seq & 0xFFFF, Endian.little);
  d.setUint16(4, sessionId & 0xFFFF, Endian.little);
  return b;
}

Uint8List _seal(Uint8List body) {
  final out = Uint8List(body.length + 1);
  out.setRange(0, body.length, body);
  out[body.length] = refitCrc8(body);
  return out;
}

/// SESSION_CONTROL — 8바이트. [cmd] 는 kSc* 중 하나.
Uint8List buildSessionControl(int cmd, {int seq = 0, int sessionId = 0}) {
  final body = Uint8List(7);
  body.setRange(0, 6, _header(kMsgSessionControl, seq, sessionId));
  body[6] = cmd;
  return _seal(body);
}

/// HEARTBEAT — 11바이트. 워치독 유지가 유일한 목적. 500ms 주기 권장.
Uint8List buildHeartbeat({int seq = 0, int sessionId = 0, int? phoneMs}) {
  final body = Uint8List(10);
  body.setRange(0, 6, _header(kMsgHeartbeat, seq, sessionId));
  ByteData.sublistView(body).setUint32(
    6,
    (phoneMs ?? DateTime.now().millisecondsSinceEpoch) & 0xFFFFFFFF,
    Endian.little,
  );
  return _seal(body);
}

/// JUDGMENT — 19바이트. [targetLevel] 은 **절대 목표 세기**(상대 증감 아님).
/// 장치 세기를 읽을 수 없어 current_level 이 추정치이므로, 상대 증감은 오차가
/// 누적되기만 하지만 절대 목표는 추정이 맞는 한 수렴한다.
Uint8List buildJudgment({
  required int action,
  required int targetLevel,
  int stage = 0,
  int reliability = kRelHigh,
  int tRefMs = 0,
  int stimIndexRef = 0,
  int seq = 0,
  int sessionId = 0,
}) {
  final body = Uint8List(18);
  body.setRange(0, 6, _header(kMsgJudgment, seq, sessionId));
  final d = ByteData.sublistView(body);
  d.setUint32(6, tRefMs & 0xFFFFFFFF, Endian.little);
  d.setUint32(10, stimIndexRef & 0xFFFFFFFF, Endian.little);
  body[14] = stage & 0xFF;
  body[15] = action & 0xFF;
  body[16] = targetLevel & 0xFF;
  body[17] = reliability & 0xFF;
  return _seal(body);
}
