import 'dart:async';

import 'package:flutter_app/ble/device_connection.dart';

/// 하드웨어 없이 안전 로직을 검증하기 위한 가짜 링크.
///
/// FES 를 끄는 경로가 실기기에서만 확인되면 안 된다 — 그래서 링크는
/// 추상화되어 있고, 테스트는 전부 이 하나를 쓴다.
class FakeLink implements DeviceLink {
  final _state = StreamController<LinkState>.broadcast();
  final _packets = StreamController<List<int>>.broadcast();

  LinkState _current = LinkState.connected;

  /// 앱이 실제로 보낸 명령. 자극이 정말 꺼졌는지 여기서 확인한다.
  final sent = <Map<String, dynamic>>[];

  /// true 면 send 가 예외를 던진다 (링크가 죽는 중).
  bool failSend = false;

  @override
  LinkState get state => _current;
  @override
  Stream<LinkState> get stateStream => _state.stream;
  @override
  Stream<List<int>> get rawPackets => _packets.stream;

  @override
  Future<void> send(Map<String, dynamic> cmd) async {
    if (failSend) throw StateError('link down');
    sent.add(cmd);
  }

  @override
  Future<void> connect() async => drop(LinkState.connected);
  @override
  Future<void> disconnect() async => drop(LinkState.disconnected);

  void drop(LinkState s) {
    _current = s;
    _state.add(s);
  }

  void emit(List<int> packet) => _packets.add(packet);

  Future<void> dispose() async {
    await _state.close();
    await _packets.close();
  }
}
