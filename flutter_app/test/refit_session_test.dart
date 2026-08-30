// RefitSession — Hybrid C 판정 층의 안전 계약 검증.
//
// 여기서 지키는 것은 성능이 아니라 **비협상 규칙**이다:
//   · 자동 UP 이 절대 나가지 않는다
//   · 기준은 '신선 고정(CL0·σ0)'이지 wander 정점이 아니다
//   · STOP 은 정착·워밍업 어떤 유예에도 걸리지 않는다
//   · 명령은 stimOn && mcuState==RUNNING 일 때만 나간다
//   · 명령이 실제로 나갔을 때만 재기준한다
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/core/refit_protocol.dart';
import 'package:flutter_app/services/refit_session.dart';

const _kCycleMs = 1622;
const _kPulseMs = 31;

/// Phase II 가 열리기까지 필요한 버스트 수.
///   전위 plateau(3) → Phase I 90초(≈55버스트) 순서로 게이트가 둘이다.
///   1.622s/버스트이므로 넉넉히 65개(≈105초) 먹인다.
const _kBaseline = 65;

/// 기준 면적. ±500 으로 흔들어 σ0 이 0 이 되지 않게 한다
/// (σ0=0 이면 관리한계가 CL 과 겹쳐 어떤 미세한 하락도 경고가 된다).
double _baselineArea(int i) => i.isEven ? 10500 : 9500;

EpochMsg _ep(int tMs, int stim, int area, {int flags = 0x01}) => EpochMsg(
  seq: 0,
  sessionId: 1,
  stimIndex: stim,
  tMs: tMs,
  sampleIndex: tMs,
  spike: 500,
  p2p: 300,
  flags: flags,
  samples: Int16List.fromList([area]), // area = Σ|표본|
);

StatusMsg _status({
  required bool stimOn,
  required int level,
  int state = kStateRunning,
}) => StatusMsg(
  seq: 0,
  sessionId: 1,
  tMs: 0,
  state: state,
  level: level,
  stimOn: stimOn,
  health: 0,
  lastCmdSeqAck: 0,
  sampleRate: 1000,
  winStartMs: 2,
  winEndMs: 15,
  maxLevel: 10,
);

RefitSession _open({
  List<RefitCommand>? out,
  List<RefitBurst>? bursts,
  bool stimOn = true,
  int level = 5,
  int state = kStateRunning,
}) {
  final s = RefitSession(
    onCommand: out?.add,
    onBurstClosed: bursts?.add,
  );
  s.onEvent(
    const EventMsg(
      seq: 0,
      sessionId: 1,
      tMs: 0,
      eventId: kEvSessionStart,
      detail: 0,
    ),
  );
  s.onEvent(
    const EventMsg(
      seq: 0,
      sessionId: 1,
      tMs: 0,
      eventId: kEvCalibDone,
      detail: 0,
    ),
  );
  s.onStatus(_status(stimOn: stimOn, level: level, state: state));
  return s;
}

/// 버스트 [from, to) 를 먹인다. 버스트는 **다음** 격자의 첫 에폭이 와야 닫히므로
/// N개를 먹이면 확정되는 건 N−1개다.
void _feed(
  RefitSession s,
  int from,
  int to,
  double Function(int i) area, {
  int pulses = 5,
}) {
  for (var i = from; i < to; i++) {
    var stim = i * 100;
    for (var k = 0; k < pulses; k++) {
      s.onEpoch(
        _ep(i * _kCycleMs + k * _kPulseMs, ++stim, area(i).round()),
      );
    }
  }
}

void main() {
  group('안전 비대칭 — 자동 UP 은 존재하지 않는다', () {
    test('RefitAction 에 increase 가 없다 (구조로 보장)', () {
      expect(RefitAction.values, [
        RefitAction.hold,
        RefitAction.decrease,
        RefitAction.stop,
      ]);
    });

    test('면적이 계속 올라가도 명령이 하나도 안 나간다', () {
      final out = <RefitCommand>[];
      final s = _open(out: out);
      _feed(s, 0, _kBaseline, (i) => 5000 + i * 100.0);
      expect(out, isEmpty);
    });
  });

  group('신선 기준(Phase I) 확립', () {
    test('전위 → 기준확립 → 감시 순으로 phase 가 올라간다', () {
      final s = _open();
      expect(s.phase, 0);
      _feed(s, 0, 6, _baselineArea); // 전위 plateau 통과
      expect(s.phase, 1, reason: 'plateau 검출 후 기준 확립 구간');
      expect(s.cl0, 0, reason: 'Phase I 중에는 아직 기준이 없다');
      _feed(s, 6, _kBaseline, _baselineArea);
      expect(s.phase, 2);
      expect(s.cl0, closeTo(10000, 200));
      expect(s.sigma0, greaterThan(0));
      expect(s.clDown, s.cl0);
      expect(s.clStop, s.cl0);
    });

    test('Phase I 중에는 DOWN 이 나가지 않는다', () {
      final out = <RefitCommand>[];
      final s = _open(out: out);
      // 기준이 서기 전에 크게 떨어뜨려도 DOWN 은 없다(기준이 없으므로).
      _feed(s, 0, 6, _baselineArea);
      _feed(s, 6, 40, (i) => 6000);
      expect(
        out.where((c) => c.action == RefitAction.decrease),
        isEmpty,
        reason: '기준 미확립 구간에서 DOWN 은 비활성',
      );
    });

    test('표본이 모자라면 Phase I 을 연장한다 (엉뚱한 σ0 동결 방지)', () {
      // 유효펄스가 2개뿐이라 버스트가 서지 않는 세션 → 90초가 지나도 기준이 안 선다.
      final s = _open();
      _feed(s, 0, 6, _baselineArea);
      _feed(s, 6, 80, _baselineArea, pulses: 2);
      expect(s.phase, 1, reason: '표본 부족이면 판정을 여는 대신 기다린다');
    });
  });

  group('DOWN 트랙 — 느린추세 2σ0', () {
    test('지속 하락이 T_down 을 넘기면 DECREASE, target = 현재−1', () {
      final out = <RefitCommand>[];
      final s = _open(out: out, level: 5);
      _feed(s, 0, _kBaseline, _baselineArea);
      expect(s.phase, 2);
      expect(out, isEmpty);
      // CL0−2σ0 아래지만 CL0−3σ0 위 → DOWN 조건이되 STOP 조건은 아니다.
      final downOnly = s.cl0 - 2.4 * s.sigma0;
      _feed(s, _kBaseline, _kBaseline + 45, (i) => downOnly);
      final downs = out.where((c) => c.action == RefitAction.decrease);
      expect(downs, isNotEmpty);
      expect(downs.first.targetLevel, 4, reason: 'MCU 실제 세기 5 − 1');
      expect(
        out.where((c) => c.action == RefitAction.stop),
        isEmpty,
        reason: '3σ0 아래가 아니므로 STOP 은 없다',
      );
    });

    test('wandering 만으로는 DOWN 이 남발되지 않는다 (구버전 회귀)', () {
      // 구버전은 running-max 기준이라 이런 진동에서 DOWN 을 11~15회 냈다.
      final out = <RefitCommand>[];
      final s = _open(out: out, level: 5);
      _feed(s, 0, _kBaseline, _baselineArea);
      final cl = s.cl0;
      // 수십 초 주기로 ±25% 흔들리는 wander (하락 추세는 없음)
      _feed(
        s,
        _kBaseline,
        _kBaseline + 120,
        (i) => cl * (1 + 0.25 * ((i ~/ 12).isEven ? 1 : -1)),
      );
      expect(
        out.where((c) => c.action == RefitAction.decrease).length,
        lessThanOrEqualTo(2),
        reason: '느린추세가 wander 를 흡수해야 한다',
      );
    });

    test('회복하면 경고 타이머가 리셋된다', () {
      final out = <RefitCommand>[];
      final s = _open(out: out, level: 5);
      _feed(s, 0, _kBaseline, _baselineArea);
      // 잠깐 내려갔다가 CL−1σ0 위로 복귀 — 확정 전에 리셋돼야 한다.
      var i = _kBaseline;
      _feed(s, i, i + 8, (_) => s.cl0 - 2.4 * s.sigma0);
      i += 8;
      _feed(s, i, i + 40, (_) => s.cl0);
      expect(out.where((c) => c.action == RefitAction.decrease), isEmpty);
    });
  });

  group('STOP 트랙 — 원버스트 3σ0 · 절대하한 · 유예 무관', () {
    test('절대 하한(40%×CL0) 아래로 지속되면 STOP', () {
      final out = <RefitCommand>[];
      final s = _open(out: out, level: 5);
      _feed(s, 0, _kBaseline, _baselineArea);
      _feed(s, _kBaseline, _kBaseline + 20, (_) => s.cl0 * 0.30);
      expect(out.any((c) => c.action == RefitAction.stop), isTrue);
    });

    test('DOWN 정착 중에도 STOP 트랙은 살아 있다', () {
      // 정착창이 STOP 을 막으면 응급 지연이 생긴다(사양서 6장).
      final out = <RefitCommand>[];
      final bursts = <RefitBurst>[];
      final s = _open(out: out, bursts: bursts, level: 5);
      _feed(s, 0, _kBaseline, _baselineArea);
      // DOWN 이 나오는 그 순간까지만 먹인다 — 정착창(5버스트) 안에서 붕괴를 주입해야
      // '정착이 STOP 을 막지 않는다'를 실제로 검증할 수 있다.
      var i = _kBaseline;
      final down = s.cl0 - 2.4 * s.sigma0;
      while (!out.any((c) => c.action == RefitAction.decrease) &&
          i < _kBaseline + 60) {
        _feed(s, i, i + 1, (_) => down);
        i++;
      }
      expect(out.any((c) => c.action == RefitAction.decrease), isTrue);
      expect(s.settling, isTrue, reason: 'DOWN 직후이므로 정착창 안이다');
      // 정착 중 붕괴 주입 — Hampel 연속배제 상한 때문에 첫 1개는 삼켜진다.
      _feed(s, i, i + 3, (_) => s.cl0 * 0.20);
      expect(
        bursts.last.dangerActive,
        isTrue,
        reason: '정착 중에도 위험 타이머가 돌아야 한다',
      );
    });
  });

  group('명령 게이트', () {
    test('자극 off 면 전송하지 않는다 (로그 전용)', () {
      final out = <RefitCommand>[];
      final s = _open(out: out, stimOn: false, level: 0);
      _feed(s, 0, _kBaseline, _baselineArea);
      _feed(s, _kBaseline, _kBaseline + 45, (_) => s.cl0 * 0.30);
      expect(out, isEmpty);
    });

    test('mcuState 가 SAFE_HOLD 면 전송하지 않는다', () {
      final out = <RefitCommand>[];
      final s = _open(out: out, level: 5, state: kStateSafeHold);
      _feed(s, 0, _kBaseline, _baselineArea);
      _feed(s, _kBaseline, _kBaseline + 45, (_) => s.cl0 * 0.30);
      expect(out, isEmpty, reason: '안전 정지 상태에서 명령을 얹지 않는다');
    });

    test('명령을 못 보내면 CL 을 재기준하지 않는다', () {
      // 2026-08-24 202251 실측 버그: 전송이 no-op 인데도 재기준이 돌아 기준이
      // 신호를 따라 내려갔다. 기준이 내려가면 진짜 피로를 영영 못 본다.
      final s = _open(stimOn: false, level: 0);
      _feed(s, 0, _kBaseline, _baselineArea);
      final cl = s.clDown;
      expect(cl, greaterThan(0));
      _feed(s, _kBaseline, _kBaseline + 60, (_) => s.cl0 - 2.4 * s.sigma0);
      expect(s.clDown, cl, reason: '재기준은 명령이 실제로 나갔을 때만');
    });
  });

  group('데이터 품질·세션 경계', () {
    test('포화·무효 에폭은 추세에 들어가지 않는다', () {
      final bursts = <RefitBurst>[];
      final s = _open(bursts: bursts);
      var stim = 0;
      for (var k = 0; k < 2; k++) {
        s.onEpoch(_ep(k * _kPulseMs, ++stim, 10000));
      }
      for (var k = 2; k < 5; k++) {
        s.onEpoch(_ep(k * _kPulseMs, ++stim, 10000, flags: 0x03)); // 창포화
      }
      _feed(s, 1, 2, _baselineArea); // 다음 격자 → 앞 버스트 닫기 시도
      expect(bursts, isEmpty, reason: '유효펄스 2개 < 최소 3개');
    });

    test('세션이 바뀌면 기준이 통째로 리셋된다', () {
      final s = _open();
      _feed(s, 0, _kBaseline, _baselineArea);
      expect(s.phase, 2);
      s.onStatus(_status(stimOn: true, level: 5)..sessionId);
      s.onEvent(
        const EventMsg(
          seq: 0,
          sessionId: 2,
          tMs: 0,
          eventId: kEvSessionStart,
          detail: 0,
        ),
      );
      expect(s.phase, 0);
      expect(s.cl0, 0);
      expect(s.clDown, 0);
    });
  });
}
