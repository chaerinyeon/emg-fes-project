/*
  EMG-FES Closed-Loop Controller
  
  분석 방법: RAW + MDF 결합 (방식 3 - 이중 조건)
  - RMS slope > +20% AND MDF slope < -10% → 피로 판정
  
  하드웨어:
  - MyoWare 2.0 Wireless Shield (ESP32 내장)
  - MyoWare 2.0 Muscle Sensor + 전극
  - PC817 + IRLZ44N → 오므론 HV-F022-V (추후 연결)
  
  통신: WiFi 핫스팟 → WebSocket (port 81)
*/

#include <WiFi.h>
#include <ESPmDNS.h>
#include <WebSocketsServer.h>
#include <ArduinoJson.h>
#include <arduinoFFT.h>
#include "secrets.h"

// ===== 핀 설정 =====
const int PIN_EMG_RAW = 36;     // A4 - RAW EMG
const int PIN_EMG_ENV = 39;     // A3 - ENV (참조용)
const int PIN_STATUS_LED = 13;

const int PIN_MASSAGER_ON_OFF = 32;
const int PIN_MASSAGER_MODE   = 33;
const int PIN_MASSAGER_UP     = 25;
const int PIN_MASSAGER_DOWN   = 26;

// ===== 신호처리 파라미터 =====
const int SAMPLE_RATE = 1000;              // 1kHz 샘플링
const int FFT_SIZE = 256;                  // FFT 윈도우 (256ms)
const int RMS_WINDOW = 1000;               // RMS 윈도우 (1초)
const int HISTORY_SIZE = 60;               // 60초 분량 히스토리

// 임계값 (방식 3: 이중 조건)
float RMS_THRESHOLD = 20.0;     // RMS slope +20% 이상
float MDF_THRESHOLD = -3.0;     // MDF slope -3% 이하 (완화: MDF 노이즈 감안)
const int CONSECUTIVE_TRIGGER = 5;
const int DC_OFFSET = 1900;     // 측정 후 본인 베이스라인으로 조정

// 베이스라인 (FES 응답 기준)
const int BASELINE_SAMPLES = 10;       // Start 후 10초간 베이스라인 수집 (FES OFF)
const float MUSCLE_LOW_RATIO  = 0.7;   // 베이스라인 대비 70% 미만 → 저운동
const float MUSCLE_HIGH_RATIO = 1.5;   // 베이스라인 대비 150% 초과 → 과운동

// ===== 전역 변수 =====
WebSocketsServer webSocket = WebSocketsServer(81);

// 1초 RMS 버퍼
volatile int rawBuffer[RMS_WINDOW];
volatile int envBuffer[RMS_WINDOW];
volatile int bufferIdx = 0;
volatile bool bufferReady = false;

// FFT용 버퍼
double vReal[FFT_SIZE];
double vImag[FFT_SIZE];
ArduinoFFT<double> FFT = ArduinoFFT<double>(vReal, vImag, FFT_SIZE, SAMPLE_RATE);

// 히스토리 (선형회귀용)
float rmsHistory[HISTORY_SIZE];
float mdfHistory[HISTORY_SIZE];
int historyIdx = 0;
int historyCount = 0;

// 시스템 상태
bool systemRunning = false;
bool isStimulating = false;
int consecutiveCount = 0;
unsigned long stimStartTime = 0;
const unsigned long STIM_TIMEOUT_MS = 180000;  // 3분 (피로 검출 시간 확보)

// 타이머
hw_timer_t* sampleTimer = nullptr;
portMUX_TYPE timerMux = portMUX_INITIALIZER_UNLOCKED;

// 최신 계산값 (전송용)
float currentRMS = 0;
float currentMDF = 0;
float currentRMSSlope = 0;
float currentMDFSlope = 0;
bool currentFatigueDetected = false;

// 베이스라인 + 상태 분류
float baselineRMS = 0;
bool  baselineReady = false;
float rmsRatio = 1.0;
String muscleState = "idle";   // idle | calibrating | low | normal | high | fatigue

// 세션 마커 (CSV 저장용)
String sessionMarker = "";

// ============================================================
// 1ms 타이머 인터럽트 - ADC 샘플링
// ============================================================
void IRAM_ATTR onSampleTimer() {
  portENTER_CRITICAL_ISR(&timerMux);
  
  if (bufferIdx < RMS_WINDOW) {
    int raw = analogRead(PIN_EMG_RAW);
    int env = analogRead(PIN_EMG_ENV);
    rawBuffer[bufferIdx] = raw - DC_OFFSET;
    envBuffer[bufferIdx] = env;
    bufferIdx++;

    if (bufferIdx >= RMS_WINDOW) {
      bufferReady = true;
    }
  }
  
  portEXIT_CRITICAL_ISR(&timerMux);
}

// ============================================================
// SETUP
// ============================================================
void setup() {
  Serial.begin(115200);
  delay(1000);
  Serial.println("\n=== EMG-FES Controller (RAW+MDF) ===");
  
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
  
  // ADC 해상도
  analogReadResolution(12);
  
  // WiFi 연결
  setupWiFi();
  
  // WebSocket 시작
  webSocket.begin();
  webSocket.onEvent(onWebSocketEvent);
  Serial.println("WebSocket 서버 시작 (포트 81)");
  
  // 1ms 타이머 시작 (1kHz 샘플링) - ESP32 core 2.0.x API
  sampleTimer = timerBegin(0, 80, true);                   // timer 0, 분주 80 → 1MHz (1us tick)
  timerAttachInterrupt(sampleTimer, &onSampleTimer, true);  // ISR 등록 (edge)
  timerAlarmWrite(sampleTimer, 1000, true);                // 1000us = 1ms = 1kHz, 자동 반복
  timerAlarmEnable(sampleTimer);                           // 타이머 활성화
  
  digitalWrite(PIN_STATUS_LED, HIGH);
  Serial.println("=== 준비 완료 ===\n");
}

// ============================================================
// LOOP
// ============================================================
void loop() {
  webSocket.loop();
  
  // 버퍼가 가득차면 (1초마다) RMS + MDF 계산
  if (bufferReady) {
    portENTER_CRITICAL(&timerMux);
    bufferReady = false;
    bufferIdx = 0;  // 다음 1초 측정 시작 (overlap 안 함, 단순화)
    portEXIT_CRITICAL(&timerMux);
    
    // RMS 계산
    currentRMS = calculateRMS();
    
    // MDF 계산 (FFT)
    currentMDF = calculateMDF();
    
    // 히스토리에 추가
    rmsHistory[historyIdx] = currentRMS;
    mdfHistory[historyIdx] = currentMDF;
    historyIdx = (historyIdx + 1) % HISTORY_SIZE;
    if (historyCount < HISTORY_SIZE) historyCount++;
    
    // 30초 분량 모이면 slope 계산 + 임계값 검사
    if (historyCount >= 30) {
      currentRMSSlope = calculateSlopePercent(rmsHistory, historyCount, true);
      currentMDFSlope = calculateSlopePercent(mdfHistory, historyCount, true);

      // 방식 3: 이중 조건
      bool fatigueCondition = (currentRMSSlope > RMS_THRESHOLD) &&
                              (currentMDFSlope < MDF_THRESHOLD);

      if (systemRunning && fatigueCondition) {
        consecutiveCount++;
        if (consecutiveCount >= CONSECUTIVE_TRIGGER && isStimulating) {
          Serial.printf("⚠️ 근피로 감지! RMS slope: +%.1f%%, MDF slope: %.1f%%\n",
                        currentRMSSlope, currentMDFSlope);
          currentFatigueDetected = true;
          triggerStimulation(false);
        }
      } else {
        consecutiveCount = 0;
        currentFatigueDetected = false;
      }
    }

    // 베이스라인 수집 + 상태 분류
    if (systemRunning && !baselineReady && historyCount >= BASELINE_SAMPLES) {
      float sum = 0;
      for (int i = 0; i < BASELINE_SAMPLES; i++) sum += rmsHistory[i];
      baselineRMS = sum / BASELINE_SAMPLES;
      baselineReady = true;
      Serial.printf("✅ Baseline RMS: %.1f (%d s 평균)\n", baselineRMS, BASELINE_SAMPLES);
    }

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

    // 데이터 전송 (CSV 저장용 + Flutter용)
    sendDataUpdate();
  }
  
  // 자극 타임아웃 (안전장치)
  if (isStimulating && (millis() - stimStartTime > STIM_TIMEOUT_MS)) {
    Serial.println("⏰ 자극 시간 초과");
    triggerStimulation(false);
  }
}

// ============================================================
// WiFi 연결
// ============================================================
void setupWiFi() {
  Serial.print("WiFi 연결 중");
  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
  
  int attempts = 0;
  while (WiFi.status() != WL_CONNECTED) {
    delay(500);
    Serial.print(".");
    if (++attempts > 40) {
      Serial.println("\n❌ WiFi 실패");
      while(1) delay(1000);
    }
  }
  Serial.println();
  Serial.print("✅ IP: ");
  Serial.println(WiFi.localIP());

  if (MDNS.begin("emg-fes")) {
    MDNS.addService("ws", "tcp", 81);
    Serial.println("✅ mDNS: emg-fes.local");
  } else {
    Serial.println("⚠️ mDNS 시작 실패");
  }
}

// ============================================================
// WebSocket 이벤트
// ============================================================
void onWebSocketEvent(uint8_t num, WStype_t type, uint8_t* payload, size_t length) {
  switch (type) {
    case WStype_CONNECTED:
      Serial.printf("[%u] 연결됨\n", num);
      break;
    case WStype_DISCONNECTED:
      Serial.printf("[%u] 해제\n", num);
      if (isStimulating) triggerStimulation(false);
      break;
    case WStype_TEXT: {
      StaticJsonDocument<256> doc;
      if (deserializeJson(doc, payload)) return;
      handleCommand(doc);
      break;
    }
    default: break;
  }
}

// ============================================================
// 명령 처리
// ============================================================
void handleCommand(JsonDocument& doc) {
  String cmd = doc["cmd"].as<String>();
  
  if (cmd == "start") {
    systemRunning = true;
    consecutiveCount = 0;
    historyIdx = 0;
    historyCount = 0;
    currentFatigueDetected = false;
    currentRMSSlope = 0;
    currentMDFSlope = 0;
    baselineReady = false;           // 베이스라인 새로 수집
    baselineRMS = 0;
    rmsRatio = 1.0;
    muscleState = "calibrating";
    sessionMarker = "session_start";
    Serial.println("→ 시작 (10초간 베이스라인 수집, FES OFF)");
    triggerStimulation(false);       // 베이스라인은 전류 없이 측정
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
    // 측정 중 본인이 "지금 힘들다" 같은 마커 추가
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
    Serial.println("→ 캘리브레이션 (베이스라인 리셋)");
  }
  else if (cmd == "set_thresholds") {
    RMS_THRESHOLD = doc["rms"].as<float>();
    MDF_THRESHOLD = doc["mdf"].as<float>();
    Serial.printf("→ 임계값: RMS +%.1f%%, MDF %.1f%%\n", RMS_THRESHOLD, MDF_THRESHOLD);
  }
}

// ============================================================
// 마사지기 제어
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
    delay(150);
    digitalWrite(PIN_MASSAGER_ON_OFF, LOW);
    isStimulating = false;
    Serial.println("🔌 마사지기 OFF");
  }
}

// ============================================================
// RMS 계산 (envelope 기반)
// ============================================================
float calculateRMS() {
  double sumSq = 0;
  for (int i = 0; i < RMS_WINDOW; i++) {
    sumSq += (double)envBuffer[i] * envBuffer[i];
  }
  return sqrt(sumSq / RMS_WINDOW);
}

// ============================================================
// MDF 계산 (FFT)
// ============================================================
float calculateMDF() {
  // 1초 버퍼에서 FFT_SIZE만큼만 사용
  for (int i = 0; i < FFT_SIZE; i++) {
    vReal[i] = (double)rawBuffer[i];
    vImag[i] = 0;
  }
  
  FFT.windowing(FFTWindow::Hamming, FFTDirection::Forward);
  FFT.compute(FFTDirection::Forward);
  FFT.complexToMagnitude();
  
  // 누적 파워가 50%가 되는 주파수 찾기
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
// 데이터 전송
// ============================================================
void sendDataUpdate() {
  if (webSocket.connectedClients() == 0) return;
  
  StaticJsonDocument<512> doc;
  doc["type"] = "data";
  doc["timestamp_ms"] = millis();
  doc["emg_raw"] = rawBuffer[RMS_WINDOW - 1] + DC_OFFSET;  // 마지막 raw 값
  doc["emg_env"] = analogRead(PIN_EMG_ENV);                // 평활화된 envelope
  doc["rms"] = currentRMS;
  doc["mdf"] = currentMDF;
  doc["rms_slope"] = currentRMSSlope;
  doc["mdf_slope"] = currentMDFSlope;
  doc["fatigue_detected"] = currentFatigueDetected;
  doc["is_running"] = systemRunning;
  doc["is_stimulating"] = isStimulating;
  doc["history_count"] = historyCount;
  doc["marker"] = sessionMarker;
  doc["baseline_rms"] = baselineRMS;
  doc["rms_ratio"] = rmsRatio;
  doc["muscle_state"] = muscleState;
  
  String json;
  serializeJson(doc, json);
  webSocket.broadcastTXT(json);
  
  sessionMarker = "";  // 마커는 한 번만 전송
}