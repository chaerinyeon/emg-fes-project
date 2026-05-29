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

// ===== BLE UUID (Nordic UART Service 호환) =====
#define SERVICE_UUID     "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
#define CHAR_DATA_UUID   "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"
#define CHAR_CMD_UUID    "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
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
const int FFT_SIZE = 256;                  // FFT 윈도우 (256ms 분량)
const int RMS_WINDOW = 1000;               // RMS 윈도우 (1초)
const int HISTORY_SIZE = 60;               // 60초 분량 RMS/MDF 히스토리

// 임계값 (방식 3: 이중 조건)
float RMS_THRESHOLD = 20.0;                // RMS slope +20% 이상
float MDF_THRESHOLD = -3.0;                // MDF slope -3% 이하 (노이즈 감안 완화)
const int CONSECUTIVE_TRIGGER = 5;
const int DC_OFFSET = 1900;                // 본인 베이스라인으로 조정

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
const int MW_ARTIFACT_THRESHOLD = 1500;
const int MW_WINDOW_START_MS = 5;             // 자극 후 ms (artifact 제외용 dead-zone)
const int MW_WINDOW_END_MS = 30;              // 자극 후 ms
const int MW_WINDOW_LEN = (MW_WINDOW_END_MS - MW_WINDOW_START_MS) + 1;  // 26 샘플 (1kHz)
const unsigned long MW_REFRACTORY_MS = 40;    // 같은 자극 중복 트리거 방지 (FES ≤ 25Hz 가정)

// ===== BLE 핸들 =====
NimBLECharacteristic* dataChar = nullptr;
NimBLECharacteristic* cmdChar  = nullptr;
volatile bool deviceConnected = false;

// ===== ADC 버퍼 (샘플링 태스크가 채움) =====
volatile int rawBuffer[RMS_WINDOW];
volatile int bufferIdx = 0;
volatile bool bufferReady = false;

// 실시간 envelope (|raw - DC| 의 1차 IIR LPF, 1kHz로 갱신)
// alpha=0.03 → 1kHz에서 약 5Hz LPF, 힘 줄 때 100~200ms 안에 따라옴
volatile float envLPF = 0;
const float ENV_LPF_ALPHA = 0.03f;

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
bool sendFullNext = true;   // 다음 송신을 "full"로 (1초마다 RMS/MDF 등 포함)

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
volatile int mwSamples[MW_WINDOW_LEN + 4];     // +여유
volatile bool mwReady = false;                 // 캡처 완료 → loop()에서 메트릭 계산
float currentMwAmp = 0;                        // peak-to-peak (ADC counts)
float currentMwArea = 0;                       // Σ|sample| (정류 면적)
float currentMwLatency = 0;                    // artifact 후 peak까지 ms
bool mwDirty = false;                          // 새 M-wave가 있어 다음 송신 포함
uint32_t mwCount = 0;                          // 세션 누적 M-wave 검출 수

// ===== 최신 계산값 =====
float currentRMS = 0;
float currentMDF = 0;
float currentRMSSlope = 0;
float currentMDFSlope = 0;
bool  currentFatigueDetected = false;

float baselineRMS = 0;
bool  baselineReady = false;
float rmsRatio = 1.0;
String muscleState = "idle";
String sessionMarker = "";

// ===== 타이머 =====
hw_timer_t* sampleTimer = nullptr;
portMUX_TYPE timerMux = portMUX_INITIALIZER_UNLOCKED;
TaskHandle_t samplingTaskHandle = nullptr;

// 함수 선언
void triggerStimulation(bool on);
void handleCommand(JsonDocument& doc);
void updateContractionState();
void samplingTask(void* param);

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

    // 실시간 envelope 업데이트 (정류 + IIR LPF) — 버퍼와 무관하게 항상 갱신
    int absVal = centered < 0 ? -centered : centered;
    envLPF = ENV_LPF_ALPHA * (float)absVal + (1.0f - ENV_LPF_ALPHA) * envLPF;

    // ===== M-wave: 자극 artifact 감지 + 윈도우 캡처 =====
    // 자극 중에만, refractory 경과 후 큰 스파이크가 들어오면 artifact로 간주.
    // artifact 시점부터 5~30ms 동안 centered 샘플을 버퍼에 모음 → loop에서 메트릭 계산.
    {
      unsigned long nowMs = millis();
      if (isStimulating && !mwCapturing &&
          absVal > MW_ARTIFACT_THRESHOLD &&
          (nowMs - mwArtifactAtMs) > MW_REFRACTORY_MS) {
        mwArtifactAtMs = nowMs;
        mwCapturing = true;
        mwSampleCount = 0;
      }
      if (mwCapturing) {
        unsigned long since = nowMs - mwArtifactAtMs;
        if (since >= (unsigned long)MW_WINDOW_START_MS &&
            since <= (unsigned long)MW_WINDOW_END_MS) {
          if (mwSampleCount < MW_WINDOW_LEN) {
            mwSamples[mwSampleCount++] = centered;
          }
        } else if (since > (unsigned long)MW_WINDOW_END_MS) {
          mwCapturing = false;
          mwReady = true;
        }
      }
    }

    if (bufferIdx >= RMS_WINDOW) continue;

    portENTER_CRITICAL(&timerMux);
    if (bufferIdx < RMS_WINDOW) {
      rawBuffer[bufferIdx] = centered;
      bufferIdx++;
      if (bufferIdx >= RMS_WINDOW) bufferReady = true;
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

  // 1kHz ADC 타이머 (ESP32 core 2.0.x API)
  sampleTimer = timerBegin(0, 80, true);                  // timer0, prescaler 80 → 1MHz tick
  timerAttachInterrupt(sampleTimer, &onSampleTimer, true);
  timerAlarmWrite(sampleTimer, 1000, true);               // 1000us = 1kHz
  timerAlarmEnable(sampleTimer);

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

  if (bufferReady) {
    portENTER_CRITICAL(&timerMux);
    bufferReady = false;
    bufferIdx = 0;
    portEXIT_CRITICAL(&timerMux);

    // RMS 계산
    currentRMS = calculateRMS();

    // MDF 계산
    currentMDF = calculateMDF();

    // 히스토리 추가
    rmsHistory[historyIdx] = currentRMS;
    mdfHistory[historyIdx] = currentMDF;
    historyIdx = (historyIdx + 1) % HISTORY_SIZE;
    if (historyCount < HISTORY_SIZE) historyCount++;

    // 30초치 모이면 slope + 임계값 검사
    if (historyCount >= 30) {
      currentRMSSlope = calculateSlopePercent(rmsHistory, historyCount, true);
      currentMDFSlope = calculateSlopePercent(mdfHistory, historyCount, true);

      bool fatigueCondition = (currentRMSSlope > RMS_THRESHOLD) &&
                              (currentMDFSlope < MDF_THRESHOLD);

      if (systemRunning && fatigueCondition) {
        consecutiveCount++;
        if (consecutiveCount >= CONSECUTIVE_TRIGGER && !currentFatigueDetected) {
          Serial.printf("⚠️ 근피로 감지! RMS:+%.1f%%, MDF:%.1f%% (FES %s)\n",
                        currentRMSSlope, currentMDFSlope,
                        isStimulating ? "ON→OFF" : "미가동");
          currentFatigueDetected = true;
          fatigueDetectedAtMs = millis();
          // 다음 BLE 송신을 즉시 full로 → Flutter에서 fd 상승 에지 놓치지 않음
          sendFullNext = true;
          // FES가 켜져 있을 때만 자동 정지
          if (isStimulating) {
            triggerStimulation(false);
          }
        }
      } else {
        consecutiveCount = 0;
      }

      // 피로 플래그는 FATIGUE_LATCH_MS 동안 유지 (UI 다이얼로그/배너 안정용)
      if (currentFatigueDetected &&
          (millis() - fatigueDetectedAtMs > FATIGUE_LATCH_MS)) {
        currentFatigueDetected = false;
      }
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

    // 수축 상태머신 업데이트 (RMS·MDF 계산 직후)
    updateContractionState();

    // 다음 BLE 송신은 1Hz 갱신값 전부 포함하는 "full" 메시지로
    sendFullNext = true;
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
      mwDirty = true;
      mwCount++;
    }
  }

  // BLE 송신은 100ms마다 (DATA_THROTTLE_MS 내부 체크 사용)
  // → env(실시간 LPF)는 10Hz로, rms/mdf는 매번 같은 값(1Hz 갱신)으로 송신
  sendDataUpdate();

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
    // M-wave 카운터/상태 리셋
    mwCount = 0;
    mwCapturing = false;
    mwSampleCount = 0;
    mwReady = false;
    mwDirty = false;
    mwArtifactAtMs = 0;
    currentMwAmp = 0;
    currentMwArea = 0;
    currentMwLatency = 0;
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
float calculateRMS() {
  // 1) 윈도우 평균 (남은 DC 성분 제거용)
  long sum = 0;
  int rawMin = 4095, rawMax = -4095;
  for (int i = 0; i < RMS_WINDOW; i++) {
    int v = rawBuffer[i];
    sum += v;
    if (v < rawMin) rawMin = v;
    if (v > rawMax) rawMax = v;
  }
  double mean = (double)sum / RMS_WINDOW;

  // 2) 평균 제거 후 RMS
  double sumSq = 0;
  for (int i = 0; i < RMS_WINDOW; i++) {
    double d = (double)rawBuffer[i] - mean;
    sumSq += d * d;
  }
  double rms = sqrt(sumSq / RMS_WINDOW);

  Serial.printf("[DIAG] RAW min=%d max=%d mean=%.0f | RMS=%.1f env=%.1f\n",
                rawMin + DC_OFFSET, rawMax + DC_OFFSET,
                mean + DC_OFFSET, rms, envLPF);
  return (float)rms;
}

// ============================================================
// MDF 계산 (RAW 핀 FFT)
// ============================================================
float calculateMDF() {
  for (int i = 0; i < FFT_SIZE; i++) {
    vReal[i] = (double)rawBuffer[i];
    vImag[i] = 0;
  }
  FFT.windowing(FFTWindow::Hamming, FFTDirection::Forward);
  FFT.compute(FFTDirection::Forward);
  FFT.complexToMagnitude();

  float totalPower = 0;
  for (int i = 1; i < FFT_SIZE / 2; i++) {
    totalPower += vReal[i];
  }
  float halfPower = totalPower / 2.0;
  float cumPower = 0;
  for (int i = 1; i < FFT_SIZE / 2; i++) {
    cumPower += vReal[i];
    if (cumPower >= halfPower) {
      return (float)i * SAMPLE_RATE / FFT_SIZE;
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
// 매 100ms마다 호출되지만 메시지 종류는 두 가지:
//   - partial (9/sec): env + 빠르게 바뀔 수 있는 상태만
//   - full    (1/sec): partial + 1Hz 갱신값(RMS/MDF/slope/state machine 등)
// Flutter는 null 필드를 스킵하므로 partial 메시지는 큐 중복을 만들지 않음.
// ============================================================
void sendDataUpdate() {
  if (!deviceConnected || dataChar == nullptr) return;

  unsigned long now = millis();
  if (now - lastNotifyMs < DATA_THROTTLE_MS) return;
  lastNotifyMs = now;

  bool full = sendFullNext;
  sendFullNext = false;
  bool hasMarker = sessionMarker.length() > 0;

  StaticJsonDocument<512> doc;

  // ===== 항상 보내는 필드 (10Hz) =====
  doc["ts"]   = now;
  doc["env"]  = envLPF;
  doc["run"]  = systemRunning;
  doc["stim"] = isStimulating;
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
    doc["mwn"] = mwCount;
    mwDirty = false;
  }

  // ===== full 메시지에만 (1Hz) =====
  if (full) {
    doc["rms"]  = currentRMS;
    doc["mdf"]  = currentMDF;
    doc["rs"]   = currentRMSSlope;
    doc["ms"]   = currentMDFSlope;
    doc["hc"]   = historyCount;
    doc["cc"]   = consecutiveCount;
    doc["b"]    = baselineRMS;
    doc["rr"]   = rmsRatio;
    doc["st"]   = muscleState;

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