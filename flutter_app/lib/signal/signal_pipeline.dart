import 'burst_segmenter.dart';
import 'constants.dart';
import 'dc_calibrator.dart';
import 'fatigue_engine.dart';
import 'hampel_filter.dart';
import 'level_tracker.dart';
import 'mwave_extractor.dart';
import 'reliability.dart';
import 'spectrum.dart';
import 'stim_detector.dart';

/// 버스트 1회분의 최종 결과.
class BurstResult {
  final int index;
  final double tSeconds;
  final double p2p; // Hampel 적용 후 버스트 대표 진폭
  final double p2pRaw; // Hampel 적용 전 원값 (진단·검증용)
  final double fatiguePct; // 적응형 기준
  final bool contractionOk;
  final int eventsInBurst;
  final bool reliable; // false 면 [fatiguePct] 를 믿지 않는다
  final int levelSegmentIndex;
  final int stimOnsetMs; // 위상 고정된 실제 자극 시점
  final double aRef; // 현재 구간의 A_ref
  final FatigueAdvice advice;

  /// **관찰용.** 피로 판정에 쓰지 않는다 — `spectrum.dart` 머리말 참고.
  final double rms;

  /// **관찰용.** 추정이 서지 않으면 null.
  final double? mdfHz;

  const BurstResult({
    required this.index,
    required this.tSeconds,
    required this.p2p,
    required this.p2pRaw,
    required this.fatiguePct,
    required this.contractionOk,
    required this.eventsInBurst,
    required this.reliable,
    required this.levelSegmentIndex,
    required this.stimOnsetMs,
    required this.aRef,
    required this.advice,
    this.rms = 0,
    this.mdfHz,
  });

  @override
  String toString() => 'Burst($index t=${tSeconds.toStringAsFixed(1)}s '
      'p2p=${p2p.toStringAsFixed(0)} fat=${fatiguePct.toStringAsFixed(1)}% '
      'seg=$levelSegmentIndex ev=$eventsInBurst '
      '${contractionOk ? 'OK' : 'MISS'}${reliable ? '' : ' UNRELIABLE'})';
}

/// [A]~[J] 전체를 잇는 파사드. 입력 1kHz ADC, 출력 버스트 단위 [BurstResult].
///
/// 오프라인 CSV 와 BLE 스트림이 **같은 경로**를 타야 회귀가 의미를 갖는다.
/// 처리 순서는 공통 컨텍스트 2.3 그대로다.
/// ```
/// raw → [A] DC → [B] 자극검출·위상 → [C][D] 버스트·에폭영점
///     → [E][F] p2p·중앙값 → [G] Hampel → [H] 레벨·A_ref
///     → [I] 피로% → [J] 수축판정
/// ```
class SignalPipeline {
  /// [fs] 는 입력 샘플레이트(Hz).
  ///
  /// 오프라인 CSV(64세션)는 1000, 실기기 펌웨어는 4000 이다. 두 경로가 **같은
  /// 코드**를 타야 회귀 테스트가 의미를 갖는다 — 그래서 레이트를 상수로 박지
  /// 않고 여기서 주입한다.
  SignalPipeline({int fs = kSampleRateHz})
      : clock = SampleClock(fs),
        _prerollTarget = SampleClock(fs).samples(kArtifactScaleWindowMs);

  /// ms 상수 ↔ 샘플 수 환산.
  final SampleClock clock;

  /// 입력 샘플레이트(Hz).
  int get fs => clock.fs;

  /// 아티팩트 규모를 재기 위해 모으는 도입부 **샘플 수**.
  ///
  /// 예전에는 `_preroll.length >= kArtifactScaleWindowMs` 로 5000 **개**를
  /// 셌다. 1kHz 에서는 그게 곧 5초였지만 4kHz 에서는 1.25초라, 아티팩트
  /// 백분위수를 4분의 1 구간에서 재게 된다.
  final int _prerollTarget;

  late final DcCalibrator _dc = DcCalibrator(clock: clock);
  final OnlineHampel _hampel = OnlineHampel();
  final LevelTracker _level = LevelTracker();
  final FatigueEngine _fatigue = FatigueEngine();
  final ReliabilityGate _gate = ReliabilityGate();

  StimDetector? _detector;
  BurstSegmenter? _segmenter;

  /// 임계 확정 전 도입부 샘플 버퍼. 확정 후 그대로 replay 한다.
  final List<(int, int)> _preroll = <(int, int)>[];

  /// replay 중 한꺼번에 닫힌 버스트를 순서대로 내보내기 위한 큐.
  final List<BurstResult> _pending = <BurstResult>[];

  double? _artifactScale;

  /// 도입부에서 추정한 아티팩트 진폭 규모.
  double? get artifactScale => _artifactScale;

  // ── 진단 ────────────────────────────────────────────────
  //
  // 검출이 어디서 끊겼는지 **화면이 갈라 말할 수 있어야** 한다. 예전에는
  // [reliability] 의 detectRate·eventsPerBurst 만 노출했는데, 그 둘은
  // [_finishBurst] 를 통과한 버스트만 센다. 그래서 "펄스를 아예 못 잡았다"와
  // "잡았는데 에폭이 안 잘려 버렸다"가 화면에서 똑같이 0 으로 보였다.

  /// 검출기가 확정한 자극 펄스 총수.
  int get detectedPulses => _detector?.pulseCount ?? 0;

  /// 검출기가 센 버스트 수. [reliability] 쪽과 달리 **폐기 전** 값이다.
  int get detectedBursts => _detector?.burstCount ?? 0;

  int _discardedBursts = 0;

  /// 유효 에폭이 하나도 없어 버려진 버스트 수.
  ///
  /// 이 값이 [detectedBursts] 를 따라 올라가면 문제는 검출이 아니라 에폭
  /// 절단이다 — 링버퍼([kSampleRingMs])를 벗어났거나 표본이 끊긴 것이다.
  int get discardedBursts => _discardedBursts;

  int _retunes = 0;

  /// 임계를 다시 잡은 횟수. 0 이 아니면 첫 추정이 틀렸다는 뜻이다.
  int get retuneCount => _retunes;

  /// 최근 |신호 − DC| 링버퍼. 재추정은 **지금 신호**로 해야 의미가 있다.
  late final List<double> _recentDev = List<double>.filled(_prerollTarget, 0);
  int _recentWrite = 0;
  int _recentFilled = 0;

  /// 검출기를 만든(또는 마지막으로 다시 잡은) 표본 인덱스.
  int? _detectorSinceIdx;

  /// 마지막으로 펄스가 확정된 표본 인덱스. 재조정 시한의 기준이다.
  int? _lastPulseIdx;

  /// 마지막으로 처리한 표본 인덱스.
  int? _lastSampleIdx;

  /// **지금 자극이 나가고 있는가.**
  ///
  /// 앱은 자극기를 켜지도 끄지도 못하고(마사지기 미배선), `isStimulating` 은
  /// 자기가 보낸 명령을 센 값이라 실제와 무관하다. 실제로 자극이 몸에 닿고
  /// 있는지 아는 길은 **신호에서 자극 아티팩트가 보이는가** 하나뿐이다.
  ///
  /// 자극 주기가 1.6초이므로 그 두 배 동안 펄스가 없으면 꺼진 것으로 본다.
  /// 한 주기만 보면 버스트 사이 쉼 구간을 "꺼짐"으로 오해한다.
  bool get stimSeenRecently {
    final last = _lastPulseIdx;
    final now = _lastSampleIdx;
    if (last == null || now == null) return false;
    return now - last < clock.samples(kStimPeriodMs * 2);
  }

  /// 자극 검출 임계 (확정 전 null).
  double? get stimThreshold => _detector?.threshold;

  /// 추정된 자극 주기.
  double? get periodMs => _detector?.periodMs;

  /// 다음 자극 예측 시점. 게임 큐는 여기서 [kCueLeadMs] 앞서 나간다.
  int? get predictedNextBurstOnsetMs => _detector?.predictedNextBurstOnsetMs;

  /// 위상 드리프트 진단 로그.
  List<PhaseDriftLog> get driftLog => _detector?.driftLog ?? const [];

  int get driftExceededCount => _detector?.driftExceededCount ?? 0;

  double? get dcOffset => _dc.offset;
  double get noiseSigma => _dc.noiseSigma;
  bool get dcWindowLooksQuiet => _dc.looksQuiet;

  ReliabilityGate get reliability => _gate;
  int get levelSegmentCount => _level.segmentCount;

  /// 샘플 1개를 넣는다. 버스트가 닫히면 결과를 반환한다.
  ///
  /// 도입부 [kArtifactScaleWindowMs] 는 아티팩트 규모를 재느라 결과가 없다.
  /// 그 구간 샘플은 임계 확정 뒤 그대로 replay 되어 버스트를 잃지 않는다.
  BurstResult? addSample(int sampleIdx, int adc) {
    if (_detector == null) {
      _dc.add(adc);
      _preroll.add((sampleIdx, adc));
      if (_preroll.length >= _prerollTarget && _dc.isCalibrated) {
        _startAndReplay();
      }
      return _takePending();
    }
    final r = _feed(sampleIdx, adc);
    if (r != null) _pending.add(r);
    return _takePending();
  }

  /// 스트림 끝에서 남은 버스트를 모두 내보낸다.
  List<BurstResult> flush() {
    final out = <BurstResult>[];

    // 도입부 창을 다 채우지 못하고 끝난 짧은 세션도 처리한다.
    if (_detector == null) {
      if (!_dc.isCalibrated || _preroll.isEmpty) return const [];
      _startAndReplay();
    }
    while (_pending.isNotEmpty) {
      out.add(_pending.removeAt(0));
    }

    final tail = _detector!.flush();
    if (tail != null) {
      final closed = _segmenter!.addEvent(tail);
      if (closed != null) {
        final r = _finishBurst(closed);
        if (r != null) out.add(r);
      }
    }
    final last = _segmenter!.flush();
    if (last != null) {
      final r = _finishBurst(last);
      if (r != null) out.add(r);
    }
    return out;
  }

  /// 스트림 → 스트림.
  Stream<BurstResult> process(Stream<(int, int)> samples) async* {
    await for (final (t, adc) in samples) {
      final r = addSample(t, adc);
      if (r != null) yield r;
    }
    for (final r in flush()) {
      yield r;
    }
  }

  /// 도입부 버퍼로 아티팩트 규모를 재고, 검출기를 만든 뒤 버퍼를 replay 한다.
  ///
  /// 결과는 전부 [_pending] 에 **순서대로** 쌓는다. 큐의 주인은 여기와
  /// [addSample] 뿐이다 — [_feed] 가 큐를 건드리면 replay 중 순서가 뒤집힌다.
  void _startAndReplay() {
    // 레일 표본은 규모 추정에서 **뺀다.** |0 − DC| 는 어떤 실제 아티팩트보다
    // 커서, 0 이 0.5%만 섞여도 상위 백분위수를 통째로 차지한다.
    final dev = <double>[];
    for (final (_, adc) in _preroll) {
      if (isAdcRail(adc)) continue;
      dev.add((adc - _dc.offset!).abs());
    }
    _artifactScale = _percentileOrNull(dev);

    _detector = StimDetector(
      dcOffset: _dc.offset!,
      noiseSigma: _dc.noiseSigma,
      artifactScale: _artifactScale,
      clock: clock,
    );
    _segmenter = BurstSegmenter(dcOffset: _dc.offset!, clock: clock);

    for (final (t, adc) in _preroll) {
      final r = _feed(t, adc);
      if (r != null) _pending.add(r);
    }
    _preroll.clear();
  }

  /// 샘플 1개를 처리한다. 큐를 건드리지 않는 순수 경로.
  BurstResult? _feed(int sampleIdx, int adc) {
    _lastSampleIdx = sampleIdx;
    _segmenter!.addSample(sampleIdx, adc);
    _gate.tick(clock.seconds(sampleIdx));

    final rail = isAdcRail(adc);

    // 재추정에 쓸 최근 창. 첫 추정과 **같은 길이·같은 규칙**이어야 한다.
    // 레일은 아예 안 적는다 — 적어 두면 재추정이 첫 추정과 같은 실수를 한다.
    if (!rail) {
      _recentDev[_recentWrite] = (adc - _dc.offset!).abs();
      _recentWrite = (_recentWrite + 1) % _recentDev.length;
      if (_recentFilled < _recentDev.length) _recentFilled++;
    }

    _maybeRetune(sampleIdx);

    // 검출기에는 레일 대신 **영점**을 흘린다.
    //
    // 버리지 않고 바꿔 넣는 이유: 그냥 건너뛰면 열려 있던 펄스 그룹이 닫힐
    // 기회를 잃는다(그룹은 임계 아래 표본을 봐야 닫힌다). 영점을 넣으면
    // 가짜 펄스를 만들지 않으면서 그룹도 정상적으로 닫힌다.
    //
    // 세그멘터에는 원값 그대로 간다 — 기록은 실제로 온 것을 남겨야 하고,
    // 튀는 값 하나는 뒤의 Hampel 이 걸러 준다.
    final event = _detector!.add(sampleIdx, rail ? _dc.offset!.round() : adc);
    if (event == null) return null;
    _lastPulseIdx = sampleIdx;

    final closed = _segmenter!.addEvent(event);
    if (closed == null) return null;
    return _finishBurst(closed);
  }

  BurstResult? _takePending() =>
      _pending.isEmpty ? null : _pending.removeAt(0);

  /// [kArtifactScalePercentile] 백분위수. 볼 것이 없거나 창이 통째로
  /// 평평했으면 null — 0 으로 임계를 세우면 의미도 없고 assert 에도 걸린다.
  double? _percentileOrNull(List<double> dev) {
    if (dev.isEmpty) return null;
    dev.sort();
    final i = ((dev.length - 1) * kArtifactScalePercentile / 100.0).round();
    final v = dev[i];
    return v > 0 ? v : null;
  }

  /// **마지막 펄스 이후** [kStimRetuneAfterMs] 가 지나면 임계를 다시 잡는다.
  ///
  /// 처음에는 "펄스 총수가 0이면"으로 짰는데 그건 틀렸다. 임계를 망가뜨리는
  /// 바로 그 사건(몸을 뒤척인 큰 아티팩트)은 **자기 자신은 임계를 넘는다.**
  /// 그래서 총수가 1이 되고, 그 뒤로 진짜 자극을 영영 못 찾는데도 안전망이
  /// 꺼진 채로 남는다.
  ///
  /// 마지막 펄스 기준이면 그런 구멍이 없다. 정상 세션에서는 버스트가 1.6초
  /// 간격이라 펄스 공백이 8초에 닿지 않으므로, 잘 되는 중에 임계가 흔들릴
  /// 일도 없다 — 흔들면 그때부터 세기가 달라 보이고 피로로 잘못 읽힌다.
  void _maybeRetune(int sampleIdx) {
    _detectorSinceIdx ??= sampleIdx;
    final since = _lastPulseIdx ?? _detectorSinceIdx!;
    if (sampleIdx - since < clock.samples(kStimRetuneAfterMs)) return;
    retuneStimDetection(atSample: sampleIdx);
  }

  /// 자극 검출 임계를 **지금 신호로** 다시 잡는다.
  ///
  /// 첫 추정은 측정 시작 직후 한 창에서 나온다. 그 창에 몸을 뒤척인 흔적이
  /// 하나만 들어가도 임계가 그 크기에 맞춰져, 진짜 자극이 그 아래로 깔려
  /// 세션 내내 안 잡힌다. 그때 사람이 할 수 있는 일이 「기다리기」밖에 없으면
  /// 안 된다.
  ///
  /// 검출기는 **새로 만든다.** 임계만 바꾸면 이미 열린 그룹·위상 원점이
  /// 옛 임계 기준으로 남아, 첫 몇 버스트의 위상이 조용히 어긋난다.
  /// 세그멘터도 같이 비운다 — 열려 있던 버스트는 옛 기준의 펄스 목록이다.
  ///
  /// 캘리브 전이거나 볼 표본이 없으면 아무것도 하지 않고 false.
  bool retuneStimDetection({int? atSample}) {
    if (!_dc.isCalibrated || _recentFilled == 0) return false;

    // 첫 추정과 **같은 규칙**으로 잰다 — 레일은 뺀다.
    _artifactScale = _percentileOrNull(
      [for (var i = 0; i < _recentFilled; i++) _recentDev[i]],
    );

    _detector = StimDetector(
      dcOffset: _dc.offset!,
      noiseSigma: _dc.noiseSigma,
      artifactScale: _artifactScale,
      clock: clock,
    );
    _segmenter = BurstSegmenter(dcOffset: _dc.offset!, clock: clock);
    _detectorSinceIdx = atSample;
    _lastPulseIdx = null; // 새 임계 기준으로 시한을 다시 센다
    _retunes++;
    return true;
  }

  BurstResult? _finishBurst(BurstEpoch burst) {
    final raw = MwaveExtractor.burstP2p(burst);
    if (raw == null) {
      // 유효 에폭이 없는 버스트는 버린다. **세고 나서** 버린다 — 조용히
      // 사라지면 화면에서 "검출을 못 했다"와 구분되지 않는다.
      _discardedBursts++;
      return null;
    }

    // [G] 인과 Hampel — 전극 접촉 글리치 제거.
    final filtered = _hampel.add(raw);

    // [H] 레벨 구간 + A_ref running-peak.
    _level.add(filtered);

    final tSeconds = burst.tSeconds;

    // [I][J]
    final sample = _fatigue.add(
      p2p: filtered,
      aRef: _level.aRef,
      tSeconds: tSeconds,
    );

    _gate.addBurst(
      eventsInBurst: burst.pulses.length,
      tSeconds: tSeconds,
    );

    // [관찰] RMS·MDF. 에폭은 이미 영점보정이 끝났으므로 이어 붙이면 그대로
    // 버스트 ON 구간의 신호가 된다. 피로 판정에는 들어가지 않는다.
    final wave = <double>[];
    for (final p in burst.pulses) {
      wave.addAll(p.samples);
    }

    return BurstResult(
      index: burst.index,
      tSeconds: tSeconds,
      p2p: filtered,
      p2pRaw: raw,
      fatiguePct: sample.fatiguePct,
      contractionOk: sample.contractionOk,
      eventsInBurst: burst.pulses.length,
      reliable: _gate.fatigueTrusted,
      levelSegmentIndex: _level.segmentIndex,
      stimOnsetMs: burst.onsetMs,
      aRef: _level.aRef,
      advice: sample.advice,
      rms: rmsOf(wave),
      mdfHz: medianFrequencyHz(wave, fs: clock.fs.toDouble()),
    );
  }
}
