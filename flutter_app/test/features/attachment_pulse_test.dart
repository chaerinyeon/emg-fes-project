import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_app/ble/device_connection.dart';
import 'package:flutter_app/ble/stim_controller.dart';
import 'package:flutter_app/data/local/session_store.dart';
import 'package:flutter_app/features/session/session_orchestrator.dart';
import 'package:flutter_app/session/session_controller.dart';
import 'package:flutter_app/signal/constants.dart';

/// **실기기처럼** 구는 링크.
///
/// `SyntheticFesLink` 는 자극 명령과 무관하게 아티팩트를 내보낸다 — 개발
/// 편의로는 맞지만, 그 탓에 "자극이 없으면 부착 확인을 통과할 수 없다"는
/// 실기기 교착이 테스트에 한 번도 걸리지 않았다. 여기서는 펌웨어처럼
/// **`trigger_stim` 이 켜졌을 때만** 자극 파형을 낸다.
class DeviceLikeLink implements DeviceLink {
  DeviceLikeLink({this.dc = 1862, this.noise = 12});

  final int dc;
  final int noise;

  final _state = StreamController<LinkState>.broadcast();
  final _packets = StreamController<List<int>>.broadcast();

  LinkState _current = LinkState.disconnected;
  bool stimOn = false;
  int _sampleIdx = 0;
  int _seed = 7;

  @override
  LinkState get state => _current;
  @override
  Stream<LinkState> get stateStream => _state.stream;
  @override
  Stream<List<int>> get rawPackets => _packets.stream;

  @override
  Future<void> connect() async {
    _current = LinkState.connected;
    _state.add(_current);
  }

  @override
  Future<void> disconnect() async {
    _current = LinkState.disconnected;
    _state.add(_current);
  }

  @override
  Future<void> send(Map<String, dynamic> cmd) async {
    // 펌웨어의 triggerStimulation() 과 같은 자리.
    if (cmd['cmd'] == 'trigger_stim') stimOn = cmd['on'] == true;
    if (cmd['cmd'] == 'emergency') stimOn = false;
  }

  /// 결정적 의사난수 — 테스트가 매번 같은 신호를 본다.
  int _rand(int n) {
    _seed = (_seed * 1103515245 + 12345) & 0x7FFFFFFF;
    return _seed % n;
  }

  /// 실기기와 같은 샘플레이트. 파형 눈금은 ms 로 정의하고 여기서 환산한다.
  static const _clock = SampleClock(kDeviceSampleRateHz);

  /// 100 **표본** 한 묶음. 실시간 길이는 `100/fs` 초다.
  void emitPacket() {
    final period = _clock.samples(kStimPeriodMs);
    final on = _clock.samples(kStimOnMs);
    final isi = _clock.samples(31);
    final peakPos = _clock.samples(8);
    final peakNeg = _clock.samples(12);
    final artifact = _clock.samples(1);

    final samples = List<int>.generate(100, (i) {
      final t = _sampleIdx + i;
      var v = dc + _rand(2 * noise + 1) - noise;

      // 자극이 꺼져 있으면 잡음뿐이다. 실기기가 그렇다.
      if (stimOn) {
        final inBurst = t % period;
        if (inBurst < on) {
          final d = inBurst % isi;
          if (d < artifact) {
            v = dc + 900; // 자극 아티팩트
          } else if (d == peakPos) {
            v = dc + 300; // M-wave 양의 정점
          } else if (d == peakNeg) {
            v = dc - 300; // 음의 정점
          }
        }
      }
      return v;
    });
    _packets.add(_encode(_sampleIdx, samples));
    _sampleIdx += 100;
  }

  /// [ms] 밀리초 분량. 패킷 하나가 100 표본이라 fs 로 환산해야 한다.
  void emitFor(int ms) {
    final n = (_clock.samples(ms) / 100).ceil();
    for (var i = 0; i < n; i++) {
      emitPacket();
    }
  }

  /// 펌웨어 `sendRawBatch` 포맷 그대로 — `RawPacket.parse` 가 읽는 6바이트
  /// 헤더 + int16 표본이다.
  List<int> _encode(int firstMs, List<int> samples) {
    final b = ByteData(6 + 2 * samples.length);
    b.setUint32(0, firstMs, Endian.little);
    b.setUint16(4, samples.length, Endian.little);
    for (var i = 0; i < samples.length; i++) {
      b.setInt16(6 + 2 * i, samples[i], Endian.little);
    }
    return b.buffer.asUint8List();
  }

  Future<void> dispose() async {
    await _state.close();
    await _packets.close();
  }
}

void main() {
  late DeviceLikeLink link;
  late SessionOrchestrator o;

  setUp(() async {
    link = DeviceLikeLink();
    o = SessionOrchestrator(
      link: link,
      store: InMemorySessionStore(),
      sessionId: 's1',
      patientId: 'p1',
      deviceId: 'd1',
    );
    await link.connect();
    await o.begin();
  });

  tearDown(() async {
    await o.stim.stop(reason: StimStopReason.sessionEnd);
    o.dispose();
    await link.dispose();
  });

  /// 표본을 [ms] 만큼 흘린다. 실시간을 기다리지 않는다.
  Future<void> pump(int ms) async {
    link.emitFor(ms);
    await pumpEventQueue();
  }

  test('자극이 없으면 패드 판정이 서지 않는다 — 실기기의 교착', () async {
    expect(o.state, SessionState.attachmentCheck);

    // 자극을 켜지 않은 채 한참 흘려도(실기기의 기본 상태) 반응이 없다.
    await pump(20000);

    // 지금 화면이 쓰는 판정은 링크만 본다(kTrustLinkForAttachment). 여기서
    // 지키려는 것은 **신호 기반 판정**이 여전히 옳게 도는가다 — 되돌릴 때
    // 근거가 남아 있어야 한다.
    final r = o.runSignalAttachmentCheck();
    expect(r.emgElectrodeOk, isTrue, reason: '전극은 붙어 있다');
    expect(r.deviceOk, isTrue);
    expect(r.stimPadOk, isFalse,
        reason: '자극이 안 나갔으니 반응도 없다 — 여기서 전 구간이 막혔었다');
    expect(r.passed, isFalse);
  });

  test('테스트 자극을 걸면 통과한다', () async {
    // 표본을 계속 흘리면서 확인을 돌린다.
    final ticker = Timer.periodic(
      const Duration(milliseconds: 1),
      (_) => link.emitPacket(),
    );
    addTearDown(ticker.cancel);

    final r = await o.runAttachmentCheckWithTestPulse(
      calibrationTimeout: const Duration(seconds: 3),
      pulseWindow: const Duration(milliseconds: 400),
      settle: const Duration(milliseconds: 200),
      poll: const Duration(milliseconds: 10),
    );

    expect(r.emgElectrodeOk, isTrue,
        reason: '자극은 영점 보정이 끝난 뒤에 켜져야 한다');
    expect(r.stimPadOk, isTrue, reason: '자극 반응이 잡혀야 한다');
    expect(r.passed, isTrue);
  });

  test('확인이 끝나면 자극은 반드시 꺼져 있다', () async {
    final ticker = Timer.periodic(
      const Duration(milliseconds: 1),
      (_) => link.emitPacket(),
    );
    addTearDown(ticker.cancel);

    await o.runAttachmentCheckWithTestPulse(
      calibrationTimeout: const Duration(seconds: 3),
      pulseWindow: const Duration(milliseconds: 300),
      settle: const Duration(milliseconds: 100),
      poll: const Duration(milliseconds: 10),
    );

    expect(o.stim.isStimulating, isFalse);
    expect(link.stimOn, isFalse, reason: '기기에도 끄라고 보냈어야 한다');
  });

  test('영점 보정 구간에는 자극이 나가지 않는다', () async {
    // 보정이 끝나기 전 상태를 만든 뒤, 확인을 걸자마자 자극 여부를 본다.
    expect(o.pipeline.dcOffset, isNull);

    final pending = o.runAttachmentCheckWithTestPulse(
      calibrationTimeout: const Duration(milliseconds: 300),
      pulseWindow: const Duration(milliseconds: 100),
      settle: Duration.zero,
      poll: const Duration(milliseconds: 10),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(link.stimOn, isFalse,
        reason: '도입부에 자극이 섞이면 전극 판정이 통째로 깨진다');
    await pending;
  });

  test('부착 확인 상태가 아니면 자극을 켜지 않는다', () async {
    final ticker = Timer.periodic(
      const Duration(milliseconds: 1),
      (_) => link.emitPacket(),
    );
    addTearDown(ticker.cancel);

    // 확인을 통과시켜 다음 단계로 보낸다.
    o.submitAttachmentCheck(const AttachmentCheck(
        emgElectrodeOk: true, stimPadOk: true, deviceOk: true));
    expect(o.state, SessionState.intensityWizard);

    var sawStim = false;
    final watch = Timer.periodic(const Duration(milliseconds: 5), (_) {
      if (link.stimOn) sawStim = true;
    });
    addTearDown(watch.cancel);

    await o.runAttachmentCheckWithTestPulse(
      calibrationTimeout: const Duration(milliseconds: 200),
      pulseWindow: const Duration(milliseconds: 200),
      settle: Duration.zero,
      poll: const Duration(milliseconds: 10),
    );

    expect(sawStim, isFalse, reason: '확인 단계 밖에서는 이 경로로 자극이 안 나간다');
  });
}
