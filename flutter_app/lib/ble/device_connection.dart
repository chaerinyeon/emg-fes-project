import 'dart:async';
import 'dart:convert';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../core/constants.dart';
import '../core/raw_packet.dart';

enum LinkState { disconnected, scanning, connecting, connected }

/// 기기 링크 추상화.
///
/// 안전 로직([StimController])이 하드웨어 없이 검증 가능해야 한다.
/// FES 를 끄는 경로는 실기기에서만 확인할 수 있으면 안 된다.
abstract class DeviceLink {
  LinkState get state;
  Stream<LinkState> get stateStream;

  /// RAW 캐릭터리스틱의 바이너리 notify 페이로드.
  Stream<List<int>> get rawPackets;

  Future<void> send(Map<String, dynamic> cmd);
  Future<void> connect();
  Future<void> disconnect();
}

/// 재연결 백오프.
///
/// 순수 함수라 시간 없이 테스트된다.
class ReconnectPolicy {
  const ReconnectPolicy({
    this.base = const Duration(seconds: 1),
    this.max = const Duration(seconds: 30),
  });

  final Duration base;
  final Duration max;

  /// [attempt] 는 0부터. 지수 백오프에 상한을 건다.
  Duration delayFor(int attempt) {
    if (attempt <= 0) return base;
    final ms = base.inMilliseconds * (1 << attempt.clamp(0, 20));
    return ms >= max.inMilliseconds ? max : Duration(milliseconds: ms);
  }
}

/// RAW 패킷 스트림 → 신호 엔진이 먹는 (timeMs, adc) 표본 스트림.
///
/// 펌웨어는 100ms마다 100표본을 한 묶음으로 보낸다. 패킷 헤더의
/// `firstSampleMs` 는 BLE 끊김 중에도 계속 증가하므로, 유실 구간이 있으면
/// 표본 시각에 그대로 구멍이 남는다 — 신호 엔진이 그 구멍을 봐야 한다.
/// 여기서 시각을 새로 만들어 메우면 위상 고정이 조용히 어긋난다.
/// ★ `async*` + `await for` 로 쓰지 않는다. 그렇게 쓰면 생성기가 다음 패킷을
/// 기다리며 멈춰 있는 동안 **구독 취소가 영영 완결되지 않는다** — 취소는
/// 생성기가 깨어나야 끝나는데, 깨울 패킷이 다시 오지 않기 때문이다.
/// 세션 종료는 `await 구독취소` 뒤에 기록을 저장하므로, 그 한 줄에서 막히면
/// 세션이 통째로 저장되지 않는다. [Stream.expand] 는 평범한 구독이라
/// 취소가 즉시 전파된다.
Stream<(int, int)> rawSamples(Stream<List<int>> packets) {
  return packets.expand((bytes) {
    final p = RawPacket.parse(bytes);
    if (p == null) return const <(int, int)>[]; // 잘린 패킷 하나는 버리고 세션은 계속
    return Iterable<(int, int)>.generate(
      p.samples.length,
      (i) => (p.firstSampleMs + i, p.samples[i]),
    );
  });
}

/// flutter_blue_plus 구현.
///
/// 이 클래스에는 **정책을 두지 않는다** — 스캔·연결·전송만 한다.
/// 안전 판단은 전부 [StimController] 에 있다.
class BleDeviceConnection implements DeviceLink {
  BleDeviceConnection();

  final _stateCtl = StreamController<LinkState>.broadcast();
  final _packetCtl = StreamController<List<int>>.broadcast();

  LinkState _state = LinkState.disconnected;
  BluetoothDevice? _device;
  BluetoothCharacteristic? _cmdChar;
  StreamSubscription<dynamic>? _connSub;
  StreamSubscription<dynamic>? _rawSub;

  @override
  LinkState get state => _state;

  @override
  Stream<LinkState> get stateStream => _stateCtl.stream;

  @override
  Stream<List<int>> get rawPackets => _packetCtl.stream;

  String? lastError;

  void _setState(LinkState s) {
    if (_state == s) return;
    _state = s;
    if (!_stateCtl.isClosed) _stateCtl.add(s);
  }

  @override
  Future<void> connect() async {
    if (_state == LinkState.connected) return;
    _setState(LinkState.scanning);
    try {
      final device = await _scan();
      if (device == null) {
        lastError = '기기를 찾지 못함. 보드 전원/BLE 광고 확인.';
        _setState(LinkState.disconnected);
        return;
      }

      _setState(LinkState.connecting);
      await _connSub?.cancel();
      _connSub = device.connectionState.listen((s) {
        if (s == BluetoothConnectionState.disconnected) {
          _device = null;
          _cmdChar = null;
          _setState(LinkState.disconnected);
        }
      });

      await device.connect(
        license: License.nonprofit,
        timeout: const Duration(seconds: 15),
        autoConnect: false,
      );
      try {
        await device.requestMtu(247);
      } catch (_) {}

      final chars = await _discover(device);
      final rawChar = chars[kRawCharUuid];
      final cmdChar = chars[kCmdCharUuid];
      if (rawChar == null || cmdChar == null) {
        lastError = '필요한 characteristic을 찾지 못함.';
        await device.disconnect();
        _setState(LinkState.disconnected);
        return;
      }

      await rawChar.setNotifyValue(true);
      await _rawSub?.cancel();
      _rawSub = rawChar.lastValueStream.listen((v) {
        if (!_packetCtl.isClosed) _packetCtl.add(v);
      });

      _device = device;
      _cmdChar = cmdChar;
      _setState(LinkState.connected);
    } catch (e) {
      lastError = '$e';
      _setState(LinkState.disconnected);
    }
  }

  Future<BluetoothDevice?> _scan() async {
    BluetoothDevice? found;
    StreamSubscription<dynamic>? sub;
    sub = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        final name = r.device.platformName.isNotEmpty
            ? r.device.platformName
            : r.advertisementData.advName;
        final hasService = r.advertisementData.serviceUuids
            .map((g) => g.toString().toLowerCase())
            .contains(kServiceUuid);
        if (name == kDeviceName || hasService) {
          found = r.device;
          break;
        }
      }
      if (found != null) FlutterBluePlus.stopScan();
    });
    await FlutterBluePlus.startScan(
      withServices: [Guid(kServiceUuid)],
      timeout: const Duration(seconds: 10),
    );
    await FlutterBluePlus.isScanning.where((s) => s == false).first;
    await sub.cancel();
    return found;
  }

  Future<Map<String, BluetoothCharacteristic>> _discover(
      BluetoothDevice device) async {
    final out = <String, BluetoothCharacteristic>{};
    for (final s in await device.discoverServices()) {
      if (s.uuid.toString().toLowerCase() != kServiceUuid) continue;
      for (final c in s.characteristics) {
        out[c.uuid.toString().toLowerCase()] = c;
      }
    }
    return out;
  }

  @override
  Future<void> send(Map<String, dynamic> cmd) async {
    final c = _cmdChar;
    if (c == null) throw StateError('링크 없음: $cmd');
    await c.write(utf8.encode(jsonEncode(cmd)), withoutResponse: false);
  }

  @override
  Future<void> disconnect() async {
    await _rawSub?.cancel();
    _rawSub = null;
    await _connSub?.cancel();
    _connSub = null;
    try {
      await _device?.disconnect();
    } catch (_) {}
    _device = null;
    _cmdChar = null;
    _setState(LinkState.disconnected);
  }

  Future<void> dispose() async {
    await disconnect();
    await _stateCtl.close();
    await _packetCtl.close();
  }
}
