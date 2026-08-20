/*
  RE:FIT EMG-FES Controller — Phase 1 (얇은 실시간·안전 MCU)
  =========================================================================
  아키텍처: "얇은 실시간·안전 MCU + 똑똑한 폰 두뇌"
    · MCU  : ADC 샘플링 · 자극 검출 · DC보정 · M-wave 에폭 추출 · 릴레이 구동
             + 자율 안전층(watchdog·하드리밋·fail-safe·INCREASE 게이팅). 판정 안 함.
    · 폰   : 에폭 수신 → 면적·running-max 정규화·인과 판정 → 판정+목표세기 하달.
  통신: BLE 바이너리 프로토콜 v0.2 (little-endian, CRC8). docs/RE-FIT_BLE_Protocol_v0.2.md 계약.

  === Phase 1 변경 (옛 "방식3: RMS+MDF+SPC 판정" 대비) ===
  [삭제] FFT/MDF · RMS · 수축상태머신 · SPC관리도 · 펌웨어 피로판정 · slope · 연속 RAW 스트리밍 · JSON
         (완전마비에 RMS/MDF 무효, 판정은 폰으로 이관 → MCU는 안전+구동만)
  [유지] 타이머 ISR+샘플링태스크 · DC캘리브 · M-wave 에폭 캡처 · 적응형 문턱 · 이중버퍼 · NimBLE
  [추가] 에폭/STATUS/EVENT 송신 · JUDGMENT/HEARTBEAT 수신 · 안전층 · 비블로킹 릴레이 액추에이터
  [수정] triggerStimulation 블로킹 delay() 제거(→ 비블로킹 큐: 그 ~1.2s raw 공백 해소)
         onDisconnect 블로킹 제거 · MW창 +2~+15ms(검증 정합) · ms↔표본 전부 SAMPLE_RATE 유도

  === v0.2 (폐루프 결함 수정) ===
  [수정] 세션 시작 경로 신설 — SC_REQUEST_START 수용. v0.1 은 startSession() 호출부가
         아예 없어 systemRunning 이 영원히 false → 에폭이 단 하나도 나가지 않았다.
  [수정] START 는 "로그 전용"(샘플링·에폭 송신)만 시작한다. 자극 투입은 SC_STIM_ENABLE 로만.
         마사지기는 사람이 직접 켜고 끄는 상태라, START 가 전원을 켠 것으로 가정하면
         stimOn 추정이 실물과 어긋나 INCREASE 게이트의 safeState 가 거짓 통과한다.
  [수정] 스파이크 진폭을 M-wave 창 이전(0~+2ms)에서만 측정. v0.1 은 캡처 전 구간에서
         peak 를 갱신해 M-wave 표본이 분모에 섞였다 → 면적÷스파이크 정규화가 무력화.
  [수정] 에폭에 실제 millis() 와 sample_index 를 동시 기입. v0.1 의 t_ms 는 샘플카운터에서
         합성한 값이라 STATUS(millis 기준)와 정렬 불가였고 샘플링 지연을 탐지할 수 없었다.
  [수정] BLE 콜백에서 릴레이 구동·notify 금지 — 세션 명령도 pending 플래그 → loop 실행.
         v0.1 은 handleDownlink 가 NimBLE 호스트 태스크에서 stopSession() 을 직접 불러
         actQueue 와 upSeq/upChar 를 loop 와 동시에 만졌다.
  [수정] ready 버퍼 기록 시 샘플링 태스크도 timerMux 를 잡는다(v0.1 은 읽기측만 잡아 무효).
  [수정] JUDGMENT 최소 길이 21 → 19 바이트. 실제 파싱하는 페이로드는 12바이트다.
  [수정] watchdog/deadman 은 stimOn 일 때만 격상. 끌 자극이 없으면 막을 위험도 없다.
  [추가] 포화 플래그(flags bit1 창 · bit2 스파이크). 실측에서 스파이크가 ADC 레일에 붙어
         (dcOffset 1904 기준 상한 2191 인데 spike=2186 이 반복) R 의 분모가 상수가 됐다.
         표시가 없으면 폰이 그 에폭을 그대로 추세에 먹인다. 예약 비트를 채운 것이라
         프로토콜 버전은 그대로다(구 리더는 무시).

  하드웨어: MyoWare 2.0 Wireless Shield(ESP32) · PC817+IRLZ44N → Omron HV-F022-V
  라이브러리: NimBLE-Arduino v2.x  (ArduinoJson·arduinoFFT 불필요 — 제거됨)
*/

#include <NimBLEDevice.h>
#include <math.h>

// ===================== 프로토콜 v0.2 =====================
// [수정] 0x01 → 0x02 : EPOCH 레이아웃(sample_index 추가·t_ms 의미 변경)과 JUDGMENT 최소
//   길이가 둘 다 바뀌었다. 버전을 올려야 구버전 펌웨어/툴과 조용히 섞이지 않는다.
#define PROTOCOL_VERSION      0x02
// msg_type (uplink 0x0X / downlink 0x1X)
#define MSG_EPOCH             0x01
#define MSG_STATUS            0x02
#define MSG_EVENT             0x03
#define MSG_JUDGMENT          0x11
#define MSG_HEARTBEAT         0x12
#define MSG_SESSION_CONTROL   0x14
// EVENT id
#define EV_SESSION_START      1
#define EV_REST_END           2
#define EV_SESSION_STOP       3
#define EV_FAULT              4
#define EV_CALIB_DONE         5
// JUDGMENT action
#define ACT_HOLD              0
#define ACT_DECREASE          1
#define ACT_INCREASE          2
#define ACT_STOP              3
// reliability
#define REL_HIGH              0
#define REL_MED               1
#define REL_LOW               2
// SESSION_CONTROL cmd
//   START/STOP 은 "기록"의 시작·정지, STIM_ENABLE/DISABLE 은 "자극"의 투입·차단으로 분리한다.
//   로그 전용 검증(자극 없이 에폭만 수집)이 별도 빌드 없이 가능해야 하기 때문.
#define SC_REQUEST_START      1
#define SC_REQUEST_STOP       2
#define SC_STIM_ENABLE        3
#define SC_STIM_DISABLE       4

// ===================== BLE UUID (Nordic UART 호환) =====================
#define SERVICE_UUID   "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
#define CHAR_UP_UUID   "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"  // MCU→Phone (notify): EPOCH·STATUS·EVENT
#define CHAR_DOWN_UUID "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"  // Phone→MCU (write) : JUDGMENT·HEARTBEAT·SC
#define BLE_DEVICE_NAME "REFIT-FES-01"

// ===================== 핀 =====================
const int PIN_EMG_RAW        = 36;   // MyoWare SIG (RAW EMG)
const int PIN_STATUS_LED     = 13;
const int PIN_MASSAGER_ON_OFF= 32;
const int PIN_MASSAGER_MODE  = 33;
const int PIN_MASSAGER_UP    = 25;
const int PIN_MASSAGER_DOWN  = 26;

// ===================== 샘플링 =====================
// [결정] 1kHz 채택: M-wave는 저주파(97%<250Hz)라 1kHz면 진폭 정합 3% 이내(다운샘플 실험).
//   에폭만 전송하므로(연속 raw 아님) BLE 부하 문제 없음. 4kHz로 올리려면 이 값만 4000으로.
//   (4kHz는 스파이크창 표본이 ~4개라 R-정규화(면적÷스파이크) 해상도만 유리)
const int SAMPLE_RATE = 1000;                 // Hz
const uint32_t US_PER_SAMPLE = 1000000UL / SAMPLE_RATE;

// DC 캘리브레이션
const int DC_OFFSET_FALLBACK = 1862;
const int DC_CALIBRATION_MS  = 3000;
volatile int dcOffset = DC_OFFSET_FALLBACK;
volatile int64_t dcCalibrationSum = 0;
volatile uint32_t dcCalibrationCount = 0;
volatile bool dcCalibrating = false;

// ===================== M-wave 에폭 파라미터 (ms→표본 전부 SAMPLE_RATE 유도) =====================
const int MW_ARTIFACT_THRESHOLD = 1000;       // 적응형 문턱 상한
const int MW_WINDOW_START_MS = 2;             // 0~1ms 스파이크 제외, +2ms부터 M-wave
const int MW_WINDOW_END_MS   = 15;            // [수정] 28→15 : 검증 분석창(+2~+15ms) 정합
const int MW_WINDOW_START_SAMPLES = MW_WINDOW_START_MS * SAMPLE_RATE / 1000;
const int MW_WINDOW_END_SAMPLES   = MW_WINDOW_END_MS   * SAMPLE_RATE / 1000;
const int MW_WINDOW_LEN = MW_WINDOW_END_SAMPLES - MW_WINDOW_START_SAMPLES + 1;  // 1kHz=14
const unsigned long MW_REFRACTORY_MS = 27;    // < 자극주기 31.185ms
const uint32_t MW_REFRACTORY_SAMPLES = MW_REFRACTORY_MS * SAMPLE_RATE / 1000;
const float MW_AMP_MIN = 80.0f;               // p2p 유효성 게이트

// 포화(레일 클리핑) 검출. 12bit ADC 라 0 또는 4095 에 닿으면 그 표본은 잘린 값이다.
//   dcOffset 으로 역산하지 않고 원 raw 를 보는 이유: 오프셋이 세션마다 달라도 레일은
//   항상 0/4095 로 고정이라 판정이 흔들리지 않는다.
// 왜 필요한가: 스파이크가 레일에 붙으면 그 값은 측정치가 아니라 "레일" 이라는 상수가 되고,
//   R = 면적÷스파이크 의 분모가 고정돼 정규화가 아무 일도 하지 않는다. 분자인 면적도
//   창이 잘리면 실제보다 작게 나온다. 폰이 이런 에폭을 추세에서 빼려면 표시가 있어야 한다.
const int ADC_MAX = 4095;
const int ADC_RAIL_MARGIN = 2;                // 레일로 볼 여유(카운트)

// 적응형 자극 트리거 문턱 = clamp(FLOOR, FRAC×스파이크EMA, 상한)
const float MW_ADAPT_FRAC  = 0.4f;
const float MW_ADAPT_FLOOR = 400.0f;
const float MW_ADAPT_ALPHA = 0.2f;
const float MW_ADAPT_EMA0  = (float)MW_ARTIFACT_THRESHOLD / MW_ADAPT_FRAC;

// ===================== 안전 파라미터 (전부 MCU 소유, BLE로 변경 불가) =====================
const uint8_t  MAX_LEVEL         = 10;        // [확정필요] HV-F022-V 세기 단계 수
const uint8_t  MAX_STEP_PER_JUDGMENT = 1;     // INCREASE 는 한 판정당 최대 1단계
const unsigned long T_WATCHDOG_MS = 2000;     // 유효 다운링크 없음 → SAFE_HOLD
const unsigned long T_DEADMAN_MS  = 8000;     // 계속 없음 → STIM_OFF
const unsigned long T_STALE_MS    = 3000;     // 판정 신선도(도착 기준)
const uint32_t STALE_STIM_LAG     = 40;       // stim_index 지연 이 이상이면 stale
const unsigned long STIM_TIMEOUT_MS = 180000; // 하드 최대 자극 시간(3분)
const unsigned long STATUS_PERIOD_MS = 200;   // STATUS 하트비트 5Hz

// ===================== BLE 핸들 =====================
NimBLECharacteristic* upChar   = nullptr;
NimBLECharacteristic* downChar = nullptr;
volatile bool deviceConnected = false;
volatile bool needRestartAdv  = false;        // onDisconnect에서 플래그만(블로킹 금지)
volatile bool needFailSafe    = false;        // onDisconnect → loop에서 안전조치

// ===================== MCU 상태머신 =====================
enum McuState { ST_IDLE=0, ST_CALIBRATING=1, ST_RUNNING=2, ST_SAFE_HOLD=3, ST_STIM_OFF=4, ST_FAULT=5 };
volatile McuState mcuState = ST_IDLE;
bool systemRunning = false;
uint16_t sessionId = 0;
unsigned long sessionStartedAtMs = 0;
unsigned long stimStartTime = 0;

// 시퀀스/세션
uint16_t upSeq = 0;                            // uplink 시퀀스
uint16_t lastCmdSeqAck = 0;                    // 마지막 수락한 downlink seq

// watchdog
volatile unsigned long lastDownlinkMs = 0;

// ===================== 릴레이(세기) 상태 + 비블로킹 액추에이터 =====================
bool     stimOn = false;
uint8_t  currentLevel = 0;                     // 개루프 추정(장치 레벨 직접 읽기 불가 — 한계)
uint8_t  healthFlags = 0;                      // bit0 watchdog · bit1 hardlimit · bit2 batt · bit3 sensor

// 버튼 프레스 큐(비블로킹): 각 원소 = (pin, 누름ms). ON_OFF 짧게=on, 길게=off, UP/DOWN=세기.
struct BtnAction { int pin; uint16_t pressMs; };
const int ACT_QUEUE_N = 24;
BtnAction actQueue[ACT_QUEUE_N];
int actHead=0, actTail=0, actCount=0;
enum ActState { A_IDLE, A_PRESSING, A_GAP };
ActState actState = A_IDLE;
unsigned long actMarkMs = 0;
uint16_t actPressMs = 0;
int actPin = -1;
const uint16_t BTN_PRESS_MS  = 150;           // 짧은 누름
const uint16_t BTN_LONG_MS   = 2000;          // 긴 누름(전원 off)
const uint16_t BTN_GAP_MS    = 200;           // 누름 사이 간격

void actEnqueue(int pin, uint16_t pressMs) {
  if (actCount >= ACT_QUEUE_N) return;         // 넘치면 버림(안전: 과도한 세기변경 방지)
  actQueue[actTail] = {pin, pressMs};
  actTail = (actTail+1) % ACT_QUEUE_N; actCount++;
}
void actClear() {                              // 진행 중 시퀀스 취소(즉시 STOP 등)
  actHead=actTail=actCount=0; actState=A_IDLE;
  digitalWrite(PIN_MASSAGER_ON_OFF, LOW); digitalWrite(PIN_MASSAGER_UP, LOW);
  digitalWrite(PIN_MASSAGER_DOWN, LOW); digitalWrite(PIN_MASSAGER_MODE, LOW);
}
// loop()에서 매 틱 호출 — delay() 없이 버튼 시퀀스 진행
void actuatorService() {
  unsigned long now = millis();
  switch (actState) {
    case A_IDLE:
      if (actCount > 0) {
        BtnAction a = actQueue[actHead];
        actHead=(actHead+1)%ACT_QUEUE_N; actCount--;
        actPin=a.pin; actPressMs=a.pressMs;
        digitalWrite(actPin, HIGH); actMarkMs=now; actState=A_PRESSING;
      }
      break;
    case A_PRESSING:
      if (now - actMarkMs >= actPressMs) {
        digitalWrite(actPin, LOW); actMarkMs=now; actState=A_GAP;
      }
      break;
    case A_GAP:
      if (now - actMarkMs >= BTN_GAP_MS) actState=A_IDLE;
      break;
  }
}

// 세기/전원 제어 헬퍼 (전부 큐잉 = 비블로킹)
void relayPowerOn()  { actEnqueue(PIN_MASSAGER_ON_OFF, BTN_PRESS_MS); stimOn=true; stimStartTime=millis(); }
void relayPowerOff() { actClear(); actEnqueue(PIN_MASSAGER_ON_OFF, BTN_LONG_MS); stimOn=false; currentLevel=0; }
void relayStepUp(uint8_t n)   { for (uint8_t i=0;i<n && currentLevel<MAX_LEVEL;i++){ actEnqueue(PIN_MASSAGER_UP,BTN_PRESS_MS); currentLevel++; } }
void relayStepDown(uint8_t n) { for (uint8_t i=0;i<n && currentLevel>0;i++){ actEnqueue(PIN_MASSAGER_DOWN,BTN_PRESS_MS); currentLevel--; } }

// ===================== M-wave 캡처 (샘플링 태스크 ↔ loop 이중버퍼) =====================
volatile uint32_t mwArtifactAtSample = 0;
volatile bool  mwArtifactSeen = false;
volatile bool  mwCapturing = false;
volatile int   mwSampleCount = 0;
volatile float mwArtifactEMA = MW_ADAPT_EMA0;
volatile int   mwArtifactPeak = 0;                 // 자극 스파이크 peak |centered| = 스파이크 진폭
volatile int   mwSamples[MW_WINDOW_LEN + 4];
volatile int   mwSamplesRdy[MW_WINDOW_LEN + 4];
volatile int   mwSampleCountRdy = 0;
volatile int   mwSpikeRdy = 0;                     // 완료 캡처의 스파이크 진폭 스냅샷
volatile bool  mwSpikeSat = false;                 // 스파이크 구간(0~+2ms)이 레일에 닿았나
volatile bool  mwWinSat   = false;                 // M-wave 창(+2~+15ms)이 레일에 닿았나
volatile bool  mwSpikeSatRdy = false;
volatile bool  mwWinSatRdy   = false;
volatile uint32_t mwArtifactAtMs = 0;              // 자극 onset 의 실제 millis() (합성 아님)
volatile uint32_t mwStimIndexRdy = 0;              // 완료 캡처의 자극 번호
volatile uint32_t mwStimTimeMsRdy = 0;             // 완료 캡처의 자극 onset — 실제 millis()
volatile uint32_t mwStimSampleRdy = 0;             // 완료 캡처의 자극 onset 샘플 인덱스
volatile bool  mwReady = false;
volatile uint32_t stimCounter = 0;                 // 세션 누적 자극 번호(stim_index)
volatile uint32_t rawSampleCounter = 0;

// ===================== 타이머/태스크 =====================
hw_timer_t* sampleTimer = nullptr;
portMUX_TYPE timerMux = portMUX_INITIALIZER_UNLOCKED;
TaskHandle_t samplingTaskHandle = nullptr;

// 함수 선언
void samplingTask(void* param);
void setupBLE();
void sendEpoch(int* samples, int n, int spike, float p2p, uint8_t flags,
               uint32_t stimIdx, uint32_t tMs, uint32_t sampleIdx);
void sendStatus();
void sendEvent(uint8_t evId, uint8_t detail);
void handleDownlink(const uint8_t* data, size_t len);
void safetySupervisor();
void serviceSessionCmd();
void startSession();
void stopSession(uint8_t evReason);

// CRC8 (poly 0x07)
uint8_t crc8(const uint8_t* p, size_t n) {
  uint8_t c = 0;
  for (size_t i=0;i<n;i++){ c ^= p[i]; for (int b=0;b<8;b++) c = (c&0x80)?(c<<1)^0x07:(c<<1); }
  return c;
}
// little-endian 패킹 헬퍼
static inline void put_u16(uint8_t* b, uint16_t v){ b[0]=v; b[1]=v>>8; }
static inline void put_u32(uint8_t* b, uint32_t v){ b[0]=v; b[1]=v>>8; b[2]=v>>16; b[3]=v>>24; }
static inline uint16_t get_u16(const uint8_t* b){ return b[0] | (b[1]<<8); }
static inline uint32_t get_u32(const uint8_t* b){ return (uint32_t)b[0] | ((uint32_t)b[1]<<8) | ((uint32_t)b[2]<<16) | ((uint32_t)b[3]<<24); }

// ============================================================
// 0.25/1ms 타이머 ISR — analogRead는 IRAM-safe 아님 → 태스크만 깨움
// ============================================================
void IRAM_ATTR onSampleTimer() {
  BaseType_t hpw = pdFALSE;
  vTaskNotifyGiveFromISR(samplingTaskHandle, &hpw);
  if (hpw == pdTRUE) portYIELD_FROM_ISR();
}

// ============================================================
// ADC 샘플링 태스크 (코어1 고정) — 자극 검출 + M-wave 에폭 캡처 + 스파이크 진폭
//   [삭제됨] RMS 윈도우 · 10Hz 블록 · blanking(RMS용) · FFT 버퍼 : 더는 필요 없음
// ============================================================
void samplingTask(void* /*param*/) {
  for (;;) {
    ulTaskNotifyTake(pdFALSE, portMAX_DELAY);   // 누적 notify 하나씩 소비(표본 유실 방지)

    int raw = analogRead(PIN_EMG_RAW);
    if (dcCalibrating) {
      dcCalibrationSum += raw; dcCalibrationCount++;
      if (dcCalibrationCount >= (uint32_t)(DC_CALIBRATION_MS * SAMPLE_RATE / 1000)) {
        dcOffset = (int)((dcCalibrationSum + dcCalibrationCount/2) / dcCalibrationCount);
        dcCalibrating = false;
      }
    }
    int centered = raw - dcOffset;
    int absVal = centered < 0 ? -centered : centered;
    const uint32_t sampleIndex = rawSampleCounter;
    // 이 표본이 ADC 레일에 닿았나 — 닿았으면 값이 잘린 것이라 진폭·면적이 실제보다 작다.
    const bool atRail = (raw <= ADC_RAIL_MARGIN) || (raw >= ADC_MAX - ADC_RAIL_MARGIN);

    // ---- 자극 artifact 검출 (적응형 문턱) + 에폭 캡처 ----
    float mwThresh = MW_ADAPT_FRAC * mwArtifactEMA;
    if (mwThresh < MW_ADAPT_FLOOR) mwThresh = MW_ADAPT_FLOOR;
    if (mwThresh > (float)MW_ARTIFACT_THRESHOLD) mwThresh = (float)MW_ARTIFACT_THRESHOLD;

    // [수정] DC 캘리브 중에는 검출하지 않는다. 그 3초는 dcOffset 이 실측값이 아니라
    //   폴백(1862)이라 centered 가 치우쳐 있고, 그렇게 뜬 에폭은 기준선이 다른 데이터가 된다.
    //   v0.1 은 에폭이 아예 안 나갔으므로 드러나지 않던 문제다.
    if (systemRunning && !dcCalibrating && !mwCapturing && (float)absVal > mwThresh &&
        (!mwArtifactSeen || sampleIndex - mwArtifactAtSample > MW_REFRACTORY_SAMPLES)) {
      mwArtifactAtSample = sampleIndex; mwArtifactSeen = true;
      mwArtifactAtMs = millis();                 // [추가] onset 의 실제 벽시계 — 합성하지 않는다
      mwCapturing = true; mwSampleCount = 0; mwArtifactPeak = absVal;
      mwSpikeSat = atRail; mwWinSat = false;     // 검출 표본 자체도 스파이크 구간이다
      stimCounter++;
    }
    if (mwCapturing) {
      uint32_t since = sampleIndex - mwArtifactAtSample;
      // [수정] 스파이크 peak 는 M-wave 창이 열리기 전(0 ~ +MW_WINDOW_START_MS)에서만 갱신한다.
      //   v0.1 은 캡처 전 구간(0~+15ms)에서 갱신해 M-wave 표본이 peak 경쟁에 들어갔다.
      //   M-wave 가 커지면 분모도 같이 커져 면적÷스파이크가 평평해진다 — 정규화가 잡으려던
      //   신호를 정규화가 지운다. 1kHz 에서 이 창은 0~1ms 로, 검증된 자극 대조군 구간과 같다.
      if (since < (uint32_t)MW_WINDOW_START_SAMPLES) {
        if (absVal > mwArtifactPeak) mwArtifactPeak = absVal;
        if (atRail) mwSpikeSat = true;           // 분모가 상수가 된다 → R 무력화
      }
      if (since >= (uint32_t)MW_WINDOW_START_SAMPLES && since <= (uint32_t)MW_WINDOW_END_SAMPLES) {
        if (atRail) mwWinSat = true;             // 면적이 실제보다 작게 나온다
        if (mwSampleCount < MW_WINDOW_LEN) mwSamples[mwSampleCount++] = centered;
      } else if (since > (uint32_t)MW_WINDOW_END_SAMPLES) {
        // 완료 캡처 → ready 버퍼로 스냅샷(다음 자극이 덮어써도 loop가 읽을 값 보존)
        // [수정] 쓰기측도 같은 락을 잡는다. v0.1 은 loop 만 잡아서 스핀락이 아무것도 배타하지
        //   못했다(스핀락은 양쪽이 잡아야 성립). 복사량은 최대 14 int 라 홀드 시간은 µs 급.
        portENTER_CRITICAL(&timerMux);
        for (int i=0;i<mwSampleCount && i<MW_WINDOW_LEN+4;i++) mwSamplesRdy[i] = mwSamples[i];
        mwSampleCountRdy = mwSampleCount;
        mwSpikeRdy       = mwArtifactPeak;
        mwStimIndexRdy   = stimCounter;
        mwStimTimeMsRdy  = mwArtifactAtMs;       // [수정] 실제 millis() — 샘플카운터 합성값 아님
        mwStimSampleRdy  = mwArtifactAtSample;   // [추가] 샘플 인덱스 동시 기입 → 폰이 드리프트 측정
        mwSpikeSatRdy    = mwSpikeSat;
        mwWinSatRdy      = mwWinSat;
        mwReady = true;
        portEXIT_CRITICAL(&timerMux);
        mwCapturing = false;
        mwArtifactEMA = MW_ADAPT_ALPHA*(float)mwArtifactPeak + (1.0f-MW_ADAPT_ALPHA)*mwArtifactEMA;
      }
    }
    rawSampleCounter++;
  }
}

// ============================================================
// BLE 콜백 (비블로킹: delay() 절대 금지)
// ============================================================
class ServerCallbacks : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer* s, NimBLEConnInfo& c) override {
    deviceConnected = true;
    s->setDataLen(c.getConnHandle(), 251);
    lastDownlinkMs = millis();               // 연결 순간 watchdog 기준 초기화
  }
  void onDisconnect(NimBLEServer* s, NimBLEConnInfo& c, int reason) override {
    deviceConnected = false;
    needFailSafe = true;                     // [수정] delay() 호출 금지 → loop에서 안전조치
    needRestartAdv = true;
  }
};

class DownCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* ch, NimBLEConnInfo& c) override {
    std::string v = ch->getValue();
    handleDownlink((const uint8_t*)v.data(), v.size());   // 파싱만, 구동은 loop
  }
};

// ============================================================
// 다운링크 처리 (JUDGMENT/HEARTBEAT/SESSION_CONTROL)
//   여기서는 검증 + 최신 판정 저장 + watchdog 리셋만. 실제 구동은 safetySupervisor().
// ============================================================
struct Judgment { uint16_t seq; uint32_t tRefMs; uint32_t stimIdxRef;
                  uint8_t stage; uint8_t action; uint8_t targetLevel; uint8_t reliability;
                  unsigned long rxMs; };
// volatile 구조체 통째 복사는 컴파일 안 됨 → 평범한 구조체 + 별도 flag(critical section 보호).
Judgment lastJudge = {0,0,0,0,0,0,0,0};
volatile bool judgePending = false;
// 세션 명령은 여기서 실행하지 않는다 — onWrite 는 NimBLE 호스트 태스크라 릴레이 큐/notify 를
// loop 와 동시에 만지게 된다. 플래그만 세우고 구동은 serviceSessionCmd() 가 loop 에서 한다.
volatile uint8_t pendingSessionCmd = 0;        // 0 = 없음, 그 외 SC_* 값

void handleDownlink(const uint8_t* d, size_t n) {
  if (n < 7) return;                          // 최소: 헤더6 + crc1
  if (d[0] != PROTOCOL_VERSION) return;        // 버전 불일치 → 폐기(무명령, watchdog 관장)
  if (crc8(d, n-1) != d[n-1]) return;          // CRC 실패 → 폐기
  uint8_t  type = d[1];
  uint16_t seq  = get_u16(d+2);
  uint16_t sess = get_u16(d+4);
  if (sess != sessionId && sess != 0) return;  // 세션 불일치 → 폐기

  lastDownlinkMs = millis();                    // 유효 다운링크 = watchdog 리셋

  if (type == MSG_HEARTBEAT) { lastCmdSeqAck = seq; return; }

  if (type == MSG_SESSION_CONTROL && n >= 8) {
    uint8_t cmd = d[6];
    if (cmd == SC_REQUEST_START || cmd == SC_REQUEST_STOP ||
        cmd == SC_STIM_ENABLE   || cmd == SC_STIM_DISABLE) {
      portENTER_CRITICAL(&timerMux);
      // 슬롯이 하나뿐이라 뒤 명령이 앞 명령을 덮는다. 정지 계열이 대기 중이면 덮지 않는다 —
      // loop 가 아직 처리하지 못한 STOP 을 STIM_ENABLE 이 지워버리면 안 된다(안전 비대칭).
      bool stopPending = (pendingSessionCmd == SC_REQUEST_STOP ||
                          pendingSessionCmd == SC_STIM_DISABLE);
      bool isStop      = (cmd == SC_REQUEST_STOP || cmd == SC_STIM_DISABLE);
      if (!stopPending || isStop) pendingSessionCmd = cmd;   // 구동은 loop 에서(위 주석 참조)
      portEXIT_CRITICAL(&timerMux);
    }
    lastCmdSeqAck = seq; return;
  }

  // [수정] 21 → 19. 실제로 파싱하는 페이로드는 d[6..17] = 12바이트다. v0.1 의 21 요구는
  //   정체불명의 패딩 2바이트를 강요해, 계약대로 19B 를 보내는 쪽이 조용히 전량 폐기됐다.
  if (type == MSG_JUDGMENT && n >= 6+12+1) {
    portENTER_CRITICAL(&timerMux);
    lastJudge.seq        = seq;
    lastJudge.tRefMs     = get_u32(d+6);
    lastJudge.stimIdxRef = get_u32(d+10);
    lastJudge.stage      = d[14];
    lastJudge.action     = d[15];
    lastJudge.targetLevel= d[16];
    lastJudge.reliability= d[17];
    lastJudge.rxMs       = millis();
    judgePending         = true;
    portEXIT_CRITICAL(&timerMux);
  }
}

// ============================================================
// 안전 감독자 (loop에서 호출) — 안전 비대칭 + watchdog + 하드리밋
//   DECREASE/STOP 즉시 · INCREASE 는 게이트 통과 시만.
// ============================================================
void safetySupervisor() {
  unsigned long now = millis();

  // --- watchdog / deadman ---
  // [수정] stimOn 일 때만 격상한다. 자극이 꺼진 로그 전용 세션에는 끊어야 할 자극이 없고,
  //   BLE 딸꾹질만으로 세션을 STIM_OFF(복귀 불가)로 보내면 수집 중인 데이터만 잃는다.
  unsigned long sinceDown = now - lastDownlinkMs;
  bool downlinkFresh = (sinceDown <= T_WATCHDOG_MS);
  if (systemRunning && stimOn) {
    if (sinceDown > T_DEADMAN_MS) {
      if (mcuState != ST_STIM_OFF) { relayPowerOff(); mcuState = ST_STIM_OFF;
        healthFlags |= 0x01; sendEvent(EV_FAULT, 1); }
      return;
    } else if (!downlinkFresh) {
      if (mcuState == ST_RUNNING) { mcuState = ST_SAFE_HOLD; healthFlags |= 0x01; }
      // SAFE_HOLD: INCREASE 금지, 현 세기 유지(또는 정책상 감소). 여기선 유지.
    } else {
      healthFlags &= ~0x01;
      if (mcuState == ST_SAFE_HOLD) mcuState = ST_RUNNING;   // 다운링크 재개 → 복귀
    }
  } else if (systemRunning && downlinkFresh) {
    healthFlags &= ~0x01;
    if (mcuState == ST_SAFE_HOLD) mcuState = ST_RUNNING;
  }

  // --- 하드 최대 자극 시간 ---
  if (stimOn && (now - stimStartTime > STIM_TIMEOUT_MS)) {
    relayPowerOff(); mcuState = ST_STIM_OFF; healthFlags |= 0x02; sendEvent(EV_FAULT, 2);
    return;
  }

  // --- 판정 적용 ---
  if (!judgePending) return;
  portENTER_CRITICAL(&timerMux);
  Judgment j = lastJudge; judgePending = false;
  portEXIT_CRITICAL(&timerMux);
  lastCmdSeqAck = j.seq;

  uint8_t target = j.targetLevel; if (target > MAX_LEVEL) target = MAX_LEVEL;   // clamp

  // STOP: 항상 즉시
  if (j.action == ACT_STOP) { stopSession(EV_SESSION_STOP); return; }
  // DECREASE 또는 목표<현재: 항상 즉시(fail-safe 방향)
  if (j.action == ACT_DECREASE || target < currentLevel) {
    if (target < currentLevel) relayStepDown(currentLevel - target);
    else if (currentLevel > 0) relayStepDown(1);
    return;
  }
  // HOLD
  if (j.action == ACT_HOLD || target == currentLevel) return;
  // INCREASE: 게이트 통과 시만
  if (j.action == ACT_INCREASE || target > currentLevel) {
    bool stale = (now - j.rxMs > T_STALE_MS) ||
                 (stimCounter > j.stimIdxRef + STALE_STIM_LAG);
    bool safeState = (mcuState == ST_RUNNING) && stimOn;
    bool relOk = (j.reliability != REL_LOW);
    if (stale || !safeState || !relOk) return;               // 증가 거부(안전)
    uint8_t step = target - currentLevel;
    if (step > MAX_STEP_PER_JUDGMENT) step = MAX_STEP_PER_JUDGMENT;   // 변화율 제한
    if (currentLevel + step > MAX_LEVEL) step = MAX_LEVEL - currentLevel;
    relayStepUp(step);
  }
}

// ============================================================
// 업링크: EPOCH / STATUS / EVENT (바이너리 v0.1)
// ============================================================
void writeHeader(uint8_t* b, uint8_t type) {
  b[0]=PROTOCOL_VERSION; b[1]=type; put_u16(b+2, upSeq++); put_u16(b+4, sessionId);
}
void sendEpoch(int* samples, int n, int spike, float p2p, uint8_t flags,
               uint32_t stimIdx, uint32_t tMs, uint32_t sampleIdx) {
  if (!deviceConnected || upChar == nullptr) return;
  if (n > MW_WINDOW_LEN) n = MW_WINDOW_LEN;
  // 헤더6 + stimIdx4 + tMs4 + sampleIdx4 + spike2 + p2p2 + flags1 + n1 + samples(2n) + crc1
  //   = 24 + 2n + 1. 1kHz(n=14) 에서 53B — MTU 247 이내.
  // t_ms 와 sample_idx 를 함께 보내는 이유: 폰이 sample_idx/fs 와 (t_ms − 세션t0) 를 비교해
  //   샘플링 지연을 직접 측정할 수 있다. 한쪽만 있으면 시간축이 밀려도 탐지할 방법이 없다.
  uint8_t buf[6+4+4+4+2+2+1+1 + 2*(MW_WINDOW_LEN) + 1];
  writeHeader(buf, MSG_EPOCH);
  put_u32(buf+6, stimIdx); put_u32(buf+10, tMs); put_u32(buf+14, sampleIdx);
  int16_t sp = (int16_t)spike; put_u16(buf+18, (uint16_t)sp);
  int16_t pp = (int16_t)p2p;   put_u16(buf+20, (uint16_t)pp);
  buf[22]=flags; buf[23]=(uint8_t)n;
  int off=24;
  for (int i=0;i<n;i++){ int16_t v=(int16_t)samples[i]; put_u16(buf+off,(uint16_t)v); off+=2; }
  buf[off]=crc8(buf, off); off++;
  upChar->setValue(buf, off); upChar->notify();
}
void sendStatus() {
  if (!deviceConnected || upChar == nullptr) return;
  uint8_t buf[6+4+1+1+1+1+2+2+1+1+1 + 1];
  writeHeader(buf, MSG_STATUS);
  put_u32(buf+6, millis());
  buf[10]=(uint8_t)mcuState;
  buf[11]=currentLevel;
  buf[12]=(stimOn?0x01:0x00);
  buf[13]=healthFlags;
  put_u16(buf+14, lastCmdSeqAck);
  put_u16(buf+16, (uint16_t)SAMPLE_RATE);
  buf[18]=(int8_t)MW_WINDOW_START_MS;
  buf[19]=(int8_t)MW_WINDOW_END_MS;
  buf[20]=MAX_LEVEL;
  buf[21]=crc8(buf,21);
  upChar->setValue(buf,22); upChar->notify();
}
void sendEvent(uint8_t evId, uint8_t detail) {
  if (!deviceConnected || upChar == nullptr) return;
  uint8_t buf[6+4+1+1+1];
  writeHeader(buf, MSG_EVENT);
  put_u32(buf+6, millis()); buf[10]=evId; buf[11]=detail; buf[12]=crc8(buf,12);
  upChar->setValue(buf,13); upChar->notify();
}

// ============================================================
// 세션 시작/정지
// ============================================================
// START = 기록의 시작이지 자극의 시작이 아니다. 자극 투입은 SC_STIM_ENABLE 로만.
//   마사지기 전원·세기는 현재 사람이 직접 조작한다. 여기서 relayPowerOn() 을 부르면
//   실물은 그대로인데 stimOn 만 true 가 되어, INCREASE 게이트의 safeState 가 거짓으로
//   통과하고 STIM_TIMEOUT_MS 마다 헛된 EV_FAULT 가 뜬다.
void startSession() {
  actClear();
  sessionId++;                                 // 새 세션 → 폰이 running-max/baseline 리셋
  systemRunning = true; mcuState = ST_CALIBRATING;
  sessionStartedAtMs = millis(); lastDownlinkMs = millis();
  dcOffset = DC_OFFSET_FALLBACK; dcCalibrationSum=0; dcCalibrationCount=0; dcCalibrating=true;
  healthFlags = 0;
  portENTER_CRITICAL(&timerMux);
  rawSampleCounter=0; stimCounter=0;
  mwCapturing=false; mwSampleCount=0; mwSampleCountRdy=0; mwReady=false;
  mwArtifactSeen=false; mwArtifactAtSample=0; mwArtifactEMA=MW_ADAPT_EMA0; mwArtifactPeak=0;
  mwArtifactAtMs=0; mwStimSampleRdy=0; mwStimTimeMsRdy=0; mwStimIndexRdy=0;
  mwSpikeSat=false; mwWinSat=false; mwSpikeSatRdy=false; mwWinSatRdy=false;
  judgePending=false;
  portEXIT_CRITICAL(&timerMux);
  currentLevel = 0;
  stimOn = false;                              // 로그 전용으로 출발
  // ST_CALIBRATING 을 유지한다 — DC 캘리브가 끝나야 loop 이 ST_RUNNING 으로 올리고
  // EV_CALIB_DONE 을 보낸다. v0.1 은 여기서 곧장 ST_RUNNING 이라 두 값이 다 죽어 있었다.
  sendEvent(EV_SESSION_START, 0);              // 이 패킷의 t_ms 가 폰의 세션 t0
}
void stopSession(uint8_t evReason) {
  systemRunning = false; mcuState = ST_IDLE;
  // 켜지도 않은 전원에 2초 롱프레스를 넣지 않는다 — 배선이 끝나면 그게 오히려 켜버린다.
  if (stimOn) relayPowerOff(); else actClear();
  sendEvent(evReason, 0);
}

// 다운링크 세션 명령 실행 — loop 에서만 호출된다(BLE 콜백에서 릴레이·notify 금지).
void serviceSessionCmd() {
  if (!pendingSessionCmd) return;
  portENTER_CRITICAL(&timerMux);          // 읽기+소거를 원자적으로 — 그 사이 도착분 유실 방지
  uint8_t cmd = pendingSessionCmd;
  pendingSessionCmd = 0;
  portEXIT_CRITICAL(&timerMux);
  switch (cmd) {
    case SC_REQUEST_START:
      if (!systemRunning) startSession();          // 이미 돌고 있으면 무시(멱등)
      break;
    case SC_REQUEST_STOP:
      stopSession(EV_SESSION_STOP);
      break;
    case SC_STIM_ENABLE:
      // 자극 투입은 세션이 정상 진행 중일 때만. 항상 레벨 0에서 출발한다.
      if (systemRunning && mcuState == ST_RUNNING && !stimOn) { currentLevel = 0; relayPowerOn(); }
      break;
    case SC_STIM_DISABLE:
      if (stimOn) relayPowerOff();
      break;
  }
}

// ============================================================
// SETUP
// ============================================================
void setup() {
  Serial.begin(115200); delay(200);
  Serial.println("\n=== RE:FIT FES Controller (Phase1 thin-MCU) ===");

  pinMode(PIN_STATUS_LED, OUTPUT);
  pinMode(PIN_MASSAGER_ON_OFF, OUTPUT); pinMode(PIN_MASSAGER_MODE, OUTPUT);
  pinMode(PIN_MASSAGER_UP, OUTPUT);     pinMode(PIN_MASSAGER_DOWN, OUTPUT);
  digitalWrite(PIN_MASSAGER_ON_OFF, LOW); digitalWrite(PIN_MASSAGER_MODE, LOW);
  digitalWrite(PIN_MASSAGER_UP, LOW);     digitalWrite(PIN_MASSAGER_DOWN, LOW);

  analogReadResolution(12);
  setupBLE();

  xTaskCreatePinnedToCore(samplingTask, "emg_sampling", 4096, nullptr,
                          configMAX_PRIORITIES-1, &samplingTaskHandle, 1);

#if defined(ESP_ARDUINO_VERSION_MAJOR) && ESP_ARDUINO_VERSION_MAJOR >= 3
  sampleTimer = timerBegin(1000000);
  timerAttachInterrupt(sampleTimer, &onSampleTimer);
  timerAlarm(sampleTimer, US_PER_SAMPLE, true, 0);       // SAMPLE_RATE 유도
#else
  sampleTimer = timerBegin(0, 80, true);
  timerAttachInterrupt(sampleTimer, &onSampleTimer, true);
  timerAlarmWrite(sampleTimer, US_PER_SAMPLE, true);
  timerAlarmEnable(sampleTimer);
#endif

  digitalWrite(PIN_STATUS_LED, HIGH);
  Serial.printf("=== 준비 완료 (BLE 광고, fs=%dHz, MW창 +%d~+%dms=%d표본) ===\n",
                SAMPLE_RATE, MW_WINDOW_START_MS, MW_WINDOW_END_MS, MW_WINDOW_LEN);
}

void setupBLE() {
  NimBLEDevice::init(BLE_DEVICE_NAME);
  NimBLEDevice::setPower(ESP_PWR_LVL_P9);
  NimBLEDevice::setMTU(247);
  NimBLEServer* s = NimBLEDevice::createServer();
  s->setCallbacks(new ServerCallbacks());
  NimBLEService* svc = s->createService(SERVICE_UUID);
  upChar = svc->createCharacteristic(CHAR_UP_UUID, NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY);
  downChar = svc->createCharacteristic(CHAR_DOWN_UUID, NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR);
  downChar->setCallbacks(new DownCallbacks());
  svc->start();
  NimBLEAdvertising* adv = NimBLEDevice::getAdvertising();
  adv->addServiceUUID(SERVICE_UUID); adv->setName(BLE_DEVICE_NAME);
  adv->enableScanResponse(true); adv->start();
  Serial.printf("✅ BLE: %s  (UP notify %s / DOWN write %s)\n", BLE_DEVICE_NAME, CHAR_UP_UUID, CHAR_DOWN_UUID);
}

// ============================================================
// LOOP — 비블로킹. 에폭 방출 · STATUS 하트비트 · 안전감독 · 액추에이터.
// ============================================================
unsigned long lastStatusMs = 0;
void loop() {
  digitalWrite(PIN_STATUS_LED, deviceConnected ? HIGH : ((millis()/500)%2));

  // onDisconnect 후처리(블로킹 없이)
  if (needFailSafe) { needFailSafe=false; if (stimOn) relayPowerOff(); mcuState = systemRunning?ST_SAFE_HOLD:ST_IDLE; }
  if (needRestartAdv) { needRestartAdv=false; NimBLEDevice::getAdvertising()->start(); }

  // ---- M-wave 에폭 완료 → 패킷 방출 ----
  if (mwReady) {
    portENTER_CRITICAL(&timerMux);
    mwReady = false;
    int n = mwSampleCountRdy; int spike = mwSpikeRdy;
    uint32_t stimIdx = mwStimIndexRdy; uint32_t tMs = mwStimTimeMsRdy;
    uint32_t sampleIdx = mwStimSampleRdy;
    bool satSpike = mwSpikeSatRdy, satWin = mwWinSatRdy;
    int snap[MW_WINDOW_LEN + 4];
    for (int i=0;i<n && i<MW_WINDOW_LEN+4;i++) snap[i]=mwSamplesRdy[i];
    portEXIT_CRITICAL(&timerMux);

    if (n >= 3) {
      int mn=snap[0], mx=snap[0];
      for (int i=0;i<n;i++){ if(snap[i]<mn)mn=snap[i]; if(snap[i]>mx)mx=snap[i]; }
      float p2p = (float)(mx - mn);
      uint8_t flags = 0;
      if (p2p >= MW_AMP_MIN) flags |= 0x01;               // bit0 valid
      if (satWin)   flags |= 0x02;                        // bit1 창 포화 → 면적 과소평가
      if (satSpike) flags |= 0x04;                        // bit2 스파이크 포화 → R 분모 상수화
      // (bit3 baseline_ok 는 후속 확장)
      sendEpoch(snap, n, spike, p2p, flags, stimIdx, tMs, sampleIdx);
    }
  }

  // ---- STATUS 하트비트 (5Hz) ----
  if (millis() - lastStatusMs >= STATUS_PERIOD_MS) { lastStatusMs = millis(); sendStatus(); }

  // ---- DC 캘리브 완료 → RUNNING 승격 ----
  if (systemRunning && mcuState == ST_CALIBRATING && !dcCalibrating) {
    mcuState = ST_RUNNING;
    sendEvent(EV_CALIB_DONE, (uint8_t)(dcOffset >> 4));   // detail: 측정된 오프셋 상위비트
  }

  // ---- 세션 명령 + 안전 감독 + 릴레이 액추에이터 (구동은 전부 여기, BLE 콜백 아님) ----
  serviceSessionCmd();
  safetySupervisor();
  actuatorService();

  // (물리 버튼으로 세션 시작하려면 여기서 버튼 폴링 → startSession(). 앱 시작은 SESSION_CONTROL.)

  vTaskDelay(1);   // BLE/IDLE 양보 (delay() 대신 — 다른 태스크 굶기지 않음)
}
