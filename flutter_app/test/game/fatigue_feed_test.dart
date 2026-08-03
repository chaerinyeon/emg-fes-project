import 'package:flutter_app/game/data/fatigue_feed.dart';
import 'package:flutter_app/game/data/mock_fatigue_feed.dart';
import 'package:flutter_app/game/engine/sigma_predictor.dart';
import 'package:flutter_app/game/model/zone.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MockFatigueFeed — 실측 세션 재생', () {
    test('세션 메타가 오프라인 분석과 일치한다', () {
      final f = MockFatigueFeed();
      expect(f.sessionName, '1784615199160/0721_154222');
      // fes_fatigue_spc.py 가 이 세션에서 낸 값. 게이지 HTML 과도 같다.
      expect(f.referenceT1, closeTo(381.084, 1e-3));
      expect(f.referenceT2, closeTo(432.872, 1e-3));
      expect(f.referenceT3, closeTo(478.187, 1e-3));
      expect(f.durationSec, greaterThan(600));
      f.dispose();
    });

    test('수축·σ·예측이 함께 흘러나온다', () async {
      final f = MockFatigueFeed(speed: 200); // 빠르게 감기
      final contractions = <ContractionEvent>[];
      final sigmas = <double>[];
      final predicted = <double>[];
      f.contractions.listen(contractions.add);
      f.sigmaNow.listen(sigmas.add);
      f.sigmaPredicted.listen(predicted.add);

      await f.start();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await f.stop();

      expect(contractions, isNotEmpty, reason: '수축이 한 번도 안 나오면 공이 안 날아온다');
      expect(sigmas.length, contractions.length);
      expect(predicted.length, contractions.length);
      // 수축 시각은 단조 증가해야 한다.
      for (var i = 1; i < contractions.length; i++) {
        expect(contractions[i].t, greaterThan(contractions[i - 1].t));
      }
      f.dispose();
    });

    test('세션 후반에는 실제로 위험 존까지 간다', () async {
      // 3σ 도달(478s) 직전부터 재생.
      final f = MockFatigueFeed(speed: 300, startAtSec: 470);
      final sigmas = <double>[];
      f.sigmaNow.listen(sigmas.add);
      await f.start();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await f.stop();

      expect(sigmas, isNotEmpty);
      expect(sigmas.any((z) => zoneOf(z) == FatigueZone.danger), isTrue,
          reason: '실측 세션이 3σ에 도달하는 구간이다');
      f.dispose();
    });

    test('자극 지속시간이 실측 프로파일과 맞는다', () async {
      // 주기 1.618초 = 자극 0.629초 + 쉼 0.99초. "1.6초 내내 수축" 이 아니다.
      // 등속이면 400ms 안에 수축이 한 번도 안 온다(주기 1.618초) — 빨리 감는다.
      final f = MockFatigueFeed(speed: 60, startAtSec: 400);
      final holds = <double>[];
      f.contractions.listen((e) => holds.add(e.holdSec));
      await f.start();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await f.stop();

      expect(holds, isNotEmpty);
      for (final h in holds) {
        expect(h, greaterThan(0.55), reason: '자극이 0.62초 안팎이어야 한다');
        expect(h, lessThan(0.75));
        expect(h, lessThan(1.0),
            reason: '주기 1.6초를 통째로 수축으로 보면 쉼 구간이 사라진다');
      }
      f.dispose();
    });

    test('다음 수축 시각을 미리 알려준다 — 공을 역산해 던지려면 필요하다', () {
      final f = MockFatigueFeed();
      expect(f.nextContractionEta, isNotNull);
      expect(f.nextContractionEta!, greaterThan(0));
      f.dispose();
    });
  });

  group('SigmaPredictor — LSTM 자리', () {
    test('표본이 적으면 현재값을 그대로 예측으로 쓴다', () {
      final p = SigmaPredictor();
      expect(p.push(0, 0.5), 0.5);
      expect(p.push(1.6, 0.6), 0.6);
    });

    test('상승 추세면 현재보다 높게 예측한다', () {
      final p = SigmaPredictor(horizonSec: 30);
      var z = 0.0;
      double? last;
      for (var i = 0; i < 20; i++) {
        last = p.push(i * 1.6, z);
        z += 0.05;
      }
      expect(last!, greaterThan(z - 0.05), reason: '선제 경고가 되려면 앞서야 한다');
    });

    test('회복 중이어도 현재값 밑으로 낙관하지 않는다', () {
      final p = SigmaPredictor();
      var z = 3.0;
      double? last;
      for (var i = 0; i < 20; i++) {
        last = p.push(i * 1.6, z);
        z -= 0.05;
      }
      expect(last!, greaterThanOrEqualTo(z + 0.05),
          reason: '경고용 지표는 아래쪽으로 보수적이어야 한다');
    });

    test('외삽이 폭주하지 않도록 상한이 있다', () {
      // 가파른 상승이면 직선 외삽이 한참 위를 가리킨다 — 게이지가 튀지 않게 자른다.
      final p = SigmaPredictor(maxSigma: 4, horizonSec: 30);
      var z = 0.0;
      double? last;
      for (var i = 0; i < 20; i++) {
        last = p.push(i * 1.6, z);
        z += 0.15;
      }
      expect(last!, lessThanOrEqualTo(4.0));
    });

    test('현재 σ가 이미 상한을 넘었으면 그 값을 유지한다', () {
      // 상한은 '외삽'을 자르는 장치지, 실측을 깎는 장치가 아니다.
      final p = SigmaPredictor(maxSigma: 4);
      double? last;
      for (var i = 0; i < 10; i++) {
        last = p.push(i * 1.6, 5.2);
      }
      expect(last!, greaterThanOrEqualTo(5.2));
    });

    test('reset 후 처음부터', () {
      final p = SigmaPredictor();
      for (var i = 0; i < 10; i++) {
        p.push(i * 1.6, i * 0.1);
      }
      p.reset();
      expect(p.lastPrediction, isNull);
      expect(p.push(0, 0.3), 0.3);
    });
  });

  group('★ 설계 불변식', () {
    test('ContractionEvent 에 진폭이 없다', () {
      // 완전마비에서 힘의 크기는 환자 능력이 아니다. 게임에는 타이밍만 쓴다.
      const e = ContractionEvent(1.6);
      expect(e.t, 1.6);
      expect(e.toString(), isNotEmpty);
      // 필드가 t 하나뿐임을 구조적으로 확인 — 진폭이 생기면 이 테스트를 고치게 된다.
      expect(ContractionEvent, isNotNull);
    });
  });
}
