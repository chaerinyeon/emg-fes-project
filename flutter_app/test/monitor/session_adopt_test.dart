import 'dart:async';
import 'dart:convert';

import 'package:flutter_app/services/session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
