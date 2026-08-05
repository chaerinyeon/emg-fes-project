import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_app/game/data/fatigue_feed.dart';
import 'package:flutter_app/game/model/zone.dart';
import 'package:flutter_app/game/ui/game_screen.dart';
import 'package:flutter_app/game/ui/widgets/patient_status_card.dart';
import 'package:flutter_app/game/ui/widgets/rest_overlay.dart';
import 'package:flutter_app/game/ui/widgets/session_hud.dart';
import 'package:flutter_test/flutter_test.dart';

/// 아무것도 흘리지 않는 조용한 피드 — 배치만 보면 되므로 애니메이션을 안 만든다.
class _StillFeed implements FatigueFeed {
  _StillFeed(this.sigma);

  final double sigma;

  @override
  double get nowSec => 0;

  @override
  Stream<ContractionEvent> get contractions => const Stream.empty();

  @override
  Stream<double> get sigmaNow => Stream.value(sigma);

  @override
  Stream<double> get sigmaPredicted => Stream.value(sigma + 0.6);

  @override
  double get predictionHorizonSec => 30;

  @override
  double? get nextContractionEta => null;

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  @override
  void dispose() {}
}

void main() {
  Future<void> pumpAt(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(home: GameScreen(feed: _StillFeed(2.4))),
    );
    // pumpAndSettle 은 쓰지 않는다 — 게임 루프가 매 프레임 다시 그려 영영 안 멈춘다.
    //
    // 여러 프레임을 미는 이유: Flame 의 onLoad 가 async 라 첫 프레임에는 σ 구독이
    // 아직 안 붙어 있다. 한 프레임만 밀면 σ 가 null 인 채로 화면이 굳는데, 그러면
    // "σ 가 화면에 없다"는 경계 테스트가 **애초에 값이 없어서** 공허하게 통과한다.
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 32));
    }
  }

  group('★ HUD 가 포구 지점을 가리지 않는다', () {
    /// 화면 중앙 아래쪽 — 공이 날아와 글러브에 잡히는 영역.
    Rect playArea(Size s) => Rect.fromLTRB(
          s.width * 0.25,
          s.height * 0.45,
          s.width * 0.75,
          s.height,
        );

    for (final size in const [
      Size(390, 844), // iPhone 세로
      Size(320, 568), // 구형 소형
      Size(900, 500), // 가로
    ]) {
      testWidgets('${size.width.toInt()}x${size.height.toInt()} — '
          'HUD 가 포구 영역을 침범하지 않는다', (tester) async {
        await pumpAt(tester, size);
        final zone = playArea(size);

        for (final finder in [
          find.byType(SessionHud),
          find.byType(PatientStatusCard),
        ]) {
          expect(finder, findsOneWidget);
          final rect = tester.getRect(finder);
          expect(rect.overlaps(zone), isFalse,
              reason: '$rect 가 포구 영역 $zone 을 덮는다 — 공이 잡히는 장면이 '
                  '이 화면의 전부라 절대 가리면 안 된다');
        }
        expect(tester.takeException(), isNull, reason: '오버플로우가 나면 안 된다');
      });
    }

    testWidgets('세션 바는 좌상단, 스태미나는 우상단', (tester) async {
      await pumpAt(tester, const Size(390, 844));
      final hud = tester.getRect(find.byType(SessionHud));
      final panel = tester.getRect(find.byType(PatientStatusCard));
      expect(hud.left, lessThan(390 / 2));
      expect(panel.right, greaterThan(390 / 2));
      expect(hud.overlaps(panel), isFalse, reason: '두 박스가 겹치면 안 된다');
    });

    testWidgets('두 박스 모두 화면 안에 있다', (tester) async {
      await pumpAt(tester, const Size(320, 568));
      for (final f in [find.byType(SessionHud), find.byType(PatientStatusCard)]) {
        final r = tester.getRect(f);
        expect(r.left, greaterThanOrEqualTo(0));
        expect(r.right, lessThanOrEqualTo(320));
      }
    });
  });

  group('★ 화면 역할 분리 — 폰은 환자, 웹은 치료사 (회귀)', () {
    /// 트리에 실제로 그려진 텍스트 전부.
    ///
    /// 판정은 **문자열로만** 한다. 색(무대 틴트·위험 비네트·스태미나 채움)은
    /// 대상이 아니다 — 설계상 폰에 남기기로 한 것들이다.
    List<String> renderedText(WidgetTester tester) => tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? '')
        .where((s) => s.isNotEmpty)
        .toList();

    void expectNoClinicalReadout(WidgetTester tester, String where) {
      final texts = renderedText(tester);

      // σ 숫자 — 예전엔 우상단에 "2.4 σ" 가 떴다.
      expect(
        texts.where((t) => t.contains('σ')),
        isEmpty,
        reason: '$where 에 σ 표기가 남아 있다: $texts — σ 는 치료사의 관찰 웹이 맡는다',
      );

      // 존 명칭·배너 — "경고", "⚠ 경고", "위험! 관리이탈 — ..." 따위.
      for (final zone in FatigueZone.values) {
        expect(
          texts.where((t) => t.contains(zone.label) || t.contains(zone.banner)),
          isEmpty,
          reason: '$where 에 존 표기(${zone.label})가 남아 있다: $texts',
        );
      }
    }

    // ── 화면 레벨 ────────────────────────────────────────────────
    //
    // 위젯 테스트에서는 Flame 루프가 σ 구독까지 가지 못해 σ 가 null 로 남는다.
    // 그래도 이 테스트는 공허하지 않다 — 되돌아올 가능성이 가장 큰 `FatiguePanel`
    // 은 σ 가 null 이어도 `' σ'` 를 **상수 텍스트로 항상** 그렸기 때문에, 그게
    // 다시 붙는 순간 여기서 걸린다.
    testWidgets('게임 화면에 σ·존 표기가 없다', (tester) async {
      await pumpAt(tester, const Size(390, 844));
      expectNoClinicalReadout(tester, '게임 화면');
    });

    testWidgets('게임 화면에 스태미나 카드는 남아 있다', (tester) async {
      await pumpAt(tester, const Size(390, 844));
      // 반대편 핀 — 경계 테스트가 "전부 지우기"로 통과되면 안 된다.
      // 환자가 STOP 을 누를 근거가 하나는 화면에 있어야 한다.
      expect(find.byType(PatientStatusCard), findsOneWidget);
      expect(renderedText(tester), contains('근육 스태미나'));
    });

    // ── 위젯 레벨 ────────────────────────────────────────────────
    //
    // 여기서는 σ 를 직접 주입한다. 값이 실제로 들어와도 숫자로 새 나가지
    // 않는다는 것이 이 분리의 핵심이라, 값 없는 화면 레벨 테스트만으로는 부족하다.
    testWidgets('스태미나 카드는 σ 를 받아도 숫자로 내보내지 않는다', (tester) async {
      // 2.4σ = 경고 존. 분리 전이라면 "2.4 σ" 와 "⚠ 경고" 가 함께 떴다.
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: PatientStatusCard(sigma: 2.4)),
        ),
      );
      expectNoClinicalReadout(tester, '스태미나 카드');
      // 100 − 2.4/4×100 = 40%
      expect(renderedText(tester), containsAll(['근육 스태미나', '40%']));
    });

    testWidgets('휴식 화면은 σ·존 없이 스태미나만 보여준다', (tester) async {
      // 3.5σ = 위험 존. 예전엔 여기서 풀 게이지와 존 타임라인을 펼쳤고
      // "관리이탈 구간입니다" 라는 SPC 용어를 환자에게 그대로 보여줬다.
      await tester.pumpWidget(
        const MaterialApp(
          home: RestOverlay(sigma: 3.5, remainingSec: 20, inning: 2),
        ),
      );
      expectNoClinicalReadout(tester, '휴식 화면');
      final texts = renderedText(tester);
      // 100 − 3.5/4×100 = 12.5 → 13%
      expect(texts, containsAll(['잠시 쉬어요', '근육 스태미나', '13%']));
      expect(texts.where((t) => t.contains('관리이탈')), isEmpty,
          reason: '환자에게 SPC 용어를 그대로 보여주지 않는다');
    });
  });
}
