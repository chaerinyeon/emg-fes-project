# 캐치 게임 UI 설계안 — RE-FIT 잼잼 grip 바이오피드백

- 작성일: 2026-07-27
- 브랜치: `feature/game`
- 대상 앱: `flutter_app` (RE-FIT, Flutter/Material 3)

## 1. 개요 & 목적

FES-EMG 재활 앱 RE-FIT에 **바이오피드백 훈련용 미니게임**을 추가한다.
FES 자극 박자(≈1.6초)에 맞춰 날아오는 야구공을 **주먹 쥐어(잼) 캐치**하고
**손을 펴(release) 되던지는** 리듬형 grip 훈련이다.

게임의 목적은 재미가 아니라 **바이오피드백 훈련**이다 — 환자의 자발 수축
타이밍과 세기를 실시간으로 화면에 반영해 "정확하고 조절된 쥐기-펴기"를
학습시킨다. 재미/동기부여는 부차적 효과다.

## 2. 확정된 설계 결정

| 항목 | 결정 | 근거 |
|---|---|---|
| 핵심 목적 | 바이오피드백 훈련 | 수축 타이밍·세기를 실시간 반영해 조절 학습 |
| 훈련 능력 | 타이밍/리듬 + 반복 수축 카운트 | 박자에 맞춰 쥐고, 잘 맞춘 수축이 rep |
| 박자(cue) 소스 | FES 자극 주기 **≈1.6초 고정** | 장치가 실제로 1.6초(실측 1621.9ms)마다 자극 → 환자는 그 순간에 맞춰 쥠 (paired-FES 재활 패러다임) |
| 몸값의 역할 | 큐 타이밍은 고정, ENV는 **판정·비주얼·적응난이도**를 좌우 | "언제"는 장치가, "얼마나 잘/세게"는 몸이 결정 |
| 적응 범위 | **적응형 난이도** — 목표세기·허용창·휴식주기를 피로에 따라 조정 (박자는 고정) | 세션 내내 바이오피드백 유지 |
| 대상(MVP) | **건강인 먼저** | 메커니즘·UI 검증 후 환자군 스케일링 |
| 비주얼 메타포 | **야구공 캐치** (잼=글러브 닫기, 펴기=되던지기) | 잼잼 grip 동작에 직관적으로 매핑 |
| 악력의 역할 | **캐치 성공 임계 + 별점** | 약하면 놓침(bobble), 셀수록 별점↑ → 타이밍+세기 동시 훈련 |
| 진입점 | **대시보드(탭1)의 카드/버튼** | 기존 흐름(프로필→연결→운동)에 자연스럽게 편입, 변경 최소 |

## 3. 아키텍처

기존 `MonitorScreen`이 자체 `SessionController`를 소유해 시뮬레이터/BLE를
구독하는 패턴을 그대로 따른다. 게임 로직은 Flutter에서 분리해 순수 Dart로
두어 유닛테스트로 검증 가능하게 한다.

```
SessionController (기존, 재사용)
      │  envLast, st.isStimulating, isRunning
      ▼
BeatSource (추상 인터페이스)              ← 박자 이벤트 방출
  ├ TimerBeatSource(periodSec: 1.6)      ← MVP/건강인 (하드웨어 없이 동작)
  └ StimEdgeBeatSource                    ← 추후: st.isStimulating 상승엣지 = 실제 자극
      │  onBeat(tSec, index)
      ▼
CatchGameEngine (순수 Dart, Flutter 의존 X)
  입력: onEnv(t, env), onBeat(t, index), tick(t)
  출력: GameState
      │
      ▼
GameController (ChangeNotifier)          ← 위 셋을 연결, 렌더 티커로 tick 구동, GameState 노출
      │
      ▼
GameScreen (풀스크린 라우트, 자체 컨트롤러 소유)
  위젯: PitchLane · GloveCatcher · GameHud · GripMeter · BeatTrack · JudgmentFlash · GameResultSheet
```

### 유닛 경계 (각각 독립 이해·테스트 가능)

- **BeatSource** — 무엇: 박자 이벤트를 방출한다. 사용법: `start()`/`stop()`, 콜백 `onBeat(double tSec, int index)`. 의존: 없음(Timer) 또는 SessionController(엣지). 두 구현은 교체 가능.
- **CatchGameEngine** — 무엇: 게임 규칙 전부(공 스폰·타이밍/세기 판정·콤보·별점·적응난이도). 사용법: `onEnv`, `onBeat`, `tick`를 호출하면 `state`가 갱신됨. 의존: `GameConfig` 값 객체만. Flutter·시간·랜덤 의존 없음(시각은 인자로 주입) → 결정론적 테스트 가능.
- **GameController** — 무엇: 신호·박자·엔진을 배선하고 화면에 노출하는 얇은 글루. 사용법: `GameScreen`이 생성/구독/파기. 의존: SessionController, BeatSource, CatchGameEngine.
- **GameScreen + 위젯** — 무엇: `GameState`를 그림. 사용법: `ListenableBuilder(GameController)`. 의존: GameController, 테마.

## 4. 화면 레이아웃 (세로, iPhone)

```
┌──────────────────────────┐
│ ⚾ 12 캐치   🔥 x8   ★★★  │  HUD: 캐치 수 · 콤보 · 별점
│──────────────────────────│
│           ◐  투수          │
│            ⚾              │  공이 박자에 맞춰 날아옴
│             ⚾             │  (1.6초 뒤 글러브 도착)
│              ⚾            │
│        ╱‾‾‾‾‾‾╲           │
│       (   🧤   )          │  글러브(=손). 도착 순간 '잼!'
│        ╲______╱           │
│   ⚡ NOW! 잡아!  PERFECT   │  타이밍 판정 플래시
│  악력 ▁▂▃▅█████ (ENV)     │  실시간 ENV = 악력 게이지
│  다음 투구 ●──●──○ 0.8s   │  박자 트랙(자극 카운트다운)
└──────────────────────────┘
```

- 상단 HUD: 누적 캐치 수, 콤보(연속 성공), 별점.
- 중앙 PitchLane: 투수 → 공 접근 애니메이션. 공 위치가 곧 타이밍 표시자
  (도착선에 닿는 순간이 beat).
- GloveCatcher: 글러브. 캐치/bobble/놓침 상태에 따라 닫힘·튕김·비움 애니메이션.
- JudgmentFlash: Perfect/Good/Early/Late/Miss + "약하게 잡음"(bobble).
- GripMeter: 실시간 ENV 막대 + `gripThreshold` 눈금(넘어야 성공).
- BeatTrack: 다음 투구까지 카운트다운(1.6초 진행바).
- 테마: 기본은 RE-FIT 그린 계열을 따르되, 몰입을 위해 게임 화면은 어두운
  배경(모니터 화면 다크 팔레트 참고) 허용. 풀스크린이라 하단 네비 없음.

## 5. 핵심 루프 & 판정 로직

1. `BeatSource`가 매 1.6초 `onBeat(tBeat, index)` 방출. 엔진은 공 1개를
   **1.6초 전에 스폰**해 `arrivalT = tBeat`에 글러브 도착하도록 애니메이션.
2. 엔진이 ENV 스트림 감시. **clench onset** = ENV가 `onsetThreshold`를
   상향 통과하는 순간 → 그 공의 "캐치 시도"로 기록.
3. **타이밍 판정** = `tClenchOnset − arrivalT`:
   - `|Δ| ≤ perfectMs` → Perfect
   - `|Δ| ≤ goodMs` → Good
   - `Δ < −goodMs`(빨리) → Early, `Δ > goodMs`(늦게) → Late
   - 캐치창(`catchWindowMs`) 내 clench 없음 → **Miss**
4. **세기 판정** = 캐치창 내 ENV 피크(`gripPeak`):
   - `gripPeak ≥ gripThreshold` → 캐치 성공, 피크가 클수록 별점 1~3
   - 임계 미만 → **bobble**(놓침, "약하게 잡음" 피드백)
5. **release 요건** = 다음 beat 전에 ENV가 `releaseThreshold` 밑으로 하강해야
   rep 완료. 안 펴면 콤보 끊김("손을 펴세요") → 쥐고-펴는 잼잼 사이클 훈련.
6. 집계: `reps`=성공 캐치, `combo`=연속 성공, `bestCombo`, `stars` 누적.

**타이밍 해상도 주의:** `envLast`는 BLE 메시지마다(~10Hz, 100ms) 갱신된다.
따라서 MVP 타이밍 판정 해상도는 ~100ms다. `perfectMs`/`goodMs`는 이보다
넉넉히 잡는다(예: perfect ±150ms, good ±350ms). 더 정밀한 판정이 필요하면
추후 RAW 1kHz 스트림을 붙인다(범위 밖).

## 6. 적응형 난이도

- **피로/난이도 프록시** 추적: 최근 N개 rep의 성공률과 ENV 피크 추세
  (피크 하락 + 미스율 상승 = 피로).
- 조정 대상(상·하한 안에서만):
  - `catchWindowMs`: 고전 시 넓힘, 잘하면 좁힘.
  - `gripThreshold`: ENV 피크가 지속 하락하면 낮춤(무리 방지).
- **박자(투구 간격)는 1.6초 고정** — 자극 주기라 바꾸지 않는다.
- 옵션: N회마다 또는 피로 프록시가 높을 때 "쉬는 공"(스킵/휴식 비트) 삽입.

## 7. 진입점 & 세션 통합

- 대시보드 탭(`_dashboardTab`)의 '세션 제어' 영역 근처에 **'⚾ 캐치 게임' 카드/버튼**
  추가 → `Navigator.push(MaterialPageRoute(GameScreen))` (풀스크린).
- `GameScreen`은 `MonitorScreen`처럼 **자체 `SessionController`를 생성·소유**한다.
  - 시작 시: BLE 연결돼 있으면 그 신호 사용, 아니면 **시뮬레이터 시작**(건강인
    MVP는 하드웨어 없이 검증). 세션 시작(`startSession`/`startSimulator`).
  - 박자: MVP는 `TimerBeatSource(1.6s)`. 실제 자극이 있을 때는
    `StimEdgeBeatSource`로 교체(추후).
- 종료 시: 세션 정지(`stopSession`/`stopSimulator`), `GameResultSheet` 표시
  (총 캐치·정확도%·평균/최고 악력·최고 콤보). MVP는 프로필 이력 저장 안 함(범위 밖).

## 8. 데이터 모델 (초안)

```dart
enum JudgmentKind { perfect, good, early, late, miss, bobble }
enum GamePhase { idle, running, paused, finished }

class GameConfig {
  final double beatPeriodSec;      // 1.6
  final double onsetThreshold;     // clench 감지 ENV 임계
  final double releaseThreshold;   // 이완 감지 ENV 임계
  final double perfectMs, goodMs;  // 타이밍 등급 경계
  final double catchWindowMsMin, catchWindowMsMax; // 적응 상·하한
  final double gripThresholdMin, gripThresholdMax; // 적응 상·하한
}

class Ball {
  final int beatIndex;
  final double arrivalT;           // = tBeat
  // 렌더용 진행도는 now/arrivalT로 계산 (엔진은 상태만 보유)
}

class Judgment {
  final JudgmentKind kind;
  final int stars;                 // 0~3
  final double timingErrMs;
  final double gripPeak;
}

class GameState {
  final GamePhase phase;
  final List<Ball> balls;          // 화면상 접근 중인 공들
  final Judgment? lastJudgment;    // 방금 판정(플래시용)
  final int reps, combo, bestCombo, stars;
  final double catchWindowMs, gripThreshold; // 현재 적응값
  final double liveEnv;            // 게이지용
}
```

## 9. MVP 범위

**포함:** 시뮬레이터 구동 캐치 게임 · `TimerBeatSource(1.6s)` · 타이밍+세기 판정 ·
잼잼(쥐고-펴기) release 요건 · 적응형 창/임계 · HUD(캐치·콤보·별점) · 실시간
악력 미터 · 박자 트랙 · 종료 결과 시트 · 대시보드 진입 카드 · iPhone 동작.

**제외(추후):** 실제 자극 엣지 박자 동기(`StimEdgeBeatSource`) · 환자군
스케일링(incomplete/complete) · 프로필 이력/CSV 저장 · 사운드 디자인 ·
M-wave 연동 · 랭킹/멀티플레이 · RAW 1kHz 고정밀 타이밍.

## 10. 성공 기준

- 시뮬레이터만으로 게임 한 판(예: 20 투구)을 처음부터 끝까지 플레이 가능.
- `CatchGameEngine`이 결정론적 유닛테스트로 검증됨(Perfect/Good/Early/Late/
  Miss/bobble, release 요건, 콤보 증감, 적응난이도 조정).
- 대시보드 카드 → GameScreen 진입 → 종료 후 대시보드 복귀 흐름이 세션을
  올바르게 시작·정지(누수 없이).
- iPhone(2)에서 빌드·실행 확인(프로젝트 iOS 빌드 워크플로 따름).

## 11. 열린 질문 (구현 중 확정)

- 캐치창/임계의 구체적 기본값과 적응 스텝(건강인 시뮬레이터로 튜닝).
- "쉬는 공" 삽입 규칙을 MVP에 넣을지, 추후로 미룰지.
- GameScreen 다크 테마를 별도 팔레트로 둘지 앱 테마 확장으로 둘지.
