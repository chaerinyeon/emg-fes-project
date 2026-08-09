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
  SignalPipeline();

  final DcCalibrator _dc = DcCalibrator();
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
  BurstResult? addSample(int tMs, int adc) {
    if (_detector == null) {
      _dc.add(adc);
      _preroll.add((tMs, adc));
      if (_preroll.length >= kArtifactScaleWindowMs && _dc.isCalibrated) {
        _startAndReplay();
      }
      return _takePending();
    }
    final r = _feed(tMs, adc);
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
    final dev = <double>[];
    for (final (_, adc) in _preroll) {
      dev.add((adc - _dc.offset!).abs());
    }
    dev.sort();
    final i = ((dev.length - 1) * kArtifactScalePercentile / 100.0).round();
    _artifactScale = dev[i];

    _detector = StimDetector(
      dcOffset: _dc.offset!,
      noiseSigma: _dc.noiseSigma,
      artifactScale: _artifactScale,
    );
    _segmenter = BurstSegmenter(dcOffset: _dc.offset!);

    for (final (t, adc) in _preroll) {
      final r = _feed(t, adc);
      if (r != null) _pending.add(r);
    }
    _preroll.clear();
  }

  /// 샘플 1개를 처리한다. 큐를 건드리지 않는 순수 경로.
  BurstResult? _feed(int tMs, int adc) {
    _segmenter!.addSample(tMs, adc);
    _gate.tick(tMs / 1000.0);

    final event = _detector!.add(tMs, adc);
    if (event == null) return null;

    final closed = _segmenter!.addEvent(event);
    if (closed == null) return null;
    return _finishBurst(closed);
  }

  BurstResult? _takePending() =>
      _pending.isEmpty ? null : _pending.removeAt(0);

  BurstResult? _finishBurst(BurstEpoch burst) {
    final raw = MwaveExtractor.burstP2p(burst);
    if (raw == null) return null; // 유효 에폭이 없는 버스트는 버린다

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
      mdfHz: medianFrequencyHz(wave, fs: kSampleRateHz.toDouble()),
    );
  }
}
