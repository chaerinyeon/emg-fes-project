/*
  EMG-FES Closed-Loop Controller (BLE 버전)

  분석 방법: RAW + MDF 결합 (방식 3 - 이중 조건)
  - RMS slope > +20% AND MDF slope < -3% → 피로 판정
  - 5회 연속 만족 시 마사지기 OFF

  하드웨어:
  - MyoWare 2.0 Wireless Shield (ESP32-WROOM 내장)
  - MyoWare 2.0 Muscle Sensor + 전극
  - PC817 + IRLZ44N → 오므론 HV-F022-V (마사지기/FES)
  - 전원: USB-C 보조배터리 또는 LiPo 배터리

  통신: BLE GATT (Nordic UART Service 호환 UUID)
    - Service:  6E400001-B5A3-F393-E0A9-E50E24DCCA9E
    - DATA  (Notify, ESP32→Phone): 6E400003-...
    - CMD   (Write,  Phone→ESP32): 6E400002-...

  필요 라이브러리 (Arduino IDE Library Manager):
    - NimBLE-Arduino  (by h2zero, v2.x)
    - ArduinoJson     (v6.x)
    - arduinoFFT      (v2.x)
*/

#include <NimBLEDevice.h>
#include <ArduinoJson.hpp>
#include <arduinoFFT.h>
#include <math.h>

// ===== BLE UUID (Nordic UART Service 호환) ====


#define SERVICE_UUID     "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
#define CHAR_DATA_UUID   "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"
#define CHAR_CMD_UUID    "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
#define CHAR_RAW_UUID    "6E400004-B5A3-F393-E0A9-E50E24DCCA9E"  // RAW 4kHz 파형 (binary notify)
#define BLE_DEVICE_NAME  "EMG-FES-01"

// ===== 핀 설정 =====
const int PIN_EMG_RAW = 36;     // A4 - MyoWare SIG (RAW EMG)
// 주: MyoWare 2.0은 SIG 한 채널만 출력. ENV는 RAW로부터 SW에서 계산.
const int PIN_STATUS_LED = 13;

const int PIN_MASSAGER_ON_OFF = 32;
const int PIN_MASSAGER_MODE   = 33;
const int PIN_MASSAGER_UP     = 25;
const int PIN_MASSAGER_DOWN   = 26;

// ===== 신호처리 파라미터 =====
const int SAMPLE_RATE = 4000;              // 4kHz 샘플링 (0.25ms/표본)
const int FFT_SIZE = 2048;                 // FFT 윈도우 (2048표본=512ms 분량 @4kHz)
// RMS 윈도우 = 자극 버스트 주기의 정수배여야 한다.
// 실측 버스트 주기 1621.9ms (버스트 593ms + 쉼 1029ms, duty 37%).
// 1000ms 였을 때: 주기의 0.62배라 창이 버스트를 0.59~1.0 비율로 물어 duty-cycle 에 따라
// RMS 가 출렁였다. 주기와 같은 1622ms 면 창 위상과 무관하게 항상 정확히 버스트 1개를
// 포함한다 → RMS 가 위상 불변이 된다.
// (기기는 잠금 수준으로 안정적: 033307 주기 σ=0.58ms, 세션 전체 드리프트 0.3ms → 재정렬 불필요)
const int RMS_WINDOW = 6488;               // = 버스트 주기 1621.9ms (실측, @4kHz)
const int HISTORY_SIZE = 60;               // 60초 분량 RMS/MDF 히스토리

// 임계값 (방식 3: 이중 조건)
float RMS_THRESHOLD = 20.0;                // RMS slope +20% 이상
float MDF_THRESHOLD = -3.0;                // MDF slope -3% 이하 (노이즈 감안 완화)
const int CONSECUTIVE_TRIGGER = 5;
const int DC_OFFSET_FALLBACK = 1862;       // 동적 캘리브레이션 전 안전 기본값
const int DC_CALIBRATION_MS = 3000;        // 세션 시작 직후 무자극 휴식 평균
volatile int dcOffset = DC_OFFSET_FALLBACK;
volatile int64_t dcCalibrationSum = 0;
volatile uint32_t dcCalibrationCount = 0;
volatile bool dcCalibrating = false;

// 베이스라인
const int BASELINE_SAMPLES = 10;
const unsigned long BASELINE_DELAY_MS = 30000;  // 준비운동 구간 제외
const float MUSCLE_LOW_RATIO  = 0.7;
const float MUSCLE_HIGH_RATIO = 1.5;

// 안전장치
const unsigned long STIM_TIMEOUT_MS = 180000;   // 3분
const unsigned long DATA_THROTTLE_MS = 100;     // 데이터 송신 최소 간격 (BLE 부하 보호)

// ===== M-wave 검출 파라미터 =====
// 자극 artifact 검출 임계 (DC 보정된 centered 값의 절대값).
// 실측에서 normal EMG burst 최대보다 충분히 커야 함. 일반적으로 1000~2000 범위.
const int MW_ARTIFACT_THRESHOLD = 1000;
// 창 시작 = artifact 제외용 dead-zone.
// 5ms 였을 때의 치명적 문제: 이 셋업의 M-wave 양의 정점은 3ms 에 있는데 창이 5ms 부터라
// argmax 가 항상 창 첫 표본(=5)에 붙었다(실측 99.9%/96.3%). 과거 latency>=6 게이트에서
// 전량 탈락 → MW_Valid ≈ 0%(042118 은 5,363행 중 1행).
// 진폭 게이트는 100% 통과했으므로 오직 이 모순 때문에 M-wave 가 통째로 버려지고 있었다.
//
// 2ms 로 여는 근거: 자극 스파이크는 0~1ms 의 용량성 성분이고, 2~4ms 는 이미 M-wave 다.
// (실측: 2~4ms 성분은 M-wave 5~15ms 와 ρ=+0.96, 바로 옆 0~1ms 스파이크와는 ρ=+0.32
//  → 1ms 떨어진 이웃보다 10ms 떨어진 M-wave 와 붙어 움직인다 = 근육 신호)
// STA 평균파형 실측: 0ms=-1042, 1ms=-585, 2ms=+362, 3ms=+546(정점), 4ms=+493, 5ms=+352
const int MW_WINDOW_START_MS = 2;             // 자극 후 ms (0~1ms 스파이크만 제외)
// 창 끝은 '다음 자극이 오기 전'이어야 한다. 실측 자극 간격은 최소 30ms(ISI 분포 30/31/32ms,
// 평균 31.185ms = 32.078Hz)이므로 30이면 ISI=30ms인 자극(실측 9%)의 마지막 표본이 '다음 자극
// 스파이크'가 되어 M-wave 를 오염시킨다. 28 이면 항상 다음 자극 앞에서 닫힌다.
// (M-wave 는 5~15ms 라 28 로 줄여도 손실 없음)
const int MW_WINDOW_END_MS = 28;              // 자극 후 ms
const int MW_WINDOW_START_SAMPLES = MW_WINDOW_START_MS * SAMPLE_RATE / 1000;
const int MW_WINDOW_END_SAMPLES = MW_WINDOW_END_MS * SAMPLE_RATE / 1000;
const int MW_WINDOW_LEN = MW_WINDOW_END_SAMPLES - MW_WINDOW_START_SAMPLES + 1;
// 불응기는 자극 주기(실측 31.185ms)보다 반드시 작아야 한다.
// 40ms 였을 때: 40 > 31 이라 자극 하나 걸러 하나만 검출 → 실측 검출률 50.0%(042118),
// blanking 도 그 절반에만 걸려 놓친 스파이크가 RMS 전력의 76% 를 차지했다.
// 27ms 면 artifact 폭(~18ms)보다 길고 ISI 최소값 30ms 보다 짧아 모든 자극을 잡는다.
const unsigned long MW_REFRACTORY_MS = 27;    // < 자극주기 31.185ms (실측)
const uint32_t MW_REFRACTORY_SAMPLES = MW_REFRACTORY_MS * SAMPLE_RATE / 1000;

// M-wave 검출 유효성(신뢰도) 판정 파라미터.
// latency는 진단값으로만 남기고 유효성·피로 판정에는 사용하지 않는다.
const float MW_AMP_MIN = 80.0f;      // peak-to-peak 이보다 작으면 유발반응 아님(노이즈)

// ===== 적응형 자극 트리거 임계값 =====
// 고정 임계(MW_ARTIFACT_THRESHOLD)는 자극 스파이크가 작아지면(전극·세기 변화) 검출을
// 통째로 놓쳐 M-wave가 절반씩 빈다. 대신 '최근 자극 스파이크 크기'를 추적해 그 일부로
// 문턱을 자동 조절한다.  임계 = clamp( FLOOR, FRAC×최근스파이크EMA, MW_ARTIFACT_THRESHOLD )
//   - FLOOR : 이 밑으로는 안 내려감(자발 EMG·노이즈 오검출 방지)
//   - 상한  : 고정값(1000)을 넘지 않음(스파이크가 커도 기존만큼은 민감)
const float MW_ADAPT_FRAC = 0.4f;    // 스파이크 EMA 의 이 비율을 문턱으로
const float MW_ADAPT_FLOOR = 400.0f; // 문턱 하한
const float MW_ADAPT_ALPHA = 0.2f;   // EMA 갱신율 (0=고정, 1=즉시)
// 초기 EMA: 초기 문턱이 기존 고정값과 같도록 (FRAC×EMA0 = MW_ARTIFACT_THRESHOLD)
const float MW_ADAPT_EMA0 = (float)MW_ARTIFACT_THRESHOLD / MW_ADAPT_FRAC;

// ===== FES 자극 blanking =====
// 자극 검출 직후 이 시간(ms)만큼 표본을 RMS/MDF/ENV 계산에서 제외(직전 깨끗한 값으로 hold).
//
// 5ms 였을 때의 문제: 스파이크(0~1ms)만 걷어내고 M-wave(5~15ms)는 그대로 통과시켰다.
// M-wave 는 자발 EMG 보다 10배 이상 커서 RMS 를 지배한다 → 펌웨어 RMS 가 자발 EMG 가 아니라
// '유발반응의 대리지표'가 됐다. 유발반응은 피로에서 내려가는데 SPC 규칙은 RMS>UCL(올라가야
// 발동)이라, 진짜 피로일수록 발동하지 않는 구조였다(042118 실측 RMS −11.8%, 후보 0개).
//
// 16ms = 스파이크(0~1) + 증폭기 회복 + M-wave(5~15) 를 모두 제외.
// 남는 16~30ms 구간이 자발 EMG 만 있는 깨끗한 창이다(실측: 무부하 21.6 → 유부하 30.9, +43%).
// 실측 자극률 12.35/s 이므로 blanking 표본 비율은 16ms×12.35 ≈ 19.8% — 80% 는 보존된다.
// (기존 주석의 "25Hz 자극 = 펄스 간격 40ms" 는 틀렸다. 실측은 32.078Hz = 31.185ms 간격)
const int STIM_BLANK_MS = 16;
const uint32_t STIM_BLANK_SAMPLES = STIM_BLANK_MS * SAMPLE_RATE / 1000;

// ===== BLE 핸들 =====
NimBLECharacteristic* dataChar = nullptr;
NimBLECharacteristic* cmdChar  = nullptr;
NimBLECharacteristic* rawChar  = nullptr;   // RAW 4kHz 파형 스트리밍 (binary)
volatile bool deviceConnected = false;

// ===== ADC 버퍼 / 10Hz 메트릭 생성 =====
// 4kHz로 샘플링하되, CSV/BLE 메트릭은 ENV와 같은 100ms 간격(10Hz)으로 만든다.
// RMS는 최근 1622ms, MDF는 최근 FFT_SIZE(2048표본=512ms) 윈도우를 유지한다.
volatile int rawBuffer[RMS_WINDOW];
volatile int writeIdx = 0;                 // 다음 기록 위치 (RMS_WINDOW로 wrap)
volatile int windowCount = 0;              // 현재 RMS 윈도우에 들어있는 표본 수, 최대 RMS_WINDOW
volatile int64_t windowSum = 0;            // 최근 RMS_WINDOW(1622ms) centered 값 합
volatile int64_t windowSumSq = 0;          // 최근 RMS_WINDOW(1622ms) centered 값 제곱합
volatile bool bufferFilled = false;        // RMS_WINDOW(6488표본=1622ms)가 한 번이라도 채워졌는지

const int COMPUTE_INTERVAL = SAMPLE_RATE / 10;  // 400표본 @4kHz = 100ms → 10Hz
volatile int samplesSinceCompute = 0;      // 마지막 10Hz 계산 이후 누적 표본 수
volatile bool metricReady = false;         // COMPUTE_INTERVAL(400표본=100ms)마다 true → loop에서 10Hz 계산
int metricCycle = 0;                        // 10Hz 사이클 카운터 (10회=1초 → 느린 로직)

// 100ms 블록 대표값: CSV에서 EMG/ENV/RMS/MDF를 모두 같은 10Hz 시간축으로 보기 위한 값
volatile int blockCount = 0;
volatile int64_t blockRawSum = 0;
volatile int64_t blockCenteredSum = 0;
volatile int64_t blockAbsSum = 0;
volatile int blockPeakAbs = 0;
volatile int blockMinCentered = 32767;
volatile int blockMaxCentered = -32768;
volatile float latestRaw10Hz = 0;           // 100ms 평균 ADC 원값
volatile float latestEmg10Hz = 0;           // 100ms 평균 |centered|, CSV용 EMG 대표값
volatile float latestCenteredMean10Hz = 0;  // 100ms centered 평균, DC 흔들림 진단용
volatile int latestPeakAbs10Hz = 0;         // 100ms peak |centered|
volatile int latestMinCentered10Hz = 0;
volatile int latestMaxCentered10Hz = 0;

// 실시간 envelope (|raw - DC| 의 1차 IIR LPF, 4kHz로 갱신)
// alpha=0.0075 → 기존 1kHz alpha=0.03과 같은 약 5Hz 응답
volatile float envLPF = 0;
const float ENV_LPF_ALPHA = 0.0075f;

// FES blanking 용: 마지막으로 blanking 되지 않은(깨끗한) centered 값. hold 대체에 사용.
int lastCleanCentered = 0;

// ===== RAW 4kHz 파형 스트리밍 (바이너리, 전용 캐릭터리스틱) =====
// 매 샘플의 raw ADC를 100개(=25ms)씩 묶어 MTU-safe 바이너리 패킷으로 보낸다.
// 패킷 포맷 (little-endian):
//   [uint32 firstSampleIndex][uint16 count][int16 raw × count]
// firstSampleIndex = 세션 시작 후 첫 표본 인덱스. 폰에서 4kHz 시간축을 복원한다.
const int RAW_BATCH_SAMPLES = 100;                 // 25ms @4kHz, 206B로 MTU 247 이내
volatile int16_t rawBatchFill[RAW_BATCH_SAMPLES];  // 샘플링 태스크가 채우는 중인 블록
volatile int rawBatchFillCount = 0;
volatile uint32_t rawSampleCounter = 0;            // 세션 시작 후 누적 샘플 수
const int RAW_QUEUE_DEPTH = 8;                     // FFT 중 최대 200ms 송신 지연 흡수
volatile int16_t rawQueue[RAW_QUEUE_DEPTH][RAW_BATCH_SAMPLES];
volatile uint32_t rawQueueFirstIdx[RAW_QUEUE_DEPTH];
volatile int rawQueueHead = 0;
volatile int rawQueueTail = 0;
volatile int rawQueueCount = 0;

// ===== FFT 버퍼 =====
double vReal[FFT_SIZE];
double vImag[FFT_SIZE];
ArduinoFFT<double> FFT = ArduinoFFT<double>(vReal, vImag, FFT_SIZE, SAMPLE_RATE);

// ===== 히스토리 (선형회귀용) =====
float rmsHistory[HISTORY_SIZE];
float mdfHistory[HISTORY_SIZE];
int historyIdx = 0;
int historyCount = 0;

// ===== 시스템 상태 =====
bool systemRunning = false;
bool isStimulating = false;
bool completeParalysisProtocol = false;
unsigned long sessionStartedAtMs = 0;
int consecutiveCount = 0;
unsigned long stimStartTime = 0;
unsigned long lastNotifyMs = 0;
unsigned long fatigueDetectedAtMs = 0;
const unsigned long FATIGUE_LATCH_MS = 10000;   // fd=true를 10초간 유지
bool sendFullNext = true;   // 다음 송신을 "full"로 (1초마다 slope/state 등 포함)
bool sendRmsMdfNext = false; // 다음 송신에 rms/mdf 포함 (10Hz 갱신 시 set)

// ===== 수축 상태머신 =====
enum ContractionState { CS_REST = 0, CS_ONSET = 1, CS_SUSTAINED = 2 };
ContractionState contractState = CS_REST;
unsigned long contractStartMs = 0;
float contractPeakRMS = 0;
float prevRMS = 0;

const float CONTRACT_ACTIVE_RATIO = 1.2;       // baseline×1.2 초과 → 활성
const float DRMS_ONSET = 8.0;                  // 초당 RMS 증가량 임계 (onset)
const float DRMS_OFFSET = -8.0;                // 종료 임계
const unsigned long ONSET_TO_SUSTAINED_MS = 2000;
const unsigned long BURST_MAX_MS = 2000;
const unsigned long SUSTAINED_MIN_MS = 5000;

// 마지막 완료된 수축 정보 (UI 표시용)
char lastContractType = '-';   // 'b'=burst, 't'=transient, 's'=sustained
unsigned long lastContractDurMs = 0;
float lastContractPeak = 0;

// 카운터 (세션 누적, calibrate 시 리셋)
uint16_t burstCount = 0;
uint16_t transientCount = 0;
uint16_t sustainedCount = 0;

// ===== M-wave 상태 (자극 artifact triggered) =====
volatile uint32_t mwArtifactAtSample = 0;
volatile bool mwArtifactSeen = false;
volatile bool mwCapturing = false;
volatile int mwSampleCount = 0;
volatile float mwArtifactEMA = MW_ADAPT_EMA0;   // 최근 자극 스파이크 peak 의 EMA(적응형 문턱용)
volatile int mwArtifactPeak = 0;                // 현재 캡처 중 자극 스파이크 peak |centered|
volatile int mwSamples[MW_WINDOW_LEN + 4];     // 캡처 중인 버퍼 (ISR 전용)
// 완료된 캡처는 별도 버퍼로 옮긴다(이중 버퍼).
// MW_REFRACTORY_MS 를 25 로 낮추면 자극이 31ms 마다 잡히므로, 캡처가 닫힌 직후(창끝 28ms)
// 곧바로 다음 캡처가 열리며 mwSampleCount 를 0 으로 리셋한다. 단일 버퍼면 loop() 가 읽기
// 전에 지워져 M-wave 가 조용히 유실된다(n=0 → n>=5 실패). 닫는 순간 스냅샷을 떠서 분리한다.
volatile int mwSamplesRdy[MW_WINDOW_LEN + 4];  // 완료된 캡처 (loop() 가 읽음)
volatile int mwSampleCountRdy = 0;
volatile bool mwReady = false;                 // 캡처 완료 → loop()에서 메트릭 계산
float currentMwAmp = 0;                        // peak-to-peak (ADC counts)
float currentMwArea = 0;                       // Σ|sample| (정류 면적)
float currentMwLatency = 0;                    // artifact 후 peak까지 ms
bool currentMwValid = false;                   // 검출 신뢰도 판정 통과 여부 (SPC·baseline은 이것만 사용)
bool mwDirty = false;                          // 새 M-wave가 있어 다음 송신 포함
uint32_t mwCount = 0;                          // 세션 누적 M-wave 검출 수

// ===== 최신 계산값 =====
float currentRaw10Hz = 0;        // 100ms 평균 ADC 원값
float currentEmg10Hz = 0;        // 100ms 평균 |centered|
float currentCenteredMean10Hz = 0;
int   currentPeakAbs10Hz = 0;
int   currentMinCentered10Hz = 0;
int   currentMaxCentered10Hz = 0;
float currentRMS = 0;            // 최근 1초 sliding RMS, 10Hz 갱신
float currentMDF = 0;            // 최근 512ms MDF, 10Hz 갱신
bool  metricsValid = false;      // RMS 1초 윈도우가 채워진 뒤 true
float currentRMSSlope = 0;
float currentMDFSlope = 0;
bool  currentFatigueDetected = false;

float baselineRMS = 0;
bool  baselineReady = false;
float baselineRmsSum = 0;
int baselineRmsSampleCount = 0;
float rmsRatio = 1.0;
String muscleState = "idle";
String sessionMarker = "";

// ===== 관리도(SPC ControlChart) — 앱 Dart FatigueEngine 과 동일 =====
// 운동 초반(아직 안 지친 상태) 표본으로 mean·σ 를 잡고 UCL=mean+kσ, LCL=mean-kσ.
// RMS·MDF 는 8표본(=8초), M-wave 는 6표본(=버스트 6회) 으로 baseline 확정.
struct CChart {
  float samples[16];
  int   n = 0;
  int   baselineSamples = 8;
  float sigmaMult = 2.0f;
  bool  established = false;
  float mean = 0, sd = 0;
};
CChart rmsChart, mdfChart, mwAmpChart, mwAreaChart, mwLatChart;

void ccInit(CChart& c, int bs, float sm) {
  c.baselineSamples = bs; c.sigmaMult = sm;
  c.n = 0; c.established = false; c.mean = 0; c.sd = 0;
}
void ccReset(CChart& c) { c.n = 0; c.established = false; c.mean = 0; c.sd = 0; }
void ccIngest(CChart& c, float v) {
  if (c.established) return;
  if (c.n < 16) c.samples[c.n++] = v;
  if (c.n >= c.baselineSamples) {
    float s = 0; for (int i = 0; i < c.n; i++) s += c.samples[i];
    c.mean = s / c.n;
    float var = 0;
    for (int i = 0; i < c.n; i++) { float d = c.samples[i] - c.mean; var += d * d; }
    c.sd = sqrtf(var / c.n);
    c.established = true;
  }
}
bool ccAbove(CChart& c, float v) { return c.established && v > c.mean + c.sigmaMult * c.sd; }
bool ccBelow(CChart& c, float v) { return c.established && v < c.mean - c.sigmaMult * c.sd; }

void resetFatigueCharts() {
  ccReset(rmsChart); ccReset(mdfChart);
  ccReset(mwAmpChart); ccReset(mwAreaChart); ccReset(mwLatChart);
}

// ===== 타이머 =====
hw_timer_t* sampleTimer = nullptr;
portMUX_TYPE timerMux = portMUX_INITIALIZER_UNLOCKED;
TaskHandle_t samplingTaskHandle = nullptr;

// 함수 선언
void triggerStimulation(bool on);
void handleCommand(ArduinoJson::JsonDocument& doc);
void updateContractionState();
void samplingTask(void* param);
float calculateRMS(int64_t sum, int64_t sumSq, int n);
float calculateMDF(int localWriteIdx);
void sendRawBatch();

// ============================================================
// 0.25ms 타이머 ISR — analogRead는 IRAM-safe가 아니므로
// ISR에서는 샘플링 태스크만 깨우고 실제 ADC는 태스크에서 수행.
// ============================================================
void IRAM_ATTR onSampleTimer() {
  BaseType_t higherPriorityTaskWoken = pdFALSE;
  vTaskNotifyGiveFromISR(samplingTaskHandle, &higherPriorityTaskWoken);
  if (higherPriorityTaskWoken == pdTRUE) {
    portYIELD_FROM_ISR();
  }
}

// ============================================================
// ADC 샘플링 태스크 — 코어 1 고정, 고우선순위
// ISR notify를 받아 RAW 채널만 read.
// (MyoWare 2.0은 SIG 핀으로 RAW or ENV 둘 중 하나만 출력 →
//  RAW만 받아서 RMS/MDF 모두 소프트웨어로 산출)
// ============================================================
void samplingTask(void* /*param*/) {
  for (;;) {
    // pdFALSE는 대기 중인 tick을 하나씩 소비한다. 4kHz에서 잠깐 스케줄링이 밀려도
    // 누적 notify를 한 번에 지워 RAW 표본을 조용히 잃지 않게 한다.
    ulTaskNotifyTake(pdFALSE, portMAX_DELAY);

    int raw = analogRead(PIN_EMG_RAW);
    if (dcCalibrating) {
      dcCalibrationSum += raw;
      dcCalibrationCount++;
      if (dcCalibrationCount >= (uint32_t)(DC_CALIBRATION_MS * SAMPLE_RATE / 1000)) {
        dcOffset = (int)((dcCalibrationSum + dcCalibrationCount / 2) /
                         dcCalibrationCount);
        dcCalibrating = false;
      }
    }
    int centered = raw - dcOffset;
    int absVal = centered < 0 ? -centered : centered;
    const uint32_t sampleIndex = rawSampleCounter;

    // ===== M-wave: 자극 artifact 감지 + 윈도우 캡처 (원신호 기준) =====
    // FES는 외부에서 수동 제어 → ESP는 자극 켜짐을 모르므로, 세션 동작 중
    // (systemRunning)이면 항상 artifact를 탐지한다. refractory 경과 후 큰
    // 스파이크가 들어오면 artifact로 간주, 5~30ms 동안 centered 샘플 수집.
    // M-wave 측정은 '진짜' 원신호로 해야 하므로 blanking 이전에 수행한다.
    {
      // 적응형 문턱: 최근 스파이크 EMA×FRAC, 단 [FLOOR, 고정값] 으로 clamp.
      float mwThresh = MW_ADAPT_FRAC * mwArtifactEMA;
      if (mwThresh < MW_ADAPT_FLOOR) mwThresh = MW_ADAPT_FLOOR;
      if (mwThresh > (float)MW_ARTIFACT_THRESHOLD) mwThresh = (float)MW_ARTIFACT_THRESHOLD;

      if (systemRunning && !mwCapturing &&
          (float)absVal > mwThresh &&
          (!mwArtifactSeen ||
           sampleIndex - mwArtifactAtSample > MW_REFRACTORY_SAMPLES)) {
        mwArtifactAtSample = sampleIndex;
        mwArtifactSeen = true;
        mwCapturing = true;
        mwSampleCount = 0;
        mwArtifactPeak = absVal;              // 스파이크 peak 추적 시작
      }
      if (mwCapturing) {
        uint32_t since = sampleIndex - mwArtifactAtSample;
        if (absVal > mwArtifactPeak) mwArtifactPeak = absVal;   // dead-zone 포함 스파이크 peak
        if (since >= (uint32_t)MW_WINDOW_START_SAMPLES &&
            since <= (uint32_t)MW_WINDOW_END_SAMPLES) {
          if (mwSampleCount < MW_WINDOW_LEN) {
            mwSamples[mwSampleCount++] = centered;
          }
        } else if (since > (uint32_t)MW_WINDOW_END_SAMPLES) {
          // 완료된 캡처를 ready 버퍼로 옮긴다. 다음 자극이 31ms 만에 와서 mwSamples 를
          // 덮어써도 loop() 가 읽을 값은 보존된다.
          for (int i = 0; i < mwSampleCount && i < MW_WINDOW_LEN + 4; i++) {
            mwSamplesRdy[i] = mwSamples[i];
          }
          mwSampleCountRdy = mwSampleCount;
          mwCapturing = false;
          mwReady = true;
          // 이번 자극 스파이크 peak 로 EMA 갱신 → 다음 문턱이 실제 크기를 따라감
          mwArtifactEMA = MW_ADAPT_ALPHA * (float)mwArtifactPeak +
                          (1.0f - MW_ADAPT_ALPHA) * mwArtifactEMA;
        }
      }
    }

    // ===== FES 자극 blanking =====
    // 자극 검출 직후 STIM_BLANK_MS 동안의 표본은 거대한 자극 스파이크라
    // RMS/MDF/SMR/ENV 를 오염시킨다. 그 구간은 '직전 깨끗한 값'으로 대체(hold)해
    // 계산 버퍼에 넣는다. → RMS/MDF 가 자극에 오염되지 않는다.
    // (raw 4kHz 로그와 M-wave 검출은 위에서 진짜 원신호로 이미 처리함)
    bool stimBlank = systemRunning && mwArtifactSeen &&
             (sampleIndex - mwArtifactAtSample) < STIM_BLANK_SAMPLES;
    int procCentered;
    if (stimBlank) {
      procCentered = lastCleanCentered;       // hold (자극 구간 대체)
    } else {
      procCentered = centered;
      lastCleanCentered = centered;           // 깨끗한 값 갱신
    }
    int procAbs = procCentered < 0 ? -procCentered : procCentered;

    // 실시간 envelope (정류 + IIR LPF) — blanking 적용값으로 갱신
    envLPF = ENV_LPF_ALPHA * (float)procAbs + (1.0f - ENV_LPF_ALPHA) * envLPF;

    // 슬라이딩 윈도우 + 100ms 블록 통계
    portENTER_CRITICAL(&timerMux);

    // 1초 RMS 윈도우: 오래된 표본을 빼고 새 표본을 더해 running sum 유지 (blanking 적용)
    int old = rawBuffer[writeIdx];
    rawBuffer[writeIdx] = procCentered;       // FFT(MDF/SMR)도 이 버퍼를 쓰므로 blanking 반영
    if (windowCount < RMS_WINDOW) {
      windowCount++;
      windowSum += procCentered;
      windowSumSq += (int64_t)procCentered * procCentered;
    } else {
      windowSum += (int64_t)procCentered - old;
      windowSumSq += (int64_t)procCentered * procCentered - (int64_t)old * old;
    }

    writeIdx++;
    if (writeIdx >= RMS_WINDOW) writeIdx = 0;
    bufferFilled = (windowCount >= RMS_WINDOW);

    // 100ms 블록 대표값. raw 평균/RAW 4kHz 로그는 '진짜' 원신호,
    // EMG/peak/centered 통계는 blanking 적용값으로 누적.
    blockRawSum += raw;                        // 진짜 raw 평균 (진단용)
    blockCenteredSum += procCentered;
    blockAbsSum += procAbs;
    if (procAbs > blockPeakAbs) blockPeakAbs = procAbs;
    if (procCentered < blockMinCentered) blockMinCentered = procCentered;
    if (procCentered > blockMaxCentered) blockMaxCentered = procCentered;
    rawBatchFill[rawBatchFillCount++] = (int16_t)raw;
    blockCount++;
    rawSampleCounter++;

    // 100표본(25ms) RAW 블록 완성 → MTU-safe 송신 버퍼로 스냅샷.
    if (rawBatchFillCount >= RAW_BATCH_SAMPLES) {
      if (systemRunning && rawQueueCount < RAW_QUEUE_DEPTH) {
        for (int i = 0; i < RAW_BATCH_SAMPLES; i++) {
          rawQueue[rawQueueTail][i] = rawBatchFill[i];
        }
        rawQueueFirstIdx[rawQueueTail] = rawSampleCounter - RAW_BATCH_SAMPLES;
        rawQueueTail = (rawQueueTail + 1) % RAW_QUEUE_DEPTH;
        rawQueueCount++;
      }
      rawBatchFillCount = 0;
    }

    samplesSinceCompute++;
    if (samplesSinceCompute >= COMPUTE_INTERVAL) {
      int n = blockCount > 0 ? blockCount : 1;
      latestRaw10Hz = (float)blockRawSum / n;
      latestEmg10Hz = (float)blockAbsSum / n;
      latestCenteredMean10Hz = (float)blockCenteredSum / n;
      latestPeakAbs10Hz = blockPeakAbs;
      latestMinCentered10Hz = blockMinCentered;
      latestMaxCentered10Hz = blockMaxCentered;

      // 다음 100ms 블록 시작
      blockRawSum = 0;
      blockCenteredSum = 0;
      blockAbsSum = 0;
      blockPeakAbs = 0;
      blockMinCentered = 32767;
      blockMaxCentered = -32768;
      blockCount = 0;

      samplesSinceCompute = 0;
      metricReady = true;          // 100ms마다 RMS/MDF 재계산 신호
    }

    portEXIT_CRITICAL(&timerMux);
  }
}

// ============================================================
// BLE 콜백 (NimBLE 2.x API)
// ============================================================
class ServerCallbacks : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer* pServer, NimBLEConnInfo& connInfo) override {
    deviceConnected = true;
    Serial.printf("✅ BLE 연결: %s\n", connInfo.getAddress().toString().c_str());
    // iPhone과 큰 MTU 협상 시도
    pServer->setDataLen(connInfo.getConnHandle(), 251);
  }
  void onDisconnect(NimBLEServer* pServer, NimBLEConnInfo& connInfo, int reason) override {
    deviceConnected = false;
    Serial.printf("❌ BLE 끊김 (reason=%d) → 재광고\n", reason);
    // 안전: 끊기면 FES 즉시 중단
    if (isStimulating) triggerStimulation(false);
    // 자동 재광고
    NimBLEDevice::getAdvertising()->start();
  }
};

class CmdCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* pCharacteristic, NimBLEConnInfo& connInfo) override {
    std::string value = pCharacteristic->getValue();
    if (value.empty()) return;

    ArduinoJson::JsonDocument doc;
    ArduinoJson::DeserializationError err = ArduinoJson::deserializeJson(doc, value.c_str());
    if (err) {
      Serial.printf("⚠️ JSON parse 실패: %s\n", err.c_str());
      return;
    }
    handleCommand(doc);
  }
};

// ============================================================
// SETUP
// ============================================================
void setup() {
  Serial.begin(115200);
  delay(1000);
  Serial.println("\n=== EMG-FES Controller (BLE) ===");

  // GPIO 초기화
  pinMode(PIN_STATUS_LED, OUTPUT);
  pinMode(PIN_MASSAGER_ON_OFF, OUTPUT);
  pinMode(PIN_MASSAGER_MODE, OUTPUT);
  pinMode(PIN_MASSAGER_UP, OUTPUT);
  pinMode(PIN_MASSAGER_DOWN, OUTPUT);
  digitalWrite(PIN_MASSAGER_ON_OFF, LOW);
  digitalWrite(PIN_MASSAGER_MODE, LOW);
  digitalWrite(PIN_MASSAGER_UP, LOW);
  digitalWrite(PIN_MASSAGER_DOWN, LOW);

  // 관리도 초기화 — RMS/MDF 8표본, M-wave 6표본, ±2σ
  ccInit(rmsChart, 8, 2.0f);
  ccInit(mdfChart, 8, 2.0f);
  ccInit(mwAmpChart, 6, 2.0f);
  ccInit(mwAreaChart, 6, 2.0f);
  ccInit(mwLatChart, 6, 2.0f);

  analogReadResolution(12);

  // BLE 초기화
  setupBLE();

  // ADC 샘플링 태스크 (코어 1, BLE는 코어 0에서 도므로 분리)
  xTaskCreatePinnedToCore(
    samplingTask,
    "emg_sampling",
    4096,
    nullptr,
    configMAX_PRIORITIES - 1,
    &samplingTaskHandle,
    1
  );

  // 4kHz ADC 타이머 (ESP32 Arduino core 2.x/3.x 호환)
#if defined(ESP_ARDUINO_VERSION_MAJOR) && ESP_ARDUINO_VERSION_MAJOR >= 3
  sampleTimer = timerBegin(1000000);                      // 1MHz tick (1us 해상도)
  timerAttachInterrupt(sampleTimer, &onSampleTimer);
  timerAlarm(sampleTimer, 250, true, 0);                  // 250us=4kHz, autoreload
#else
  sampleTimer = timerBegin(0, 80, true);                  // 80MHz / 80 = 1MHz
  timerAttachInterrupt(sampleTimer, &onSampleTimer, true);
  timerAlarmWrite(sampleTimer, 250, true);                // 250us=4kHz, autoreload
  timerAlarmEnable(sampleTimer);
#endif

  digitalWrite(PIN_STATUS_LED, HIGH);
  Serial.println("=== 준비 완료 (BLE 광고 중) ===\n");
}

// ============================================================
// BLE 셋업
// ============================================================
void setupBLE() {
  NimBLEDevice::init(BLE_DEVICE_NAME);
  NimBLEDevice::setPower(ESP_PWR_LVL_P9);    // 최대 송신 출력 (+9dBm)
  NimBLEDevice::setMTU(247);                 // iPhone 자동 협상 가능 (실효 244B/패킷)

  NimBLEServer* pServer = NimBLEDevice::createServer();
  pServer->setCallbacks(new ServerCallbacks());

  NimBLEService* pService = pServer->createService(SERVICE_UUID);

  // DATA characteristic (ESP32 → Phone, notify)
  dataChar = pService->createCharacteristic(
    CHAR_DATA_UUID,
    NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY
  );

  // RAW characteristic (ESP32 → Phone, notify) — 4kHz 파형 바이너리 스트림
  rawChar = pService->createCharacteristic(
    CHAR_RAW_UUID,
    NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY
  );

  // CMD characteristic (Phone → ESP32, write)
  cmdChar = pService->createCharacteristic(
    CHAR_CMD_UUID,
    NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR
  );
  cmdChar->setCallbacks(new CmdCallbacks());

  pService->start();

  // Advertising
  NimBLEAdvertising* pAdv = NimBLEDevice::getAdvertising();
  pAdv->addServiceUUID(SERVICE_UUID);
  pAdv->setName(BLE_DEVICE_NAME);
  pAdv->enableScanResponse(true);
  pAdv->start();

  Serial.printf("✅ BLE 시작: name=%s\n", BLE_DEVICE_NAME);
  Serial.printf("   Service: %s\n", SERVICE_UUID);
  Serial.printf("   Data   : %s (notify)\n", CHAR_DATA_UUID);
  Serial.printf("   Cmd    : %s (write)\n", CHAR_CMD_UUID);
}

// ============================================================
// LOOP
// ============================================================
void loop() {
  // 연결 상태 LED (연결 시 ON, 미연결 시 1Hz 블링크)
  digitalWrite(PIN_STATUS_LED, deviceConnected ? HIGH : ((millis() / 500) % 2));

  if (metricReady) {
    // samplingTask가 만든 100ms 대표값과 RMS running sum을 한 번에 스냅샷
    int localWriteIdx;
    int localWindowCount;
    int64_t localWindowSum;
    int64_t localWindowSumSq;

    portENTER_CRITICAL(&timerMux);
    metricReady = false;
    localWriteIdx = writeIdx;
    localWindowCount = windowCount;
    localWindowSum = windowSum;
    localWindowSumSq = windowSumSq;
    currentRaw10Hz = latestRaw10Hz;
    currentEmg10Hz = latestEmg10Hz;
    currentCenteredMean10Hz = latestCenteredMean10Hz;
    currentPeakAbs10Hz = latestPeakAbs10Hz;
    currentMinCentered10Hz = latestMinCentered10Hz;
    currentMaxCentered10Hz = latestMaxCentered10Hz;
    portEXIT_CRITICAL(&timerMux);

    // ===== 10Hz: ENV와 같은 시간축으로 RMS/MDF 재계산 =====
    // RMS는 최근 1초 sliding window, MDF는 최근 512ms FFT window.
    bool rmsReady = (localWindowCount >= RMS_WINDOW);
    bool mdfReady = (localWindowCount >= FFT_SIZE);

    if (rmsReady) {
      currentRMS = calculateRMS(localWindowSum, localWindowSumSq, localWindowCount);
    }
    if (mdfReady) {
      currentMDF = calculateMDF(localWriteIdx);
    }
    // calculateMDF 는 실패 시 NaN 을 돌려준다. NaN 이 그대로 흘러가면 ccIngest 가 관리도의
    // mean/sd 를 NaN 으로 만들어 그 세션 내내 복구되지 않는다(판정이 조용히 죽음).
    // 여기서 막는다 — MDF 가 유한할 때만 히스토리·관리도·판정을 돌린다.
    // (MDF 실패는 대역 전력이 0 인 경우뿐이라 그때는 RMS 도 무의미하다)
    metricsValid = rmsReady && mdfReady && isfinite(currentMDF);
    sendRmsMdfNext = true;          // 다음 100ms BLE 행에 rms/mdf를 반드시 포함

    // ===== 1Hz: 느린 로직 (히스토리·관리도·판정·상태머신) =====
    // 피로 판정과 baseline은 초 단위 표본 기준으로 유지한다.
    if (metricsValid) {
      metricCycle++;
      if (metricCycle >= 10) {
        metricCycle = 0;

        // 히스토리 추가
        rmsHistory[historyIdx] = currentRMS;
        mdfHistory[historyIdx] = currentMDF;
        historyIdx = (historyIdx + 1) % HISTORY_SIZE;
        if (historyCount < HISTORY_SIZE) historyCount++;

        // slope 는 표시용으로만 계산 (30초치 모이면 갱신) — 판정엔 미사용
        if (historyCount >= 30) {
          currentRMSSlope = calculateSlopePercent(rmsHistory, historyCount, true);
          currentMDFSlope = calculateSlopePercent(mdfHistory, historyCount, true);
        }

        const bool baselineWindowOpen = systemRunning &&
            (millis() - sessionStartedAtMs >= BASELINE_DELAY_MS);

        // ---- 관리도 baseline 학습 (준비운동 30초 이후 표본만) ----
        if (baselineWindowOpen && !completeParalysisProtocol) {
          ccIngest(rmsChart, currentRMS);
          ccIngest(mdfChart, currentMDF);
        }

        // 완전마비 프로토콜에서는 유발파형에 오염되는 RMS/MDF를 판정에 쓰지 않는다.
        bool rmsHigh = systemRunning && !completeParalysisProtocol &&
                       ccAbove(rmsChart, currentRMS);
        bool mdfLow  = systemRunning && !completeParalysisProtocol &&
                       ccBelow(mdfChart, currentMDF);
        bool rmsMdfGroup = rmsHigh && mdfLow;
        bool mwGroup = currentMwValid &&
                       mwAmpChart.established && mwAreaChart.established &&
                       ccBelow(mwAmpChart, currentMwAmp) &&
                       ccBelow(mwAreaChart, currentMwArea);
        bool fatigueCondition = rmsMdfGroup || mwGroup;

        if (systemRunning && fatigueCondition) {
          consecutiveCount++;
          if (consecutiveCount >= CONSECUTIVE_TRIGGER && !currentFatigueDetected) {
            Serial.printf("⚠️ 근피로 감지! [%s] RMS %.0f(UCL %.0f) MDF %.0f(LCL %.0f)\n",
                          rmsMdfGroup ? "RMS·MDF" : "M-wave",
                          currentRMS, rmsChart.mean + rmsChart.sigmaMult * rmsChart.sd,
                          currentMDF, mdfChart.mean - mdfChart.sigmaMult * mdfChart.sd);
            currentFatigueDetected = true;
            fatigueDetectedAtMs = millis();
            sendFullNext = true;
            // 자동 정지 없음 — 피로는 '기록'만 하고 자극은 끄지 않는다.
            // 정지는 오직 사용자의 stop 명령으로만.
            //
            // 왜: 이 판정(rmsMdfGroup || mwGroup)은 실측에서 신뢰할 수 없다.
            //  - rmsMdfGroup: 펌웨어 RMS 는 자발 EMG 가 아니라 유발반응의 대리지표라
            //    피로에서 '내려간다'. 규칙은 RMS>UCL(올라가야 발동)이라 방향이 반대다.
            //    실측 4세션 정답률 1/4, 진짜 피로 세션(042118)에서 후보 0개.
            //  - mwGroup: 정규화 안 된 생 M-wave 를 본다. 전극 드리프트만으로도 내려가
            //    위양성이 난다(033307: 자극 -19.5% 따라 M-wave -19.1%, 근육은 멀쩡).
            //    올바른 지표는 M-wave ÷ 자극스파이크(R)인데 펌웨어는 스파이크를 안 낸다.
            //
            // 자동 정지가 세션을 중간에 끊으면 그 데이터는 못 쓴다. 판정이 옳아질 때까지
            // 끊지 않는다 — 자극기는 사용자가 손으로도 즉시 끌 수 있다.
          }
        } else {
          consecutiveCount = 0;
        }

        if (currentFatigueDetected &&
            (millis() - fatigueDetectedAtMs > FATIGUE_LATCH_MS)) {
          currentFatigueDetected = false;
        }

        // 근활성 상태 표시용 RMS baseline도 30초 이후 새 표본만 수집한다.
        if (baselineWindowOpen && !baselineReady) {
          baselineRmsSum += currentRMS;
          baselineRmsSampleCount++;
          if (baselineRmsSampleCount >= BASELINE_SAMPLES) {
            baselineRMS = baselineRmsSum / baselineRmsSampleCount;
            baselineReady = true;
            Serial.printf("✅ Baseline RMS: %.1f (t>=30s, %d samples)\n",
                          baselineRMS, baselineRmsSampleCount);
          }
        }

        // 상태 분류
        if (!systemRunning) {
          muscleState = "idle";
          rmsRatio = 1.0;
        } else if (!baselineReady) {
          muscleState = "calibrating";
          rmsRatio = 1.0;
        } else {
          rmsRatio = (baselineRMS > 0.01) ? (currentRMS / baselineRMS) : 1.0;
          if (currentFatigueDetected)              muscleState = "fatigue";
          else if (rmsRatio > MUSCLE_HIGH_RATIO)   muscleState = "high";
          else if (rmsRatio < MUSCLE_LOW_RATIO)    muscleState = "low";
          else                                     muscleState = "normal";
        }

        updateContractionState();
        sendFullNext = true;
      }
    }
  }

  // ===== M-wave 메트릭 계산 (sampling task가 mwReady=true 신호) =====
  if (mwReady) {
    portENTER_CRITICAL(&timerMux);
    mwReady = false;
    int n = mwSampleCountRdy;                  // 진행 중인 캡처가 아니라 '완료된' 캡처
    int snapshot[MW_WINDOW_LEN + 4];
    for (int i = 0; i < n && i < MW_WINDOW_LEN + 4; i++) {
      snapshot[i] = mwSamplesRdy[i];
    }
    portEXIT_CRITICAL(&timerMux);

    if (n >= 5) {
      int mn = snapshot[0], mx = snapshot[0], peakIdx = 0;
      long absSum = 0;
      for (int i = 0; i < n; i++) {
        int v = snapshot[i];
        if (v < mn) mn = v;
        if (v > mx) { mx = v; peakIdx = i; }
        absSum += (v < 0 ? -v : v);
      }
      currentMwAmp = (float)(mx - mn);
      // 면적은 ADC·ms 단위를 유지하고 latency는 0.25ms 해상도로 환산한다.
      currentMwArea = (float)absSum * 1000.0f / SAMPLE_RATE;
      currentMwLatency = (float)(MW_WINDOW_START_SAMPLES + peakIdx) *
             1000.0f / SAMPLE_RATE;
      // latency는 진단/CSV에만 남기고 유효성은 진폭 노이즈 게이트로만 판정한다.
      currentMwValid = currentMwAmp >= MW_AMP_MIN;
      mwDirty = true;
      mwCount++;
      // 관리도 baseline 학습 — 준비운동 30초 이후의 유효 M-wave만.
      if (systemRunning && currentMwValid &&
          (millis() - sessionStartedAtMs >= BASELINE_DELAY_MS)) {
        ccIngest(mwAmpChart, currentMwAmp);
        ccIngest(mwAreaChart, currentMwArea);
        ccIngest(mwLatChart, currentMwLatency);
      }
    }
  }

  // BLE 송신은 100ms마다. raw/emg/env/rms/mdf 모두 같은 10Hz 행으로 송신.
  sendDataUpdate();

  // RAW 4kHz 파형 바이너리 패킷 송신 (25ms마다 100표본씩, 전용 캐릭터리스틱).
  sendRawBatch();

  // FES 타임아웃 안전장치
  if (isStimulating && (millis() - stimStartTime > STIM_TIMEOUT_MS)) {
    Serial.println("⏰ 자극 시간 초과 → OFF");
    triggerStimulation(false);
  }

  delay(1);   // BLE 스택 처리 양보
}

// ============================================================
// 명령 처리 (BLE write로 수신)
// ============================================================
void handleCommand(ArduinoJson::JsonDocument& doc) {
  String cmd = doc["cmd"].as<String>();
  Serial.printf("📥 cmd: %s\n", cmd.c_str());

  if (cmd == "start") {
    // DC 평균에 종료 펄스나 남은 자극이 섞이지 않도록 먼저 확실히 끈다.
    triggerStimulation(false);
    systemRunning = true;
    completeParalysisProtocol = doc["category"].as<String>() == "C";
    sessionStartedAtMs = millis();
    dcOffset = DC_OFFSET_FALLBACK;
    dcCalibrationSum = 0;
    dcCalibrationCount = 0;
    dcCalibrating = true;
    consecutiveCount = 0;
    metricCycle = 0;           // 1Hz 느린 로직 사이클을 세션 시작에 정렬
    historyIdx = 0;
    historyCount = 0;
    currentFatigueDetected = false;
    fatigueDetectedAtMs = 0;
    currentRMSSlope = 0;
    currentMDFSlope = 0;
    baselineReady = false;
    baselineRMS = 0;
    baselineRmsSum = 0;
    baselineRmsSampleCount = 0;
    rmsRatio = 1.0;
    envLPF = 0;
    lastCleanCentered = 0;      // FES blanking hold 값 리셋
    metricsValid = false;
    currentRMS = 0;
    currentMDF = 0;
    // 10Hz 블록/윈도우 리셋
    portENTER_CRITICAL(&timerMux);
    writeIdx = 0;
    windowCount = 0;
    windowSum = 0;
    windowSumSq = 0;
    bufferFilled = false;
    samplesSinceCompute = 0;
    metricReady = false;
    blockCount = 0;
    blockRawSum = blockCenteredSum = blockAbsSum = 0;
    blockPeakAbs = 0;
    blockMinCentered = 32767;
    blockMaxCentered = -32768;
    for (int i = 0; i < RMS_WINDOW; i++) rawBuffer[i] = 0;
    // RAW 4kHz 스트리밍 상태 리셋 — 인덱스를 세션 시작에 0으로 정렬
    rawSampleCounter = 0;
    rawBatchFillCount = 0;
    rawQueueHead = 0;
    rawQueueTail = 0;
    rawQueueCount = 0;
    portEXIT_CRITICAL(&timerMux);
    // M-wave 카운터/상태 리셋
    mwCount = 0;
    mwCapturing = false;
    mwSampleCount = 0;
    mwSampleCountRdy = 0;
    mwReady = false;
    mwDirty = false;
    mwArtifactAtSample = 0;
    mwArtifactSeen = false;
    mwArtifactEMA = MW_ADAPT_EMA0;   // 적응형 문턱 초기화 (초기 문턱=기존 고정값)
    mwArtifactPeak = 0;
    currentMwAmp = 0;
    currentMwArea = 0;
    currentMwLatency = 0;
    currentMwValid = false;
    resetFatigueCharts();          // 관리도 baseline 재학습
    muscleState = "calibrating";
    // 수축 상태머신 리셋
    contractState = CS_REST;
    contractStartMs = 0;
    contractPeakRMS = 0;
    prevRMS = 0;
    burstCount = transientCount = sustainedCount = 0;
    lastContractType = '-';
    lastContractDurMs = 0;
    lastContractPeak = 0;
    sessionMarker = "session_start";
    sendFullNext = true;   // 다음 송신은 리셋된 상태값 전부 포함
    Serial.printf("→ 시작 (DC %d초 캘리브레이션, baseline 30초 이후, protocol=%s)\n",
            DC_CALIBRATION_MS / 1000,
            completeParalysisProtocol ? "complete/M-wave" : "voluntary/mixed");
  }
  else if (cmd == "stop") {
    systemRunning = false;
    sessionMarker = "session_stop";
    Serial.println("→ 정지");
    triggerStimulation(false);
  }
  else if (cmd == "emergency") {
    systemRunning = false;
    sessionMarker = "emergency";
    Serial.println("🛑 비상정지");
    triggerStimulation(false);
  }
  else if (cmd == "marker") {
    sessionMarker = doc["label"].as<String>();
    Serial.printf("📍 마커: %s\n", sessionMarker.c_str());
  }
  else if (cmd == "calibrate") {
    historyIdx = 0;
    historyCount = 0;
    consecutiveCount = 0;
    baselineReady = false;
    baselineRMS = 0;
    baselineRmsSum = 0;
    baselineRmsSampleCount = 0;
    sessionStartedAtMs = millis();
    dcOffset = DC_OFFSET_FALLBACK;
    dcCalibrationSum = 0;
    dcCalibrationCount = 0;
    dcCalibrating = true;
    rmsRatio = 1.0;
    resetFatigueCharts();          // 관리도 baseline 재학습
    muscleState = systemRunning ? "calibrating" : "idle";
    // 수축 상태머신도 리셋
    contractState = CS_REST;
    contractStartMs = 0;
    contractPeakRMS = 0;
    prevRMS = 0;
    burstCount = transientCount = sustainedCount = 0;
    lastContractType = '-';
    lastContractDurMs = 0;
    lastContractPeak = 0;
    sendFullNext = true;
    Serial.println("→ 캘리브레이션 (베이스라인 + 수축 카운터 리셋)");
  }
  else if (cmd == "set_thresholds") {
    RMS_THRESHOLD = doc["rms"].as<float>();
    MDF_THRESHOLD = doc["mdf"].as<float>();
    Serial.printf("→ 임계값: RMS +%.1f%%, MDF %.1f%%\n", RMS_THRESHOLD, MDF_THRESHOLD);
  }
  else if (cmd == "trigger_stim") {
    bool on = doc["on"].as<bool>();
    triggerStimulation(on);
  }
  else {
    Serial.printf("⚠️ 알 수 없는 명령: %s\n", cmd.c_str());
  }
}

// ============================================================
// 마사지기 제어 (PC817 + IRLZ44N → HV-F022-V)
// ============================================================
void triggerStimulation(bool on) {
  if (on && !isStimulating) {
    digitalWrite(PIN_MASSAGER_ON_OFF, HIGH);
    delay(150);
    digitalWrite(PIN_MASSAGER_ON_OFF, LOW);
    isStimulating = true;
    stimStartTime = millis();
    Serial.println("🔌 마사지기 ON");
  }
  else if (!on && isStimulating) {
    digitalWrite(PIN_MASSAGER_ON_OFF, HIGH);
    delay(2000);   // long-press로 전원 OFF
    digitalWrite(PIN_MASSAGER_ON_OFF, LOW);
    isStimulating = false;
    Serial.println("🔌 마사지기 OFF (2s long-press)");
  }
}

// ============================================================
// RMS 계산 (RAW 1초치, 평균 자동 제거)
// DC_OFFSET이 정확하지 않아도 흡수되도록 윈도우 평균을 빼고 RMS.
// ============================================================
float calculateRMS(int64_t sum, int64_t sumSq, int n) {

  if (n <= 0) return 0;

  // 창 평균을 빼서 RMS를 계산(= 표본 표준편차). 고정 DC_OFFSET이 실제와 어긋나거나
  // 전극 드리프트가 있어도 창별 DC를 자동 흡수한다(MDF의 창평균 제거와 동일 취지).
  double mean = (double)sum / n;
  double meanSq = (double)sumSq / n;
  double variance = meanSq - mean * mean;
  if (variance < 0) variance = 0;      // 부동소수 오차로 음수 되는 것 방지

  double rms = sqrt(variance);

  static int diagCnt = 0;

  if (++diagCnt >= 10) {
    diagCnt = 0;

    Serial.printf(
      "[DIAG] raw100=%.0f emg100=%.1f cMean100=%.1f cMin=%d cMax=%d peak100=%d | RMS=%.1f MDF=%.1f ENV=%.1f\n",
      currentRaw10Hz,
      currentEmg10Hz,
      currentCenteredMean10Hz,
      currentMinCentered10Hz,
      currentMaxCentered10Hz,
      currentPeakAbs10Hz,
      rms,
      currentMDF,
      envLPF
    );
  }

  return (float)rms;
}

// ============================================================
// MDF 계산 (RAW 핀 FFT)
// ============================================================
// MDF 계산에서 제외할 대역:
//  (1) 60Hz 전원 노이즈 + 하모닉(120/180Hz)
//  (2) FES 자극 배음 — 32.078Hz 의 정수배 (64·96·128·…·449Hz)
//
// (2)가 없으면 MDF 는 근육이 아니라 자극을 잰다. 실측(042118 60초 FFT): 20~450Hz 대역
// 전력의 81.1% 가 자극 배음이다. blanking 으로도 안 없어진다 — M-wave 가 31ms 마다 반복되는
// 것 자체가 32.078Hz 주기성이고, hold 방식 blanking 은 오히려 31ms 주기 계단 함수를 새로 만든다.
//
// F0 = 32.078: ISI '평균' 31.185ms 에서 나온 값. '중앙값' 31ms 로 1000/31=32.258 을 쓰면
// 오차 0.182×k 라 k=14 에서 2.55Hz 어긋나 ±2Hz 노치가 놓친다(노치 효과 81.1%→68.9%).
static const float MDF_NOTCH_HZ[] = {60.0f, 120.0f, 180.0f};
static const float MDF_NOTCH_BW = 2.0f;   // ±2Hz bin 제거
static const float STIM_F0_HZ = 32.078f;  // 실측 자극 기본주파수 (= 1000/31.185ms)
static const int   STIM_HARMONIC_MAX = 14;// 450Hz 까지 (32.078×14 = 449.1)
static inline bool mdfNotched(float freqHz) {
  for (int k = 0; k < 3; k++) {
    if (freqHz >= MDF_NOTCH_HZ[k] - MDF_NOTCH_BW &&
        freqHz <= MDF_NOTCH_HZ[k] + MDF_NOTCH_BW) return true;
  }
  for (int k = 1; k <= STIM_HARMONIC_MAX; k++) {
    float f = STIM_F0_HZ * k;
    if (f > 450.0f) break;
    if (freqHz >= f - MDF_NOTCH_BW && freqHz <= f + MDF_NOTCH_BW) return true;
  }
  return false;
}

float calculateMDF(int localWriteIdx) {
  // 원형 버퍼에서 "가장 최근 FFT_SIZE개"를 시간순으로 읽는다.
  int start = (localWriteIdx - FFT_SIZE + RMS_WINDOW) % RMS_WINDOW;

  // FFT 윈도우 평균 제거: DC 흔들림이 MDF를 낮은 주파수로 끌고 가는 문제 완화
  double mean = 0;
  for (int i = 0; i < FFT_SIZE; i++) {
    int idx = (start + i) % RMS_WINDOW;
    mean += rawBuffer[idx];
  }
  mean /= FFT_SIZE;

  for (int i = 0; i < FFT_SIZE; i++) {
    int idx = (start + i) % RMS_WINDOW;
    vReal[i] = (double)rawBuffer[idx] - mean;
    vImag[i] = 0;
  }

  FFT.windowing(FFTWindow::Hamming, FFTDirection::Forward);
  FFT.compute(FFTDirection::Forward);
  FFT.complexToMagnitude();

  const float BIN_HZ = (float)SAMPLE_RATE / FFT_SIZE;
  const float MDF_MIN_HZ = 20.0f;
  const float MDF_MAX_HZ = 450.0f;
  int firstBin = max(1, (int)ceil(MDF_MIN_HZ / BIN_HZ));
  int lastBin  = min((FFT_SIZE / 2) - 1, (int)floor(MDF_MAX_HZ / BIN_HZ));

  double totalPower = 0;
  for (int i = firstBin; i <= lastBin; i++) {
    if (mdfNotched((float)i * BIN_HZ)) continue;   // 전원 노이즈 + 자극 배음 제외
    double power = vReal[i] * vReal[i];
    totalPower += power;
  }
  // 실패는 0 이 아니라 NaN 으로 돌려준다. 0 은 'MDF = 0Hz' 라는 유효값처럼 보여서
  // 다운스트림(SPC baseline·CSV·학습)에 조용히 섞인다.
  if (totalPower <= 0.000001) return NAN;

  double halfPower = totalPower / 2.0;
  double cumPower = 0;
  for (int i = firstBin; i <= lastBin; i++) {
    if (mdfNotched((float)i * BIN_HZ)) continue;   // notch 와 동일하게 건너뜀
    double power = vReal[i] * vReal[i];
    double prevCum = cumPower;
    cumPower += power;
    if (cumPower >= halfPower) {
      // bin 중심을 그대로 쓰면 MDF 가 BIN_HZ(=1.953Hz) 격자에 양자화된다.
      // 그러면 baseline 10개가 몇 개 값으로 뭉쳐 σ 가 붕괴하고(실측 σ=1.45Hz=0.74bin),
      // 2σ 관리한계가 평균에서 1.5bin 아래에 붙어 잡음에도 발동한다(위양성).
      // 이 bin 안에서 누적전력이 halfPower 를 지나는 지점을 선형보간해 격자를 없앤다.
      double frac = (power > 0.0) ? (halfPower - prevCum) / power : 0.0;
      if (frac < 0.0) frac = 0.0;
      if (frac > 1.0) frac = 1.0;
      // bin i 는 [i-0.5, i+0.5] 를 대표하므로 그 구간 안에서 보간
      return (float)((double)i - 0.5 + frac) * BIN_HZ;
    }
  }
  return NAN;
}

// ============================================================
// 선형회귀 slope (% 단위)
// ============================================================
float calculateSlopePercent(float* history, int count, bool circular) {
  float sumX = 0, sumY = 0, sumXY = 0, sumX2 = 0;
  for (int i = 0; i < count; i++) {
    int idx = circular ? ((historyIdx - count + i + HISTORY_SIZE) % HISTORY_SIZE) : i;
    float x = i;
    float y = history[idx];
    sumX += x;
    sumY += y;
    sumXY += x * y;
    sumX2 += x * x;
  }
  float meanY = sumY / count;
  if (meanY < 0.01) return 0;
  float slope = (count * sumXY - sumX * sumY) / (count * sumX2 - sumX * sumX);
  return (slope * count) / meanY * 100.0;
}

// ============================================================
// BLE Notify로 데이터 송신 (기본 10Hz, 그중 1Hz는 full)
// ----------------------------------------------------------
// 매 100ms마다 한 줄씩 보낸다.
// raw/emg/env/rms/mdf/valid 는 모든 행에 들어가므로 CSV가 10Hz로 정렬된다.
// full 메시지는 여기에 1Hz 상태값(slope/baseline/state machine 등)만 추가된다.
// ============================================================
void sendDataUpdate() {
  if (!deviceConnected || dataChar == nullptr) return;

  unsigned long now = millis();
  if (now - lastNotifyMs < DATA_THROTTLE_MS) return;
  lastNotifyMs = now;

  bool full = sendFullNext;
  sendFullNext = false;
  sendRmsMdfNext = false;
  bool hasMarker = sessionMarker.length() > 0;

  ArduinoJson::JsonDocument doc;

  // ===== 항상 보내는 필드 (10Hz) =====
  doc["ts"]   = now;
  doc["raw"]  = currentRaw10Hz;          // 100ms 평균 ADC 원값
  doc["emg"]  = currentEmg10Hz;          // 100ms 평균 |centered|
  doc["env"]  = envLPF;                  // envelope LPF, 10Hz 송신
  doc["rms"]  = currentRMS;              // 최근 1초 sliding RMS, 10Hz 계산
  doc["mdf"]  = currentMDF;              // 최근 512ms MDF, 10Hz 계산
  doc["v"]    = metricsValid;            // 초기 1초 전에는 false
  doc["run"]  = systemRunning;
  // FES 외부 수동 제어 → 세션 동작 중을 '자극 중'으로 보고 (앱 엔진·CSV 일관성).
  doc["stim"] = systemRunning;
  doc["fd"]   = currentFatigueDetected;
  if (hasMarker) {
    doc["mk"] = sessionMarker;
    sessionMarker = "";          // 마커는 1회만 전송
  }

  // ===== M-wave 메트릭 (새 검출이 있을 때만) =====
  if (mwDirty) {
    doc["mwa"] = currentMwAmp;
    doc["mwc"] = currentMwArea;
    doc["mwl"] = currentMwLatency;
    doc["mwv"] = currentMwValid;    // 검출 신뢰도 플래그 (CSV MW_Valid 컬럼)
    doc["mwn"] = mwCount;
    mwDirty = false;
  }

  // rms/mdf는 위에서 모든 10Hz 행에 항상 포함한다.

  // ===== full 메시지에만 (1Hz) =====
  if (full) {
    doc["rs"]   = currentRMSSlope;
    doc["ms"]   = currentMDFSlope;
    doc["hc"]   = historyCount;
    doc["cc"]   = consecutiveCount;
    doc["b"]    = baselineRMS;
    doc["rr"]   = rmsRatio;
    doc["st"]   = muscleState;
    doc["cm"]   = currentCenteredMean10Hz;
    doc["pk"]   = currentPeakAbs10Hz;
    doc["dco"]  = dcOffset;
    doc["dcc"]  = !dcCalibrating;
    doc["proto"] = completeParalysisProtocol ? "complete" : "mixed";

    // 수축 상태머신
    doc["cs"]   = (int)contractState;
    doc["cd"]   = (contractState != CS_REST)
                    ? (uint32_t)(now - contractStartMs) : 0;
    doc["lt"]   = String((char)lastContractType);
    doc["ld"]   = lastContractDurMs;
    doc["lp"]   = lastContractPeak;
    doc["bc"]   = burstCount;
    doc["sc"]   = sustainedCount;
    doc["tc"]   = transientCount;

    // 임계값은 매 10초마다만
    if ((now / 1000) % 10 == 0) {
      doc["rt"] = RMS_THRESHOLD;
      doc["mt"] = MDF_THRESHOLD;
      doc["ct"] = CONSECUTIVE_TRIGGER;
    }
  }

  String json;
  ArduinoJson::serializeJson(doc, json);

  dataChar->setValue((uint8_t*)json.c_str(), json.length());
  dataChar->notify();
}

// ============================================================
// RAW 4kHz 파형 바이너리 송신
// ----------------------------------------------------------
// 완성된 100표본 블록을 [uint32 firstSampleIndex][uint16 count][int16 raw×count]
// 형식(little-endian)으로 rawChar에 notify. 한 패킷 = 6 + 200 = 206바이트.
// (MTU 247 협상 기준. 폰에서 count/길이를 검증하므로 잘린 패킷은 폐기됨)
// ============================================================
// 큐를 **비울 때까지** 보낸다.
//
// 예전에는 호출당 한 패킷만 보냈다. RAW 블록은 25ms마다(40Hz) 생기는데 이
// 함수는 loop() 의 100ms 주기(10Hz)에서 불리므로, 네 개 중 세 개가 큐에
// 쌓이다 RAW_QUEUE_DEPTH 를 넘겨 **조용히 버려졌다.**
//
// 실측(2026-08-13, raw_20260813_164954_4khz.csv): 표본의 80%가 유실됐고
// 도착한 조각은 전부 정확히 100표본(한 패킷)이었다. 그 사이 빈 구간은
// 100ms. 그래서 31ms 에폭(4kHz에서 124표본)이 통째로 들어가는 구간이
// 1925개 중 **1개**뿐이었고, 앱은 버스트를 전량 폐기했다 — 화면에는
// 「자극을 찾지 못했다」로만 나타나서 원인이 여기 있는 줄 아무도 몰랐다.
//
// 한 번에 최대 RAW_QUEUE_DEPTH 개까지만 돈다. 큐 크기가 상한이라 이 루프가
// loop() 를 오래 붙들 수 없다.
void sendRawBatch() {
  if (!deviceConnected || rawChar == nullptr) return;

  for (int k = 0; k < RAW_QUEUE_DEPTH; k++) {
    uint32_t firstIdx;
    int16_t local[RAW_BATCH_SAMPLES];

    portENTER_CRITICAL(&timerMux);
    if (rawQueueCount <= 0) { portEXIT_CRITICAL(&timerMux); return; }
    firstIdx = rawQueueFirstIdx[rawQueueHead];
    for (int i = 0; i < RAW_BATCH_SAMPLES; i++) local[i] = rawQueue[rawQueueHead][i];
    rawQueueHead = (rawQueueHead + 1) % RAW_QUEUE_DEPTH;
    rawQueueCount--;
    portEXIT_CRITICAL(&timerMux);

    uint8_t buf[6 + 2 * RAW_BATCH_SAMPLES];
    buf[0] = firstIdx & 0xFF;
    buf[1] = (firstIdx >> 8) & 0xFF;
    buf[2] = (firstIdx >> 16) & 0xFF;
    buf[3] = (firstIdx >> 24) & 0xFF;
    buf[4] = RAW_BATCH_SAMPLES & 0xFF;
    buf[5] = (RAW_BATCH_SAMPLES >> 8) & 0xFF;
    for (int i = 0; i < RAW_BATCH_SAMPLES; i++) {
      int16_t v = local[i];
      buf[6 + 2 * i]     = v & 0xFF;
      buf[6 + 2 * i + 1] = (v >> 8) & 0xFF;
    }

    rawChar->setValue(buf, 6 + 2 * RAW_BATCH_SAMPLES);
    rawChar->notify();
  }
}

// ============================================================
// 수축 상태머신 — 매 1초 RMS 계산 직후 호출
// ----------------------------------------------------------
// 상태: REST → ONSET → SUSTAINED → (종료 시 라벨링 후) REST
//
// 활성 조건:  currentRMS > baselineRMS × CONTRACT_ACTIVE_RATIO
// onset 조건: 활성 + ΔRMS > +DRMS_ONSET
// 종료 조건: 비활성 OR ΔRMS < DRMS_OFFSET
//
// 종료 시 지속시간으로 라벨 부여:
//   < 2s        → 'b' burst    (일시적 떨림, 분석 제외 권장)
//   2~5s        → 't' transient (애매)
//   ≥ 5s        → 's' sustained (분석에 유효)
// ============================================================
void updateContractionState() {
  if (!systemRunning || !baselineReady) {
    contractState = CS_REST;
    prevRMS = currentRMS;
    return;
  }

  unsigned long now = millis();
  float drms = currentRMS - prevRMS;
  bool active = (currentRMS > baselineRMS * CONTRACT_ACTIVE_RATIO);

  switch (contractState) {
    case CS_REST:
      if (active && drms > DRMS_ONSET) {
        contractState = CS_ONSET;
        contractStartMs = now;
        contractPeakRMS = currentRMS;
      }
      break;

    case CS_ONSET:
    case CS_SUSTAINED:
      if (currentRMS > contractPeakRMS) contractPeakRMS = currentRMS;

      if (!active || drms < DRMS_OFFSET) {
        // 종료 → 라벨링
        unsigned long dur = now - contractStartMs;
        lastContractDurMs = dur;
        lastContractPeak  = contractPeakRMS;

        if (dur < BURST_MAX_MS) {
          lastContractType = 'b';
          burstCount++;
        } else if (dur >= SUSTAINED_MIN_MS) {
          lastContractType = 's';
          sustainedCount++;
        } else {
          lastContractType = 't';
          transientCount++;
        }

        Serial.printf("💪 contract end: %c, dur=%lums, peak=%.0f\n",
                      lastContractType, lastContractDurMs, lastContractPeak);

        contractState = CS_REST;
        contractPeakRMS = 0;
      } else if (contractState == CS_ONSET &&
                 (now - contractStartMs > ONSET_TO_SUSTAINED_MS)) {
        contractState = CS_SUSTAINED;
      }
      break;
  }

  prevRMS = currentRMS;
}