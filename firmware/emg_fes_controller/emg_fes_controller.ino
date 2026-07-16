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
#include <ArduinoJson.h>
#include <arduinoFFT.h>
#include <math.h>

// ===== BLE UUID (Nordic UART Service 호환) ====


#define SERVICE_UUID     "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
#define CHAR_DATA_UUID   "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"
#define CHAR_CMD_UUID    "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
#define CHAR_RAW_UUID    "6E400004-B5A3-F393-E0A9-E50E24DCCA9E"  // RAW 1kHz 파형 (binary notify)
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
const int SAMPLE_RATE = 1000;              // 1kHz 샘플링
const int FFT_SIZE = 512;                  // FFT 윈도우 (512표본=512ms 분량 @1kHz)
const int RMS_WINDOW = 1000;               // RMS 윈도우 (1초)
const int HISTORY_SIZE = 60;               // 60초 분량 RMS/MDF 히스토리

// 임계값 (방식 3: 이중 조건)
float RMS_THRESHOLD = 20.0;                // RMS slope +20% 이상
float MDF_THRESHOLD = -3.0;                // MDF slope -3% 이하 (노이즈 감안 완화)
const int CONSECUTIVE_TRIGGER = 5;
const int DC_OFFSET = 1862;                // 실측 휴식 mean (DIAG 로그 기준)

// 베이스라인
const int BASELINE_SAMPLES = 10;
const float MUSCLE_LOW_RATIO  = 0.7;
const float MUSCLE_HIGH_RATIO = 1.5;

// 안전장치
const unsigned long STIM_TIMEOUT_MS = 180000;   // 3분
const unsigned long DATA_THROTTLE_MS = 100;     // 데이터 송신 최소 간격 (BLE 부하 보호)

// ===== M-wave 검출 파라미터 =====
// 자극 artifact 검출 임계 (DC 보정된 centered 값의 절대값).
// 실측에서 normal EMG burst 최대보다 충분히 커야 함. 일반적으로 1000~2000 범위.
const int MW_ARTIFACT_THRESHOLD = 1000;
const int MW_WINDOW_START_MS = 5;             // 자극 후 ms (artifact 제외용 dead-zone)
const int MW_WINDOW_END_MS = 30;              // 자극 후 ms
const int MW_WINDOW_LEN = (MW_WINDOW_END_MS - MW_WINDOW_START_MS) + 1;  // 26 샘플 (1kHz)
const unsigned long MW_REFRACTORY_MS = 40;    // 같은 자극 중복 트리거 방지 (FES ≤ 25Hz 가정)

// M-wave 검출 유효성(신뢰도) 판정 파라미터.
// 목적: 검출 실패(노이즈 피크·창끝값)를 '유효'로 오인해 데이터셋 정답과 SPC baseline을
//       오염시키는 것을 막는다. 유효하지 않아도 원값은 CSV에 남기되 mwv 플래그로 구분.
const float MW_AMP_MIN = 80.0f;      // peak-to-peak 이보다 작으면 유발반응 아님(노이즈)
const int   MW_LAT_MIN_MS = 6;       // 생리적 M-wave 잠복 하한 (창 시작 5ms 직후=아티팩트 잔향 배제)
const int   MW_LAT_MAX_MS = 24;      // 이보다 늦으면(특히 30=창 끝) 피크 못 찾은 검출 실패

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
// 기본 5ms = 자극 스파이크 + 증폭기 회복 구간(MW_WINDOW_START_MS와 동일).
//   → RMS/MDF/SMR 의 주 오염원인 거대 스파이크 제거, 펄스 사이 데이터는 대부분 보존.
// 값을 ~30ms로 키우면 M-wave(유발반응)까지 제외되지만, 25Hz 자극에선 펄스 간격이
// 40ms뿐이라 데이터가 거의 다 blanking 되므로 권장하지 않음.
const int STIM_BLANK_MS = 5;

// ===== BLE 핸들 =====
NimBLECharacteristic* dataChar = nullptr;
NimBLECharacteristic* cmdChar  = nullptr;
NimBLECharacteristic* rawChar  = nullptr;   // RAW 1kHz 파형 스트리밍 (binary)
volatile bool deviceConnected = false;

// ===== ADC 버퍼 / 10Hz 메트릭 생성 =====
// 1kHz로 샘플링하되, CSV/BLE 행은 ENV와 같은 100ms 간격(10Hz)으로 만든다.
// RMS는 최근 1초(1000표본) 슬라이딩 윈도우를 100ms마다 다시 계산한다.
// MDF는 최근 FFT_SIZE(512표본=512ms) 윈도우를 100ms마다 다시 계산한다.
volatile int rawBuffer[RMS_WINDOW];
volatile int writeIdx = 0;                 // 다음 기록 위치 (RMS_WINDOW로 wrap)
volatile int windowCount = 0;              // 현재 RMS 윈도우에 들어있는 표본 수, 최대 1000
volatile int64_t windowSum = 0;            // 최근 1초 centered 값 합
volatile int64_t windowSumSq = 0;          // 최근 1초 centered 값 제곱합
volatile bool bufferFilled = false;        // 1초치(1000표본)가 한 번이라도 채워졌는지

const int COMPUTE_INTERVAL = 100;          // 100표본 @1kHz = 100ms → 10Hz
volatile int samplesSinceCompute = 0;      // 마지막 10Hz 계산 이후 누적 표본 수
volatile bool metricReady = false;         // 100표본마다 true → loop에서 10Hz 계산
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

// 실시간 envelope (|raw - DC| 의 1차 IIR LPF, 1kHz로 갱신)
// alpha=0.03 → 1kHz에서 약 5Hz LPF, 힘 줄 때 100~200ms 안에 따라옴
volatile float envLPF = 0;
const float ENV_LPF_ALPHA = 0.03f;

// FES blanking 용: 마지막으로 blanking 되지 않은(깨끗한) centered 값. hold 대체에 사용.
int lastCleanCentered = 0;

// ===== RAW 1kHz 파형 스트리밍 (바이너리, 전용 캐릭터리스틱) =====
// 매 샘플의 raw ADC를 100개(=100ms)씩 묶어 바이너리 패킷으로 보낸다.
// 패킷 포맷 (little-endian):
//   [uint32 firstSampleMs][uint16 count][int16 raw × count]
// firstSampleMs = 세션 시작 후 첫 샘플의 ms 인덱스 (1kHz라 1샘플=1ms).
//   → 폰에서 1ms 해상도 타임라인 복원 + 인덱스 불연속으로 패킷 누락 감지.
volatile int16_t rawBatchFill[COMPUTE_INTERVAL];   // ISR 태스크가 채우는 중인 블록
volatile int16_t rawBatchOut[COMPUTE_INTERVAL];    // 완성되어 송신 대기 중인 블록
volatile uint32_t rawSampleCounter = 0;            // 세션 시작 후 누적 샘플 수
volatile uint32_t rawBatchFirstIdx = 0;            // rawBatchOut 첫 샘플의 인덱스(ms)
volatile int  rawBatchCount = 0;                    // rawBatchOut 유효 샘플 수
volatile bool rawBatchReady = false;               // loop()에서 송신할 블록 대기 플래그

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
volatile unsigned long mwArtifactAtMs = 0;
volatile bool mwCapturing = false;
volatile int mwSampleCount = 0;
volatile float mwArtifactEMA = MW_ADAPT_EMA0;   // 최근 자극 스파이크 peak 의 EMA(적응형 문턱용)
volatile int mwArtifactPeak = 0;                // 현재 캡처 중 자극 스파이크 peak |centered|
volatile int mwSamples[MW_WINDOW_LEN + 4];     // +여유
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
void handleCommand(JsonDocument& doc);
void updateContractionState();
void samplingTask(void* param);
float calculateRMS(int64_t sum, int64_t sumSq, int n);
float calculateMDF(int localWriteIdx);
void sendRawBatch();

// ============================================================
// 1ms 타이머 ISR — analogRead는 IRAM-safe가 아니므로
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
    ulTaskNotifyTake(pdTRUE, portMAX_DELAY);

    int raw = analogRead(PIN_EMG_RAW);
    int centered = raw - DC_OFFSET;
    int absVal = centered < 0 ? -centered : centered;
    unsigned long nowMs = millis();

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
          (nowMs - mwArtifactAtMs) > MW_REFRACTORY_MS) {
        mwArtifactAtMs = nowMs;
        mwCapturing = true;
        mwSampleCount = 0;
        mwArtifactPeak = absVal;              // 스파이크 peak 추적 시작
      }
      if (mwCapturing) {
        unsigned long since = nowMs - mwArtifactAtMs;
        if (absVal > mwArtifactPeak) mwArtifactPeak = absVal;   // dead-zone 포함 스파이크 peak
        if (since >= (unsigned long)MW_WINDOW_START_MS &&
            since <= (unsigned long)MW_WINDOW_END_MS) {
          if (mwSampleCount < MW_WINDOW_LEN) {
            mwSamples[mwSampleCount++] = centered;
          }
        } else if (since > (unsigned long)MW_WINDOW_END_MS) {
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
    // (raw 1kHz 로그와 M-wave 검출은 위에서 진짜 원신호로 이미 처리함)
    bool stimBlank = systemRunning && mwArtifactAtMs != 0 &&
                     (nowMs - mwArtifactAtMs) < (unsigned long)STIM_BLANK_MS;
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

    // 100ms 블록 대표값. raw 평균/RAW 1kHz 로그는 '진짜' 원신호,
    // EMG/peak/centered 통계는 blanking 적용값으로 누적.
    blockRawSum += raw;                        // 진짜 raw 평균 (진단용)
    blockCenteredSum += procCentered;
    blockAbsSum += procAbs;
    if (procAbs > blockPeakAbs) blockPeakAbs = procAbs;
    if (procCentered < blockMinCentered) blockMinCentered = procCentered;
    if (procCentered > blockMaxCentered) blockMaxCentered = procCentered;
    if (blockCount < COMPUTE_INTERVAL) rawBatchFill[blockCount] = (int16_t)raw;  // RAW 1kHz: 진짜 원신호(오프라인용)
    blockCount++;
    rawSampleCounter++;          // 세션 시작 후 누적 샘플 인덱스 (1kHz=1ms)

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

      // RAW 1kHz 블록(100표본) 완성 → 송신 대기 버퍼로 스냅샷 (세션 동작 중에만)
      if (systemRunning) {
        for (int i = 0; i < COMPUTE_INTERVAL; i++) rawBatchOut[i] = rawBatchFill[i];
        rawBatchCount = COMPUTE_INTERVAL;
        rawBatchFirstIdx = rawSampleCounter - COMPUTE_INTERVAL;
        rawBatchReady = true;
      }

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

    StaticJsonDocument<256> doc;
    DeserializationError err = deserializeJson(doc, value.c_str());
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

  // 1kHz ADC 타이머 (ESP32 core 3.x API)
  sampleTimer = timerBegin(1000000);                      // 1MHz tick (1us 해상도)
  timerAttachInterrupt(sampleTimer, &onSampleTimer);
  timerAlarm(sampleTimer, 1000, true, 0);                 // 1000us=1kHz, autoreload

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

  // RAW characteristic (ESP32 → Phone, notify) — 1kHz 파형 바이너리 스트림
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
    metricsValid = rmsReady && mdfReady;
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

        // ---- 관리도 baseline 학습 (세션 동작 중 RMS/MDF 표본, 8개면 확정) ----
        if (systemRunning) {
          ccIngest(rmsChart, currentRMS);
          ccIngest(mdfChart, currentMDF);
        }

        // ---- 통일 판정 규칙 (앱 FatigueEngine 과 동일) ----
        bool rmsHigh = systemRunning && ccAbove(rmsChart, currentRMS);
        bool mdfLow  = systemRunning && ccBelow(mdfChart, currentMDF);
        bool rmsMdfGroup = rmsHigh && mdfLow;
        bool mwGroup = currentMwValid &&
                       mwAmpChart.established && mwAreaChart.established &&
                       mwLatChart.established &&
                       ccBelow(mwAmpChart, currentMwAmp) &&
                       ccBelow(mwAreaChart, currentMwArea) &&
                       ccAbove(mwLatChart, currentMwLatency);
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
            if (isStimulating) {
              triggerStimulation(false);
            }
          }
        } else {
          consecutiveCount = 0;
        }

        if (currentFatigueDetected &&
            (millis() - fatigueDetectedAtMs > FATIGUE_LATCH_MS)) {
          currentFatigueDetected = false;
        }

        // 베이스라인 수집
        if (systemRunning && !baselineReady && historyCount >= BASELINE_SAMPLES) {
          float sum = 0;
          for (int i = 0; i < BASELINE_SAMPLES; i++) sum += rmsHistory[i];
          baselineRMS = sum / BASELINE_SAMPLES;
          baselineReady = true;
          Serial.printf("✅ Baseline RMS: %.1f (%ds 평균)\n", baselineRMS, BASELINE_SAMPLES);
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
    int n = mwSampleCount;
    int snapshot[MW_WINDOW_LEN + 4];
    for (int i = 0; i < n && i < MW_WINDOW_LEN + 4; i++) {
      snapshot[i] = mwSamples[i];
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
      currentMwArea = (float)absSum;
      currentMwLatency = (float)(MW_WINDOW_START_MS + peakIdx);
      // ── 검출 신뢰도 판정 ──
      // 진폭이 노이즈 수준이거나, 피크가 생리범위를 벗어나면(특히 창 끝=피크 못 찾음)
      // '무효'로 표시. 원값(amp/area/lat)은 그대로 두어 CSV/학습엔 남기고,
      // SPC baseline·즉시판정에서만 제외해 오검출로 인한 오작동을 막는다.
      currentMwValid = (currentMwAmp >= MW_AMP_MIN) &&
                       (currentMwLatency >= (float)MW_LAT_MIN_MS) &&
                       (currentMwLatency <= (float)MW_LAT_MAX_MS);
      mwDirty = true;
      mwCount++;
      // 관리도 baseline 학습 — 유효한 M-wave만 (세션 동작 중 초반 6회 → mean·σ 확정)
      if (systemRunning && currentMwValid) {
        ccIngest(mwAmpChart, currentMwAmp);
        ccIngest(mwAreaChart, currentMwArea);
        ccIngest(mwLatChart, currentMwLatency);
      }
    }
  }

  // BLE 송신은 100ms마다. raw/emg/env/rms/mdf 모두 같은 10Hz 행으로 송신.
  sendDataUpdate();

  // RAW 1kHz 파형 바이너리 패킷 송신 (100ms마다 100표본씩, 전용 캐릭터리스틱).
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
void handleCommand(JsonDocument& doc) {
  String cmd = doc["cmd"].as<String>();
  Serial.printf("📥 cmd: %s\n", cmd.c_str());

  if (cmd == "start") {
    systemRunning = true;
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
    // RAW 1kHz 스트리밍 상태 리셋 — 인덱스를 세션 시작에 0으로 정렬
    rawSampleCounter = 0;
    rawBatchFirstIdx = 0;
    rawBatchCount = 0;
    rawBatchReady = false;
    portEXIT_CRITICAL(&timerMux);
    // M-wave 카운터/상태 리셋
    mwCount = 0;
    mwCapturing = false;
    mwSampleCount = 0;
    mwReady = false;
    mwDirty = false;
    mwArtifactAtMs = 0;
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
    Serial.println("→ 시작 (10초간 베이스라인 수집, FES OFF)");
    triggerStimulation(false);
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
// 60Hz 전원 노이즈 + 하모닉(120/180Hz) ±NOTCH_BW 를 MDF 계산에서 제외.
// 전원 노이즈가 크면 그 성분이 중앙주파수를 끌어올려 '피로에 의한 MDF 하강'을 가린다.
static const float MDF_NOTCH_HZ[] = {60.0f, 120.0f, 180.0f};
static const float MDF_NOTCH_BW = 2.0f;   // ±2Hz bin 제거
static inline bool mdfNotched(float freqHz) {
  for (int k = 0; k < 3; k++) {
    if (freqHz >= MDF_NOTCH_HZ[k] - MDF_NOTCH_BW &&
        freqHz <= MDF_NOTCH_HZ[k] + MDF_NOTCH_BW) return true;
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
    if (mdfNotched((float)i * BIN_HZ)) continue;   // 60/120/180Hz 전원 노이즈 제외
    double power = vReal[i] * vReal[i];
    totalPower += power;
  }
  if (totalPower <= 0.000001) return 0;

  double halfPower = totalPower / 2.0;
  double cumPower = 0;
  for (int i = firstBin; i <= lastBin; i++) {
    if (mdfNotched((float)i * BIN_HZ)) continue;   // notch 와 동일하게 건너뜀
    double power = vReal[i] * vReal[i];
    cumPower += power;
    if (cumPower >= halfPower) {
      return (float)i * BIN_HZ;
    }
  }
  return 0;
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

  StaticJsonDocument<512> doc;

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
  serializeJson(doc, json);

  dataChar->setValue((uint8_t*)json.c_str(), json.length());
  dataChar->notify();
}

// ============================================================
// RAW 1kHz 파형 바이너리 송신
// ----------------------------------------------------------
// 완성된 100표본 블록을 [uint32 firstSampleMs][uint16 count][int16 raw×count]
// 형식(little-endian)으로 rawChar에 notify. 한 패킷 = 6 + 200 = 206바이트.
// (MTU 247 협상 기준. 폰에서 count/길이를 검증하므로 잘린 패킷은 폐기됨)
// ============================================================
void sendRawBatch() {
  if (!deviceConnected || rawChar == nullptr) return;
  if (!rawBatchReady) return;

  uint32_t firstIdx;
  int cnt;
  int16_t local[COMPUTE_INTERVAL];

  portENTER_CRITICAL(&timerMux);
  if (!rawBatchReady) { portEXIT_CRITICAL(&timerMux); return; }
  rawBatchReady = false;
  firstIdx = rawBatchFirstIdx;
  cnt = rawBatchCount;
  for (int i = 0; i < cnt && i < COMPUTE_INTERVAL; i++) local[i] = rawBatchOut[i];
  portEXIT_CRITICAL(&timerMux);

  uint8_t buf[6 + 2 * COMPUTE_INTERVAL];
  buf[0] = firstIdx & 0xFF;
  buf[1] = (firstIdx >> 8) & 0xFF;
  buf[2] = (firstIdx >> 16) & 0xFF;
  buf[3] = (firstIdx >> 24) & 0xFF;
  buf[4] = cnt & 0xFF;
  buf[5] = (cnt >> 8) & 0xFF;
  for (int i = 0; i < cnt; i++) {
    int16_t v = local[i];
    buf[6 + 2 * i]     = v & 0xFF;
    buf[6 + 2 * i + 1] = (v >> 8) & 0xFF;
  }

  rawChar->setValue(buf, 6 + 2 * cnt);
  rawChar->notify();
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
