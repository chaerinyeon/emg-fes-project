/// 웹 모니터로 보내는 프레임 정의.
///
/// ## 웹은 판정하지 않는다
///
/// σ·존·스태미나를 여기서 확정해 보낸다. `monitor.html` 은 SPC 규칙을 모른다.
/// 그래야 폰 게임과 웹 모니터가 같은 σ를 다른 존으로 표시하는 사고가 구조적으로
/// 불가능해진다. 존 경계를 바꾸려면 [FatigueZone] 한 곳만 고치면 된다.
library;

import 'dart:collection';

import '../game/model/zone.dart';

/// 10 Hz 로 흐르는 관찰 프레임 1개.
class MonitorTick {
  const MonitorTick({
    required this.t,
    required this.sigma,
    required this.sigmaPredicted,
    required this.env,
    required this.rms,
    required this.mdf,
    required this.contractions,
    this.t1,
    this.t2,
    this.t3,
  });

  /// 세션 시작 기준 초.
  final double t;

  /// 현재 σ. baseline 확정 전이면 null — "정상"으로 단정하지 않는다.
  final double? sigma;

  /// 예측 σ (선제 경고용). 없으면 null.
  final double? sigmaPredicted;

  final double env;
  final double rms;
  final double mdf;

  /// 지금까지 관측된 수축(버스트) 수.
  final int contractions;

  /// 1σ/2σ/3σ 지속 도달 시각(초). 아직이면 null.
  ///
  /// `SigmaTracker` 는 버스트마다 이 셋을 다시 계산한다(도달 후엔 값이
  /// 고정되지만, 확정 자체는 매 버스트 다시 훑는다). `hello` 는 접속
  /// 시점 1회뿐이라 그 이후의 도달을 반영 못 한다 — 그래서 `tick` 에도
  /// 실어 매 프레임 최신값을 유지한다(Important 5).
  final double? t1;
  final double? t2;
  final double? t3;

  /// σ 로부터의 존. σ 가 없으면 null.
  FatigueZone? get zone {
    final z = sigma;
    return z == null ? null : zoneOf(z);
  }

  /// 스태미나 %. σ 가 없으면 null.
  double? get stamina {
    final z = sigma;
    return z == null ? null : staminaPercent(z);
  }

  Map<String, dynamic> toJson() {
    final z = zone;
    return {
      't': 'tick',
      'ts': t,
      if (sigma != null) 'z': sigma,
      if (sigmaPredicted != null) 'zp': sigmaPredicted,
      if (z != null) 'zone': z.index,
      if (stamina != null) 'stam': stamina,
      'env': env,
      'rms': rms,
      'mdf': mdf,
      'n': contractions,
      if (t1 != null) 't1': t1,
      if (t2 != null) 't2': t2,
      if (t3 != null) 't3': t3,
    };
  }

  factory MonitorTick.fromJson(Map<String, dynamic> j) => MonitorTick(
        t: (j['ts'] as num).toDouble(),
        sigma: (j['z'] as num?)?.toDouble(),
        sigmaPredicted: (j['zp'] as num?)?.toDouble(),
        env: (j['env'] as num).toDouble(),
        rms: (j['rms'] as num).toDouble(),
        mdf: (j['mdf'] as num).toDouble(),
        contractions: (j['n'] as num).toInt(),
        t1: (j['t1'] as num?)?.toDouble(),
        t2: (j['t2'] as num?)?.toDouble(),
        t3: (j['t3'] as num?)?.toDouble(),
      );
}

/// 이산 사건. kind 는 다음 중 하나다:
/// `session_start` `session_stop` `contraction` `zone` `fatigue`
/// `rest_start` `rest_end`
class MonitorEvent {
  const MonitorEvent(this.kind, this.t, {this.zone});

  final String kind;
  final double t;

  /// 존 전환·피로 사건에서의 [FatigueZone.index]. 그 외엔 null.
  final int? zone;

  Map<String, dynamic> toJson() => {
        't': 'event',
        'kind': kind,
        'ts': t,
        if (zone != null) 'zone': zone,
      };
}

/// 접속 직후 1회. 세션 메타 + baseline + 직전 60초 맥락.
///
/// 치료사가 세션 도중에 붙어도 빈 화면을 보지 않게 하는 것이 목적이다.
class MonitorHello {
  const MonitorHello({
    required this.session,
    required this.startedAtMs,
    required this.mu0,
    required this.sd0,
    required this.t1,
    required this.t2,
    required this.t3,
    required this.ticks,
  });

  final String session;
  final int startedAtMs;

  /// baseline 중앙값·견고 표준편차. 확정 전이면 null.
  final double? mu0;
  final double? sd0;

  /// 1σ/2σ/3σ 지속 도달 시각(초). 아직이면 null.
  final double? t1;
  final double? t2;
  final double? t3;

  final List<MonitorTick> ticks;

  Map<String, dynamic> toJson() => {
        't': 'hello',
        'session': session,
        'startedAtMs': startedAtMs,
        'mu0': mu0,
        'sd0': sd0,
        't1': t1,
        't2': t2,
        't3': t3,
        'ticks': [for (final f in ticks) f.toJson()],
      };
}

/// 고정 용량 링버퍼. 넘치면 오래된 것부터 버린다.
class FrameRing {
  FrameRing(this.capacity) : assert(capacity > 0);

  final int capacity;
  final Queue<MonitorTick> _q = Queue<MonitorTick>();

  void add(MonitorTick f) {
    _q.addLast(f);
    while (_q.length > capacity) {
      _q.removeFirst();
    }
  }

  List<MonitorTick> get frames => List.unmodifiable(_q);

  int get length => _q.length;

  void clear() => _q.clear();
}
