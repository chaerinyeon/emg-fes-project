import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import '../../ble/device_connection.dart';
import '../../signal/constants.dart';

/// 기기 없이 화면을 확인하기 위한 합성 링크.
///
/// 펌웨어와 **같은 바이너리 포맷**으로 100ms마다 100표본을 흘린다.
/// 실기기와 완전히 같은 경로(rawSamples → SignalPipeline → 게임 루프)를
/// 타므로, 여기서 잘 도는 것은 실기기에서도 같은 방식으로 돈다.
///
/// 시연용이라 진폭을 실제보다 빠르게 떨어뜨린다 — 1분 안에 수축 성공과
/// 실패가 둘 다 보이게 하려는 것이다.
class SyntheticFesLink implements DeviceLink {
  SyntheticFesLink({
    this.dc = 1862,
    this.declineOverBursts = 50,
    this.autoTick = true,
    this.baselineNoise = 9,
    int seed = 20260806,
  }) : _rng = math.Random(seed);

  final int dc;
  final int declineOverBursts;

  /// 실시간으로 스스로 표본을 낼 것인가. 테스트는 손으로 민다.
  final bool autoTick;

  /// 무자극 구간의 기저 잡음 폭(ADC LSB).
  ///
  /// **0이면 안 된다.** 팔에 붙은 전극에서 완전히 평평한 신호는 나오지 않고,
  /// 부착 체크가 `noiseSigma > 0` 으로 "전극이 실제로 붙었는가"를 판단한다.
  /// 잡음이 없으면 그 판정이 영원히 서지 않아 게임까지 갈 수 없다.
  /// 실측 조용한 세션의 σ(8~12)에 맞춘 값이다.
  final int baselineNoise;

  final math.Random _rng;

  final _state = StreamController<LinkState>.broadcast();
  final _packets = StreamController<List<int>>.broadcast();

  LinkState _current = LinkState.disconnected;
  Timer? _timer;
  int _tMs = 0;
  bool _stimOn = false;

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
    if (!autoTick) return;
    _timer ??= Timer.periodic(
      const Duration(milliseconds: 100),
      (_) => emitNextPacket(),
    );
  }

  @override
  Future<void> disconnect() async {
    _timer?.cancel();
    _timer = null;
    _current = LinkState.disconnected;
    _state.add(_current);
  }

  @override
  Future<void> send(Map<String, dynamic> cmd) async {
    if (cmd['cmd'] == 'trigger_stim') _stimOn = cmd['on'] == true;
    if (cmd['cmd'] == 'emergency') _stimOn = false;
  }

  /// 100ms 어치(100표본) 패킷 하나를 낸다.
  ///
  /// 공개되어 있는 것은 테스트가 **시간을 손으로 밀기** 위해서다. 실시간을
  /// 기다리면 20초짜리 세션 검증에 20초가 든다.
  void emitNextPacket() {
    final first = _tMs;
    final samples = List<int>.filled(100, dc);

    for (var i = 0; i < 100; i++) {
      final t = first + i;

      // 기저 잡음. 실제 전극에서 오는 신호는 평평하지 않고, 부착 체크가
      // 이 잡음의 크기로 "전극이 붙었는가"를 판단한다.
      samples[i] = dc + _rng.nextInt(2 * baselineNoise + 1) - baselineNoise;

      // 도입부 2초는 무자극 — DC 캘리브 구간.
      if (t < 2000) continue;

      final since = t - 2000;
      final burst = since ~/ kStimPeriodMs;
      final inBurst = since % kStimPeriodMs;
      if (inBurst >= kStimOnMs) continue;

      final d = inBurst % 31; // 펄스 내 오프셋
      final amp = _amplitudeAt(burst);

      if (d == 0) {
        samples[i] = dc + 900; // 자극 아티팩트
      } else if (d == 8) {
        samples[i] = dc + (amp / 2).round(); // M-wave 양의 정점
      } else if (d == 12) {
        samples[i] = dc - (amp / 2).round(); // 음의 정점
      }
    }

    _packets.add(_encode(first, samples));
    _tMs += 100;
  }

  /// 버스트가 갈수록 진폭이 준다 = 피로. 자극이 꺼져 있으면 반응도 없다.
  double _amplitudeAt(int burst) {
    if (!_stimOn) return 40; // 자극 OFF — 잔잔한 잡음 수준
    final k = (burst / declineOverBursts).clamp(0.0, 1.0);
    return 620 - 500 * k;
  }

  static List<int> _encode(int firstMs, List<int> samples) {
    final b = ByteData(6 + 2 * samples.length);
    b.setUint32(0, firstMs, Endian.little);
    b.setUint16(4, samples.length, Endian.little);
    for (var i = 0; i < samples.length; i++) {
      b.setInt16(6 + 2 * i, samples[i], Endian.little);
    }
    return b.buffer.asUint8List();
  }

  Future<void> dispose() async {
    _timer?.cancel();
    await _state.close();
    await _packets.close();
  }
}
