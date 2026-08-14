import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_app/core/constants.dart';
import 'package:flutter_app/core/raw_packet.dart';
import 'package:flutter_app/services/profile_service.dart';
import 'package:flutter_app/services/session_controller.dart';
import 'package:flutter_app/services/simulator_service.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

/// [BluetoothCharacteristic.write] 는 실제로 부르면 플랫폼 채널을 거쳐
/// device 연결 상태를 확인하고 예외를 던진다 — 이 프로젝트의 테스트 환경엔
/// 진짜 BLE 스택이 없다. `write()` 를 오버라이드해 호출 횟수만 세는 순수
/// Dart 더블로 대신한다: 생성자(원본)는 필드 대입뿐이라 플랫폼 호출이
/// 없고, 오버라이드한 `write()` 도 마찬가지다.
class _RecordingCmdChar extends BluetoothCharacteristic {
  _RecordingCmdChar()
      : super(
          remoteId: const DeviceIdentifier('AA:BB:CC:DD:EE:FF'),
          serviceUuid: Guid(kServiceUuid),
          characteristicUuid: Guid(kCmdCharUuid),
        );

  int writeCount = 0;

  @override
  Future<void> write(
    List<int> value, {
    bool withoutResponse = false,
    bool allowLongWrite = false,
    int timeout = 15,
  }) async {
    writeCount++;
  }
}

/// RAW 패킷 바이트 조립 헬퍼. 펌웨어 포맷과 동일 —
/// [uint32 firstSampleIndex][uint16 count][int16 raw × count], little-endian.
List<int> _rawBytes(int firstSampleIndex, List<int> samples) {
  final bd = ByteData(6 + 2 * samples.length);
  bd.setUint32(0, firstSampleIndex, Endian.little);
  bd.setUint16(4, samples.length, Endian.little);
  for (var i = 0; i < samples.length; i++) {
    bd.setInt16(6 + 2 * i, samples[i], Endian.little);
  }
  return bd.buffer.asUint8List();
}

void main() {
  // startSimulator() 가 gProfileService.active 를 읽는다. Hive 를 초기화
  // 해야 하는 이유는 test/monitor/monitor_e2e_test.dart 와 동일.
  late Directory hiveDir;

  setUpAll(() async {
    hiveDir = await Directory.systemTemp.createTemp('session_adopt_hive_');
    Hive.init(hiveDir.path);
    await gProfileService.init();
  });

  tearDownAll(() async {
    await Hive.close();
    if (await hiveDir.exists()) await hiveDir.delete(recursive: true);
  });

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

  test('adopt 후 disconnect() 해도 더 이상 받지 않는다', () async {
    // disconnect() 는 원래 scanAndConnect() 의 _dataSub 만 정리했다 —
    // startSimulator() 가 connState=='connected' 일 때 disconnect() 를
    // 부르므로, adopt 된 컨트롤러에서 시뮬레이터를 켜면 _adoptedSub 가 살아
    // 남아 실제 BLE 패킷과 합성 패킷이 같은 피로 엔진에 섞여 들어갔다.
    final ctrl = StreamController<List<int>>.broadcast();
    addTearDown(ctrl.close);
    final session = SessionController();
    addTearDown(session.dispose);

    session.adopt(dataStream: ctrl.stream, label: 'EMG-FES-01');
    await session.disconnect();
    expect(session.connState, 'disconnected');

    ctrl.add(utf8.encode(jsonEncode({
      'ts': 4000, 'env': 888.0, 'rms': 888.0, 'mdf': 888.0,
      'v': true, 'run': true, 'stim': true, 'fd': false,
    })));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(session.envLast, isNot(888.0));
  });

  test('시뮬레이터가 도는 동안 adopt() 는 거부된다', () async {
    final ctrl = StreamController<List<int>>.broadcast();
    addTearDown(ctrl.close);
    final session = SessionController();
    addTearDown(session.dispose);

    await session.startSimulator(SimScenario.clinical);
    addTearDown(session.stopSimulator);

    expect(
      () => session.adopt(dataStream: ctrl.stream, label: 'EMG-FES-01'),
      throwsStateError,
    );

    // 거부됐으니 시뮬레이터의 실제 소스는 그대로 살아 있어야 한다.
    expect(session.simOn, isTrue);
  });

  test('adopt 한 적 없는 컨트롤러에서 release() 는 아무것도 건드리지 않는다',
      () async {
    final session = SessionController();
    addTearDown(session.dispose);

    // 실 BLE 연결을 흉내: scanAndConnect() 없이도 connState 만으로 검증
    // 가능하지만, 여기서는 "adopt 한 적 없음" 자체가 핵심이므로 시뮬레이터로
    // 진짜 소스를 하나 열어 release() 가 그걸 건드리는지 확인한다.
    await session.startSimulator(SimScenario.clinical);
    addTearDown(session.stopSimulator);

    final labelBefore = session.deviceLabel;
    session.release();

    expect(session.simOn, isTrue);
    expect(session.connState, 'connected');
    expect(session.deviceLabel, labelBefore);
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

  // ── adopt() 는 관찰자다 (Approved change, 최종 리뷰) ────────────────────
  //
  // GameScreen 이 adopt() 로 받은 컨트롤러는 home_page 가 이미 올바르게
  // baseline 을 잡은 엔진과 별개로, 게임이 세션 도중 열리면 그 순간부터
  // 다시 baseline 을 잡는 자체 FatigueEngine 을 굴린다. 그 오판정이 같은
  // cmdChar 에 자극 정지를 중복으로 쓰면 안 된다 — home_page 의 엔진만
  // 자극을 멈출 권한이 있다.
  group('adopt() 는 순수 관찰자다', () {
    test('fd:true 를 받아도 cmdChar 에 stop 을 쓰지 않는다', () async {
      final ctrl = StreamController<List<int>>.broadcast();
      addTearDown(ctrl.close);
      final session = SessionController();
      addTearDown(session.dispose);
      final cmdChar = _RecordingCmdChar();

      // home_page._openGame() 과 동일하게 cmdChar 를 함께 넘긴다 — 실기기
      // 에서도 adopt() 된 컨트롤러는 cmdChar 를 쥐고 있다("Do not remove
      // cmdChar" 참고, cmdChar 자체는 그대로 유지하기로 결정됐다). 이
      // 테스트는 cmdChar 가 있어도 자동 정지 write 는 안 나가야 한다는
      // 것을 확인한다 — cmdChar 를 null 로 두면 write() 가 호출 전에
      // 이미 no-op 이라 이 게이트를 실제로 검증하지 못한다.
      session.adopt(
        dataStream: ctrl.stream,
        cmdChar: cmdChar,
        label: 'EMG-FES-01',
      );

      ctrl.add(utf8.encode(jsonEncode({
        'ts': 1000,
        'env': 100.0, 'rms': 200.0, 'mdf': 80.0,
        'v': true, 'run': true, 'stim': true, 'fd': true,
      })));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(session.st.fatigueDetected, isTrue,
          reason: '피로 관측 자체는 여전히 반영된다 — 관찰자도 값은 읽는다');
      expect(cmdChar.writeCount, 0,
          reason: 'adopt() 로 받은 컨트롤러는 순수 관찰자다. 자기 소유가 '
              '아닌 세션에서 자극을 멈추면 home_page 의 올바른 엔진과 '
              '중복으로 같은 characteristic 에 쓰게 된다.');
    });
  });

  // ── RAW 1kHz 스트림 (Task 10) ─────────────────────────────────────────
  group('adopt 의 rawStream', () {
    test('바이트가 파싱되어 rawPackets 로 나온다', () async {
      final dataCtrl = StreamController<List<int>>.broadcast();
      addTearDown(dataCtrl.close);
      final rawCtrl = StreamController<List<int>>.broadcast();
      addTearDown(rawCtrl.close);
      final session = SessionController();
      addTearDown(session.dispose);

      final got = <RawPacket>[];
      final sub = session.rawPackets.listen(got.add);
      addTearDown(sub.cancel);

      session.adopt(
        dataStream: dataCtrl.stream,
        rawStream: rawCtrl.stream,
        label: 'EMG-FES-01',
      );
      rawCtrl.add(_rawBytes(1000, [10, -20, 30]));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(got, hasLength(1));
      expect(got.single.firstSampleIndex, 1000);
      expect(got.single.samples, [10, -20, 30]);
    });

    test('rawStream 을 안 넘기면 조용히 아무 것도 안 온다 (예외 없음)', () async {
      final dataCtrl = StreamController<List<int>>.broadcast();
      addTearDown(dataCtrl.close);
      final session = SessionController();
      addTearDown(session.dispose);

      final got = <RawPacket>[];
      final sub = session.rawPackets.listen(got.add);
      addTearDown(sub.cancel);

      expect(() => session.adopt(dataStream: dataCtrl.stream), returnsNormally);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(got, isEmpty);
    });

    test('잘린/쓰레기 패킷은 조용히 버려지고 세션은 계속된다', () async {
      final dataCtrl = StreamController<List<int>>.broadcast();
      addTearDown(dataCtrl.close);
      final rawCtrl = StreamController<List<int>>.broadcast();
      addTearDown(rawCtrl.close);
      final session = SessionController();
      addTearDown(session.dispose);

      final got = <RawPacket>[];
      final sub = session.rawPackets.listen(got.add);
      addTearDown(sub.cancel);

      session.adopt(
        dataStream: dataCtrl.stream,
        rawStream: rawCtrl.stream,
        label: 'EMG-FES-01',
      );

      // 헤더도 못 채우는 쓰레기, 그리고 count 는 100인데 실제로는 모자란 패킷.
      rawCtrl.add(const [1, 2, 3]);
      rawCtrl.add(const []);
      // 유효한 패킷도 하나 섞어 보내 파이프라인 자체는 살아 있음을 확인한다.
      rawCtrl.add(_rawBytes(5, [1, 2]));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(got, hasLength(1));
      expect(got.single.firstSampleIndex, 5);
      // 손상 패킷이 섞여도 데이터 파이프라인(JSON)은 영향받지 않는다.
      dataCtrl.add(utf8.encode(jsonEncode({
        'ts': 6000, 'env': 1.0, 'rms': 1.0, 'mdf': 1.0,
        'v': true, 'run': true, 'stim': true, 'fd': false,
      })));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(session.envLast, 1.0);
    });

    test('release 하면 raw 구독도 함께 끊긴다', () async {
      final dataCtrl = StreamController<List<int>>.broadcast();
      addTearDown(dataCtrl.close);
      final rawCtrl = StreamController<List<int>>.broadcast();
      addTearDown(rawCtrl.close);
      final session = SessionController();
      addTearDown(session.dispose);

      final got = <RawPacket>[];
      final sub = session.rawPackets.listen(got.add);
      addTearDown(sub.cancel);

      session.adopt(
        dataStream: dataCtrl.stream,
        rawStream: rawCtrl.stream,
        label: 'EMG-FES-01',
      );
      session.release();

      rawCtrl.add(_rawBytes(999, [1, 2, 3]));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(got, isEmpty);
    });

    test('disconnect() 해도 raw 구독이 끊긴다', () async {
      final dataCtrl = StreamController<List<int>>.broadcast();
      addTearDown(dataCtrl.close);
      final rawCtrl = StreamController<List<int>>.broadcast();
      addTearDown(rawCtrl.close);
      final session = SessionController();
      addTearDown(session.dispose);

      final got = <RawPacket>[];
      final sub = session.rawPackets.listen(got.add);
      addTearDown(sub.cancel);

      session.adopt(
        dataStream: dataCtrl.stream,
        rawStream: rawCtrl.stream,
        label: 'EMG-FES-01',
      );
      await session.disconnect();

      rawCtrl.add(_rawBytes(999, [1, 2, 3]));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(got, isEmpty);
    });
  });
}
