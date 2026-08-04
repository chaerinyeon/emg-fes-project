import 'package:flutter_app/game/model/zone.dart';
import 'package:flutter_app/monitor/monitor_frame.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MonitorTick', () {
    test('JSON 왕복에서 값이 보존된다', () {
      const tick = MonitorTick(
        t: 12.5,
        sigma: 1.4,
        sigmaPredicted: 1.9,
        env: 120.0,
        rms: 210.5,
        mdf: 88.25,
        contractions: 7,
      );
      final back = MonitorTick.fromJson(tick.toJson());
      expect(back.t, 12.5);
      expect(back.sigma, 1.4);
      expect(back.sigmaPredicted, 1.9);
      expect(back.env, 120.0);
      expect(back.rms, 210.5);
      expect(back.mdf, 88.25);
      expect(back.contractions, 7);
    });

    test('태그가 tick 이다', () {
      const tick = MonitorTick(
        t: 0, sigma: null, sigmaPredicted: null,
        env: 0, rms: 0, mdf: 0, contractions: 0,
      );
      expect(tick.toJson()['t'], 'tick');
    });

    test('σ 가 null 이면 존과 스태미나도 null 이다', () {
      const tick = MonitorTick(
        t: 1, sigma: null, sigmaPredicted: null,
        env: 0, rms: 0, mdf: 0, contractions: 0,
      );
      expect(tick.zone, isNull);
      expect(tick.stamina, isNull);
      expect(tick.toJson().containsKey('zone'), isFalse);
    });

    test('존·스태미나는 zone.dart 규칙을 그대로 쓴다', () {
      const tick = MonitorTick(
        t: 1, sigma: 2.5, sigmaPredicted: null,
        env: 0, rms: 0, mdf: 0, contractions: 0,
      );
      expect(tick.zone, FatigueZone.warning);
      expect(tick.stamina, closeTo(staminaPercent(2.5), 1e-9));
      expect(tick.toJson()['zone'], FatigueZone.warning.index);
    });

    test('t1/t2/t3 가 JSON 왕복에서 보존된다 (Important 5)', () {
      const tick = MonitorTick(
        t: 95.0, sigma: 2.1, sigmaPredicted: null,
        env: 0, rms: 0, mdf: 0, contractions: 10,
        t1: 30.0, t2: 60.0, t3: null,
      );
      final j = tick.toJson();
      expect(j['t1'], 30.0);
      expect(j['t2'], 60.0);
      expect(j.containsKey('t3'), isFalse,
          reason: 'null 인 필드는 다른 필드들과 마찬가지로 실어 보내지 않는다');

      final back = MonitorTick.fromJson(j);
      expect(back.t1, 30.0);
      expect(back.t2, 60.0);
      expect(back.t3, isNull);
    });

    test('t1/t2/t3 가 없으면(hello 이전 tick) 셋 다 null 이다', () {
      const tick = MonitorTick(
        t: 1, sigma: null, sigmaPredicted: null,
        env: 0, rms: 0, mdf: 0, contractions: 0,
      );
      expect(tick.t1, isNull);
      expect(tick.t2, isNull);
      expect(tick.t3, isNull);
      expect(tick.toJson().containsKey('t1'), isFalse);
    });
  });

  group('MonitorEvent', () {
    test('kind·시각·존이 실린다', () {
      final e = MonitorEvent('fatigue', 42.0, zone: FatigueZone.danger.index);
      final j = e.toJson();
      expect(j['t'], 'event');
      expect(j['kind'], 'fatigue');
      expect(j['ts'], 42.0);
      expect(j['zone'], FatigueZone.danger.index);
    });
  });

  group('MonitorHello', () {
    test('링버퍼 프레임과 baseline 을 함께 싣는다', () {
      const tick = MonitorTick(
        t: 1, sigma: 0.5, sigmaPredicted: null,
        env: 0, rms: 0, mdf: 0, contractions: 1,
      );
      final hello = MonitorHello(
        session: '홍길동',
        startedAtMs: 1000,
        mu0: 900.0,
        sd0: 45.0,
        t1: 30.0,
        t2: null,
        t3: null,
        ticks: const [tick],
      );
      final j = hello.toJson();
      expect(j['t'], 'hello');
      expect(j['session'], '홍길동');
      expect(j['mu0'], 900.0);
      expect(j['t1'], 30.0);
      expect(j['t2'], isNull);
      expect((j['ticks'] as List).length, 1);
      expect((j['ticks'] as List).first['ts'], 1);
    });
  });

  group('FrameRing', () {
    test('용량을 넘으면 오래된 것부터 버린다', () {
      final ring = FrameRing(3);
      for (var i = 0; i < 5; i++) {
        ring.add(MonitorTick(
          t: i.toDouble(), sigma: null, sigmaPredicted: null,
          env: 0, rms: 0, mdf: 0, contractions: 0,
        ));
      }
      expect(ring.length, 3);
      expect(ring.frames.map((f) => f.t), [2.0, 3.0, 4.0]);
    });

    test('용량 이하면 전부 보존한다', () {
      final ring = FrameRing(600);
      ring.add(const MonitorTick(
        t: 1, sigma: null, sigmaPredicted: null,
        env: 0, rms: 0, mdf: 0, contractions: 0,
      ));
      expect(ring.length, 1);
    });
  });
}
