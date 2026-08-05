// 오프라인 raw CSV 회귀 하네스.
//
// emgfes-data/subject_*/raw_*.csv 를 SignalPipeline 에 그대로 흘려보내고,
// 공통 컨텍스트 8장의 기대치와 대조한다.
//
// 사용:
//   dart run tool/signal_regression.dart
//   dart run tool/signal_regression.dart --root /path/to/emgfes-data
//   dart run tool/signal_regression.dart --limit 5 --json out.json
//
// 데이터셋은 저장소 밖에 있다(약 559MB). EMGFES_DATA_DIR 로도 지정할 수 있다.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_app/signal/constants.dart';
import 'package:flutter_app/signal/signal_pipeline.dart';

class SessionReport {
  final String path;
  final bool ok;
  final String? skipReason;
  final double durationS;
  final int burstCount;
  final double eventsPerBurst;
  final double detectRate;
  final double? periodMs;
  final int levelSegments;
  final bool reliable;
  final String grade;
  final double maxFatigue;
  final double endFatigue;
  final double? onsetS;
  final int driftExceeded;
  final double dcOffset;
  final double noiseSigma;

  SessionReport({
    required this.path,
    required this.ok,
    this.skipReason,
    this.durationS = 0,
    this.burstCount = 0,
    this.eventsPerBurst = 0,
    this.detectRate = 0,
    this.periodMs,
    this.levelSegments = 0,
    this.reliable = false,
    this.grade = 'C',
    this.maxFatigue = 0,
    this.endFatigue = 0,
    this.onsetS,
    this.driftExceeded = 0,
    this.dcOffset = 0,
    this.noiseSigma = 0,
  });

  Map<String, dynamic> toJson() => {
        'path': path,
        'ok': ok,
        'skip_reason': skipReason,
        'duration_s': durationS,
        'burst_count': burstCount,
        'events_per_burst': eventsPerBurst,
        'detect_rate': detectRate,
        'period_ms': periodMs,
        'level_segments': levelSegments,
        'reliable': reliable,
        'grade': grade,
        'max_fatigue': maxFatigue,
        'end_fatigue': endFatigue,
        'onset_s': onsetS,
        'drift_exceeded': driftExceeded,
        'dc_offset': dcOffset,
        'noise_rms': noiseSigma,
      };
}

SessionReport processFile(File f, String root) {
  final rel = f.path.replaceFirst('$root/', '');
  final pipeline = SignalPipeline();
  final results = <BurstResult>[];

  var lastT = 0;
  var lineNo = 0;
  try {
    final lines = f.readAsLinesSync();
    for (final line in lines) {
      lineNo++;
      if (lineNo == 1) continue; // header
      if (line.isEmpty) continue;
      final comma = line.indexOf(',');
      if (comma <= 0) continue;
      final t = int.tryParse(line.substring(0, comma));
      final adc = int.tryParse(line.substring(comma + 1).trim());
      if (t == null || adc == null) continue;
      lastT = t;
      final r = pipeline.addSample(t, adc);
      if (r != null) results.add(r);
    }
    results.addAll(pipeline.flush());
  } catch (e) {
    return SessionReport(path: rel, ok: false, skipReason: 'read error: $e');
  }

  final durationS = lastT / 1000.0;
  if (results.length < 8) {
    return SessionReport(
      path: rel,
      ok: false,
      skipReason: 'too few bursts (${results.length})',
      durationS: durationS,
      burstCount: results.length,
    );
  }

  final gate = pipeline.reliability;
  final maxFat =
      results.map((r) => r.fatiguePct).reduce((a, b) => a > b ? a : b);

  // 마지막 1/4 구간 평균 = end fatigue (오프라인 파이프라인과 동일 정의)
  final q = (results.length / 4).ceil().clamp(1, results.length);
  final tail = results.sublist(results.length - q);
  final endFat =
      tail.map((r) => r.fatiguePct).reduce((a, b) => a + b) / tail.length;

  // 적응형 임계 도달 시점: 연속 kFatigueConsecutiveBursts 유지
  double? onset;
  if (kFatigueThresholdPct != null) {
    var run = 0;
    for (final r in results) {
      if (r.fatiguePct >= kFatigueThresholdPct!) {
        run++;
        if (run >= kFatigueConsecutiveBursts) {
          onset = r.tSeconds;
          break;
        }
      } else {
        run = 0;
      }
    }
  }

  return SessionReport(
    path: rel,
    ok: true,
    durationS: durationS,
    burstCount: results.length,
    eventsPerBurst: gate.eventsPerBurst,
    detectRate: gate.detectRate,
    periodMs: pipeline.periodMs,
    levelSegments: pipeline.levelSegmentCount,
    reliable: gate.fatigueTrusted,
    grade: gate.grade,
    maxFatigue: maxFat,
    endFatigue: endFat,
    onsetS: onset,
    driftExceeded: pipeline.driftExceededCount,
    dcOffset: pipeline.dcOffset ?? 0,
    noiseSigma: pipeline.noiseSigma,
  );
}

double _median(List<double> xs) {
  if (xs.isEmpty) return double.nan;
  final s = List<double>.of(xs)..sort();
  final n = s.length;
  return n.isOdd ? s[n ~/ 2] : (s[n ~/ 2 - 1] + s[n ~/ 2]) / 2.0;
}

double _pct(List<double> xs, double p) {
  if (xs.isEmpty) return double.nan;
  final s = List<double>.of(xs)..sort();
  final i = ((s.length - 1) * p).round();
  return s[i];
}

String _fmt(double v, [int d = 1]) =>
    v.isNaN ? 'n/a' : v.toStringAsFixed(d);

void main(List<String> args) {
  var root = Platform.environment['EMGFES_DATA_DIR'] ??
      '${Platform.environment['HOME']}/emgfes-data';
  var limit = -1;
  String? jsonOut;

  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--root':
        root = args[++i];
      case '--limit':
        limit = int.parse(args[++i]);
      case '--json':
        jsonOut = args[++i];
    }
  }

  final dir = Directory(root);
  if (!dir.existsSync()) {
    stderr.writeln('데이터셋 없음: $root');
    stderr.writeln('EMGFES_DATA_DIR 또는 --root 로 지정하세요.');
    exit(2);
  }

  final files = dir
      .listSync()
      .whereType<Directory>()
      .where((d) => d.path.split('/').last.startsWith('subject_'))
      .expand((d) => d.listSync().whereType<File>())
      .where((f) {
        final n = f.path.split('/').last;
        return n.startsWith('raw_') && n.endsWith('.csv');
      })
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  final selected = limit > 0 ? files.take(limit).toList() : files;
  stderr.writeln('raw CSV ${files.length}개 중 ${selected.length}개 처리');

  final reports = <SessionReport>[];
  final sw = Stopwatch()..start();
  for (var i = 0; i < selected.length; i++) {
    final r = processFile(selected[i], root);
    reports.add(r);
    stderr.writeln('[${i + 1}/${selected.length}] ${r.path} '
        '${r.ok ? "bursts=${r.burstCount} "
            "period=${_fmt(r.periodMs ?? double.nan)} "
            "epb=${_fmt(r.eventsPerBurst)} "
            "seg=${r.levelSegments} "
            "rel=${r.reliable} max=${_fmt(r.maxFatigue)}%" : "SKIP ${r.skipReason}"}');
  }
  sw.stop();

  final ok = reports.where((r) => r.ok).toList();
  final bad = reports.where((r) => !r.ok).toList();
  final reliable = ok.where((r) => r.reliable).toList();

  final periods = ok
      .where((r) => r.periodMs != null)
      .map((r) => r.periodMs!)
      .toList();
  final bursts = ok.map((r) => r.burstCount.toDouble()).toList();
  final durations = ok.map((r) => r.durationS).toList();
  final segs = ok.map((r) => r.levelSegments.toDouble()).toList();
  final epbs = ok.map((r) => r.eventsPerBurst).toList();

  final b = StringBuffer();
  b.writeln('\n${'=' * 68}');
  b.writeln('RE-FIT 신호엔진 오프라인 회귀 — 공통 컨텍스트 8장 대조');
  b.writeln('=' * 68);
  b.writeln('처리 시간            : ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s');
  b.writeln('');
  b.writeln('${'항목'.padRight(24)}${'실측'.padRight(22)}기대');
  b.writeln('-' * 68);
  b.writeln('${'파일'.padRight(24)}${'${reports.length}'.padRight(22)}90');
  b.writeln('${'처리 성공 세션'.padRight(22)}${'${ok.length}'.padRight(22)}88');
  b.writeln('${'자극 주기 중앙값'.padRight(21)}'
      '${'${_fmt(_median(periods))} ms'.padRight(22)}1618 ms 근방');
  b.writeln('${'주기 p25~p75'.padRight(23)}'
      '${'${_fmt(_pct(periods, .25))}~${_fmt(_pct(periods, .75))} ms'.padRight(22)}—');
  b.writeln('${'버스트 수 중앙값'.padRight(21)}'
      '${_fmt(_median(bursts), 0).padRight(22)}337');
  b.writeln('${'세션 길이 중앙값'.padRight(21)}'
      '${'${_fmt(_median(durations) / 60, 2)} min'.padRight(22)}9.3 min');
  b.writeln('${'신뢰도 통과 세션'.padRight(21)}'
      '${'${reliable.length}'.padRight(22)}58');
  b.writeln('${'events/burst 중앙값'.padRight(20)}'
      '${_fmt(_median(epbs), 2).padRight(22)}—');
  b.writeln('${'레벨 구간 평균'.padRight(22)}'
      '${_fmt(segs.isEmpty ? double.nan : segs.reduce((x, y) => x + y) / segs.length, 2).padRight(22)}4.1');
  b.writeln('-' * 68);

  b.writeln('\n등급 분포: '
      'A=${ok.where((r) => r.grade == "A").length} '
      'B=${ok.where((r) => r.grade == "B").length} '
      'C=${ok.where((r) => r.grade == "C").length}');

  final driftBad = ok.where((r) => r.driftExceeded > 0).length;
  b.writeln('위상 드리프트 초과가 있는 세션: $driftBad / ${ok.length}');

  if (kFatigueThresholdPct == null) {
    b.writeln('\n적응형 임계 검출: 측정 불가 '
        '(FATIGUE_THRESHOLD_PCT 가 null — P0 확정 전)');
    // 참고용으로 여러 임계에서의 검출 수를 낸다.
    b.writeln('참고 — 임계별 (연속 $kFatigueConsecutiveBursts버스트) 검출 세션 수 / '
        '신뢰 ${reliable.length}세션:');
    for (final thr in [10.0, 15.0, 20.0, 25.0, 30.0, 40.0]) {
      var hit = 0;
      for (final r in reliable) {
        if (r.maxFatigue >= thr) hit++;
      }
      b.writeln('   임계 ${thr.toStringAsFixed(0).padLeft(2)}% → '
          '$hit 세션');
    }
    b.writeln('   (기대: 신뢰 세션 중 47/58 에서 검출)');
  }

  if (bad.isNotEmpty) {
    b.writeln('\n처리 실패 ${bad.length}건:');
    for (final r in bad) {
      b.writeln('   ${r.path}: ${r.skipReason} '
          '(dur=${_fmt(r.durationS)}s)');
    }
  }

  stdout.write(b.toString());

  if (jsonOut != null) {
    File(jsonOut).writeAsStringSync(
        const JsonEncoder.withIndent(' ')
            .convert(reports.map((r) => r.toJson()).toList()));
    stderr.writeln('\nJSON: $jsonOut');
  }
}
