/// RE-FIT 신호 상수 — 공통 컨텍스트 4장 상수 테이블.
///
/// 이 파일은 **순수 Dart**다. flutter/material 을 import 하지 않는다.
/// 신호 엔진 전체를 `dart test` 로 돌려 오프라인 Python 파이프라인과
/// 1:1 대조하기 위해서다. (기존 `lib/core/constants.dart` 는 BLE UUID·색상
/// 전용이라 Flutter 의존이 있어 여기 섞지 않았다.)
///
/// 값을 바꾸지 말 것. 바꿔야 한다고 판단되면 먼저 물어볼 것.
library;

// ===== 신호 =====

/// 원시 샘플레이트.
const int kSampleRateHz = 1000;

/// M-wave 측정 창 (자극 onset = 0ms 기준, 시작 포함 / 끝 제외).
/// 1kHz 이므로 정확히 10 샘플이다.
const int kMwaveWindowStartMs = 5;
const int kMwaveWindowEndMs = 15;

/// 버스트 내 펄스 주파수.
///
/// 실측 in-burst ISI 중앙값이 31.0ms 정수라 1/0.031 = 32.26Hz 로 보이지만,
/// 이는 1kHz 샘플링의 양자화 착시다. 실제는 32Hz 근방.
const double kPulseFreqHz = 32.0;

// ===== 버스트 (사전값, 세션마다 추정 갱신) =====

/// 자극 ON 구간.
const int kStimOnMs = 591;

/// 자극 OFF 구간.
const int kStimOffMs = 1027;

/// 총 주기. 실측 88세션 중앙값 1619.5ms 로 확인됨.
const int kStimPeriodMs = 1618;

// ===== 필터 =====

/// Hampel 윈도우 크기 (홀수).
const int kHampelK = 7;

/// Hampel 이상치 임계 (MAD 기반 시그마 배수).
const double kHampelSigma = 3.0;

/// MAD → 표준편차 환산 상수 (정규분포 가정).
const double kMadToSigma = 1.4826;

// ===== 판정 (P0에서 실측 튜닝) =====

/// contraction_ok 임계 배수. p2p >= A_ref * 이 값 이면 수축 성공.
// TODO(P0): 실측 확정 — 현재는 공통 컨텍스트 사전값
const double kContractionK = 0.30;

/// 적응형 피로 게이지 종료 임계(%).
/// P0 확정 전까지 null — null 이면 피로 기반 자동 종료를 걸지 않는다.
// TODO(P0): 실측 확정. null 인 동안은 백업 종료조건(성공률·시간)만 동작한다.
const double? kFatigueThresholdPct = null;

/// 피로 임계가 연속 몇 버스트 유지되어야 종료로 인정하는가.
const int kFatigueConsecutiveBursts = 8;

// ===== 신뢰도 =====

/// 버스트당 최소 검출 이벤트 수.
const int kMinEventsPerBurst = 10;

/// 최소 검출률.
const double kMinDetectRate = 0.50;

/// 검출 실패가 이만큼 지속되면 signal_lost.
const int kSignalLostTimeoutS = 30;

/// 버스트 1회에서 기대되는 펄스 수. 검출률의 분모다.
///
/// 591ms ON / 31ms ISI ≈ 19.1 이지만, 기존 master 파이프라인이 20을 분모로
/// 쓰고 있어 그 정의를 그대로 따른다(detect_rate 를 과거 결과와 비교 가능하게).
const int kExpectedPulsesPerBurst = 20;

/// 등급 A 의 하한 (events/burst, 검출률).
// TODO(P0): 실측 확정
const int kGradeAEventsPerBurst = 15;
const double kGradeADetectRate = 0.75;

// ===== 세션 =====

/// 자극 주기 동기화 + A_ref 워밍업 구간.
const int kSyncWindowS = 30;

/// 화면 큐가 자극보다 앞서는 시간. 이 값을 줄이면 훈련 효과가 사라진다.
const int kCueLeadMs = 300;

/// 세션 시간 상한.
const int kSessionMaxMin = 15;

/// 백업 종료: 초기 대비 성공률 하락폭.
const double kSuccessRateDropRatio = 0.40;

/// 성공률 평가 윈도우 (버스트).
const int kSuccessRateWindow = 50;

/// 위상 드리프트 허용치. 초과 시 로그를 남기고 재동기한다.
const int kPhaseDriftToleranceMs = 100;

// ===== [B] 자극 검출 =====
//
// 공통 컨텍스트는 "고정 임계 1000 금지 / noise RMS의 배수" 만 규정하고
// 배수 자체는 정하지 않았다. 아래는 P0 튜닝 대상이다.

/// 자극 후보 임계 = 잡음 산포 × 이 배수.
const double kStimThresholdNoiseMult = 8.0;

/// 검출 임계의 하한 (ADC LSB 단위).
const double kStimThresholdFloorAdc = 40.0;

// --- 아티팩트 규모 기준 ---
//
// 잡음 배수는 위아래 어느 쪽으로도 못 믿는다. 조용한 세션은 σ=8 → 임계 65 로
// 아티팩트(≈900) 밑까지 내려가 한 자극이 여러 번 잡히고(102627: epb 38.2),
// 시끄러운 세션은 σ×8=2491 이 신호 최대 2202 를 넘어 검출이 0이 된다
// (205037). 그래서 임계를 **아티팩트 진폭**에 묶는다. 26세션 비교(불응기 26ms):
//
//   규칙                    epb중앙  epb>21  중복률  검출0
//   max(σ×8, 0.30×p99.5)    19.99      4    0.033    1
//   0.35 × p99.5            19.99      6    0.025    0   ← 채택
//
// σ 는 임계가 아니라 부착 체크(looksQuiet)에 쓴다.

/// 아티팩트 규모 추정에 쓰는 세션 도입부 길이(ms).
const int kArtifactScaleWindowMs = 5000;

/// 아티팩트 규모로 삼을 |신호−DC| 백분위수.
const double kArtifactScalePercentile = 99.5;

/// 임계 = 아티팩트 규모 × 이 비율.
const double kArtifactScaleFrac = 0.35;

/// 펄스 그룹화 불응기(ms). 같은 펄스의 여러 샘플·꼬리를 하나로 묶는다.
///
/// 실측 in-burst ISI 는 31ms 다. 불응기가 이보다 **크면** 자극의 절반만
/// 검출된다(과거 펌웨어 MW_REFRACTORY_MS=40 버그). 반대로 너무 **작으면**
/// 아티팩트 꼬리와 M-wave 가 새 펄스로 잡힌다. 26ms 는 그 사이다.
const int kPulseRefractoryMs = 26;

/// 버스트 경계 판정 gap(ms). 펄스 간 간격이 이보다 크면 새 버스트.
const int kBurstGapMs = 800;

/// 주기 추정 탐색 범위 (사전값 kStimPeriodMs 근방).
const int kPeriodSearchMinMs = 1200;
const int kPeriodSearchMaxMs = 2100;

/// 위상 재정렬 주기 (버스트). 이만큼마다 실제 검출 시점으로 재동기.
const int kPhaseResyncEveryBursts = 10;

// ===== [D] 에폭별 영점보정 =====
//
// **자극 직전 구간을 영점 기준으로 쓰지 않는다.** (하드 제약 1)
// 실측에서 자극 직전 5샘플이 M-wave 피크의 중앙 20.2% 크기로 오염되어 있었고
// 88세션 중 74세션이 10%를 넘었다. 그래서 영점은 M-wave 가 끝난 뒤
// (다음 펄스 아티팩트가 오기 전) 구간에서 잡는다.

/// 에폭 길이(ms). in-burst ISI 1개분.
const int kEpochLenMs = 31;

/// 에폭 영점 구간 시작(ms, onset 기준). M-wave 창(5~15ms) 이후.
const int kEpochBaselineStartMs = 18;

/// 에폭 영점 구간 끝(ms, onset 기준, 제외). 다음 펄스 아티팩트 이전.
const int kEpochBaselineEndMs = 28;

/// 샘플 링버퍼 길이(ms). 버스트는 다음 버스트가 시작될 때 닫히므로
/// 최소 한 주기 + 여유가 필요하다.
const int kSampleRingMs = 4000;

// ===== [A] DC 캘리브 =====

/// DC offset 추정에 쓰는 무자극 구간 길이(ms).
/// 하드코딩 금지 — 반드시 세션 시작 직후 실측으로 잡는다.
const int kDcCalibWindowMs = 1500;

/// DC 캘리브에 필요한 최소 샘플 수.
const int kDcCalibMinSamples = 200;

/// 부착 체크에서 EMG 전극을 정상으로 볼 잡음 상한(ADC LSB).
///
/// 실측 88세션의 도입부 σ 는 대부분 8~40 이었고, 전극이 뜬 세션에서
/// 311까지 올라갔다(raw_20260730_205037_C_complete.csv).
// TODO(P0): 실측 분포로 확정
const double kAttachMaxNoiseSigma = 120.0;

// ===== [H] 적응형 레벨 구간 =====

/// 레벨 시프트 판정 윈도우 (버스트). 최근 W개 중앙값으로 판정.
// TODO(P0): 실측 확정
const int kLevelShiftWindow = 9;

/// 레벨 시프트로 인정하기 위해 이탈이 지속되어야 하는 버스트 수.
// TODO(P0): 실측 확정
const int kLevelShiftSustain = 5;

/// 현재 구간 기준선 대비 이 비율 이상 벗어나면 시프트 후보.
/// 실측 세션당 평균 4.1회의 레벨 변화를 잡아내는 것이 목표.
// TODO(P0): 실측 확정
const double kLevelShiftRatio = 0.35;

// ===== [I] 피로도 =====

/// 인과 EMA 계수. 작을수록 부드럽고 느리다.
// TODO(P0): 실측 확정
const double kFatigueEmaAlpha = 0.15;

/// 급등 감지: 이 시간(초) 안에
const int kFatigueSpikeWindowS = 32;

/// 이만큼(%p) 이상 오르면 피로가 아니라 "센서 점검 안내"로 분기한다.
/// 실측 13/58 세션에서 나타났고 대부분 전극·자세 변화였다.
const double kFatigueSpikePct = 30.0;
