import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_app/services/profile_service.dart';
import 'package:flutter_app/services/session_controller.dart';
import 'package:flutter_app/services/simulator_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

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
}
