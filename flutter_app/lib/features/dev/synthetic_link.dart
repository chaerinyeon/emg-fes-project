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
    int fs = kDeviceSampleRateHz,
    int seed = 20260806,
  })  : clock = SampleClock(fs),
        _rng = math.Random(seed);

  /// 합성 신호의 샘플레이트. **소비자(파이프라인)와 같아야 한다** — 다르면
  /// 실기기에서 났던 것과 똑같이 시간축이 배수로 어긋난다.
  final SampleClock clock;

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
  int _sampleIdx = 0;
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
    // 패킷 하나가 100표본이므로 실시간 간격은 fs 에 반비례한다.
    // 4kHz 면 25ms — 고정 100ms 로 두면 신호가 4배 느리게 흐른다.
    _timer ??= Timer.periodic(
      Duration(milliseconds: (100 * 1000 / clock.fs).round().clamp(1, 1000)),
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

  /// [ms] 밀리초 분량을 한 번에 낸다.
  ///
  /// 패킷 하나는 100 **표본**이라 실시간 길이가 fs 에 따라 달라진다 — 1kHz 면
  /// 100ms, 4kHz 면 25ms. 호출부가 `for (t=0; t<ms; t+=100) emitNextPacket()`
  /// 처럼 세면 1kHz 에서만 맞고, 4kHz 에서는 시간이 4분의 1만 흐른다. 환산을
  /// 링크가 직접 해서 그 실수를 구조적으로 막는다.
  void emitFor(int ms) {
    final n = (clock.samples(ms) / 100).ceil();
    for (var i = 0; i < n; i++) {
      emitNextPacket();
    }
  }

  /// 100표본 패킷 하나를 낸다. 실시간으로는 100표본이 `100/fs` 초에 해당한다.
  ///
  /// 공개되어 있는 것은 테스트가 **시간을 손으로 밀기** 위해서다. 실시간을
  /// 기다리면 20초짜리 세션 검증에 20초가 든다.
  ///
  /// 파형의 모든 눈금은 밀리초로 정의하고 [clock] 으로 표본 수를 얻는다 —
  /// 1kHz 시절처럼 인덱스를 곧 밀리초로 쓰면 4kHz 에서 자극이 4배 빨라진다.
  void emitNextPacket() {
    final first = _sampleIdx;
    final samples = List<int>.filled(100, dc);

    final calib = clock.samples(2000); // 도입부 무자극 구간
    final period = clock.samples(kStimPeriodMs);
    final on = clock.samples(kStimOnMs);
    final isi = clock.samples(31); // in-burst ISI
    final peakPos = clock.samples(8); // M-wave 양의 정점
    final peakNeg = clock.samples(12); // 음의 정점
    final artifactWidth = clock.samples(1); // 자극 스파이크 폭

    for (var i = 0; i < 100; i++) {
      final t = first + i;

      // 기저 잡음. 실제 전극에서 오는 신호는 평평하지 않고, 부착 체크가
      // 이 잡음의 크기로 "전극이 붙었는가"를 판단한다.
      samples[i] = dc + _rng.nextInt(2 * baselineNoise + 1) - baselineNoise;

      if (t < calib) continue;

      final since = t - calib;
      final burst = since ~/ period;
      final inBurst = since % period;
      if (inBurst >= on) continue;

      final d = inBurst % isi; // 펄스 내 오프셋(표본)
      final amp = _amplitudeAt(burst);

      if (d < artifactWidth) {
        samples[i] = dc + 900; // 자극 아티팩트
      } else if (d == peakPos) {
        samples[i] = dc + (amp / 2).round(); // M-wave 양의 정점
      } else if (d == peakNeg) {
        samples[i] = dc - (amp / 2).round(); // 음의 정점
      }
    }

    _packets.add(_encode(first, samples));
    _sampleIdx += 100;
  }

  /// 버스트가 갈수록 진폭이 준다 = 피로. 자극이 꺼져 있으면 반응도 없다.
  double _amplitudeAt(int burst) {
    if (!_stimOn) return 40; // 자극 OFF — 잔잔한 잡음 수준
    final k = (burst / declineOverBursts).clamp(0.0, 1.0);
    return 620 - 500 * k;
  }

  static List<int> _encode(int firstSampleIndex, List<int> samples) {
    final b = ByteData(6 + 2 * samples.length);
    b.setUint32(0, firstSampleIndex, Endian.little);
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
