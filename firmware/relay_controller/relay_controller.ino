/*
  Relay Controller (BLE) — 마사지기 UP/DOWN 릴레이 제어 (EMG-FES 와 무관한 독립 ESP)

  emg_fes_controller.ino 와 별개로 동작하는 단독 릴레이 컨트롤러.
  Flutter 앱이 EMG-FES 기기와 동일한 방식으로 스캔·연결한 뒤(같은 서비스 UUID),
  cmd 특성으로 {"cmd":"up"} / {"cmd":"down"} 을 보내면 해당 릴레이를 0.3초 펄스.
  USB 시리얼로 "up" / "down" 입력해도 동일하게 동작(테스트용).

  - UP_RELAY_PIN   17
  - DOWN_RELAY_PIN 16
  - Active LOW 릴레이 (HIGH = OFF, LOW = ON)

  필요 라이브러리: NimBLE-Arduino (h2zero, v2.x), ArduinoJson
*/

#include <NimBLEDevice.h>
#include <ArduinoJson.h>

// ===== BLE UUID — 앱(EMG-FES)과 동일한 Nordic UART Service =====
// 앱은 이 서비스 UUID 를 광고하는 기기에 연결하므로, 이름만 다르게 둔다.
#define SERVICE_UUID    "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
#define CHAR_DATA_UUID  "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"
#define CHAR_CMD_UUID   "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
#define BLE_DEVICE_NAME "RELAY-CTRL-01"

// ===== 릴레이 핀 =====
#define UP_RELAY_PIN   17
#define DOWN_RELAY_PIN 16
const unsigned long RELAY_PULSE_MS = 300;   // 릴레이 ON 유지 시간

NimBLECharacteristic* dataChar = nullptr;   // (앱 연결 요건상 생성, 알림은 ack 용도)
NimBLECharacteristic* cmdChar  = nullptr;
bool deviceConnected = false;

// ============================================================
// 릴레이 펄스 (Active LOW: LOW = ON)
// ============================================================
void pulseRelay(int pin, const char* label) {
  Serial.printf("%s Relay ON\n", label);
  digitalWrite(pin, LOW);            // 릴레이 ON
  delay(RELAY_PULSE_MS);             // 0.3초 유지
  digitalWrite(pin, HIGH);           // 릴레이 OFF
  Serial.printf("%s Relay OFF\n", label);
}

// "up" / "down" 처리 (BLE·시리얼 공용)
void handleAction(const String& action) {
  if (action == "up") {
    pulseRelay(UP_RELAY_PIN, "UP");
  } else if (action == "down") {
    pulseRelay(DOWN_RELAY_PIN, "DOWN");
  } else {
    Serial.printf("알 수 없는 명령: %s (up/down)\n", action.c_str());
  }
}

// ============================================================
// BLE 콜백 (NimBLE 2.x API)
// ============================================================
class ServerCallbacks : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer* pServer, NimBLEConnInfo& connInfo) override {
    deviceConnected = true;
    Serial.printf("✅ BLE 연결: %s\n", connInfo.getAddress().toString().c_str());
    pServer->setDataLen(connInfo.getConnHandle(), 251);
  }
  void onDisconnect(NimBLEServer* pServer, NimBLEConnInfo& connInfo, int reason) override {
    deviceConnected = false;
    Serial.printf("❌ BLE 끊김 (reason=%d) → 재광고\n", reason);
    NimBLEDevice::getAdvertising()->start();
  }
};

class CmdCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* pCharacteristic, NimBLEConnInfo& connInfo) override {
    std::string value = pCharacteristic->getValue();
    if (value.empty()) return;

    // 앱은 {"cmd":"up"} 형태 JSON 으로 보냄. (순수 "up" 문자열도 허용)
    StaticJsonDocument<128> doc;
    DeserializationError err = deserializeJson(doc, value.c_str());
    if (!err) {
      handleAction(String(doc["cmd"] | ""));
    } else {
      handleAction(String(value.c_str()));   // 평문 fallback
    }
  }
};

// ============================================================
void setupBLE() {
  NimBLEDevice::init(BLE_DEVICE_NAME);
  NimBLEDevice::setPower(ESP_PWR_LVL_P9);
  NimBLEDevice::setMTU(247);

  NimBLEServer* pServer = NimBLEDevice::createServer();
  pServer->setCallbacks(new ServerCallbacks());

  NimBLEService* pService = pServer->createService(SERVICE_UUID);

  // DATA characteristic — 앱 연결 요건상 생성(ack 알림용).
  dataChar = pService->createCharacteristic(
    CHAR_DATA_UUID,
    NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY
  );

  // CMD characteristic — Phone → ESP (write)
  cmdChar = pService->createCharacteristic(
    CHAR_CMD_UUID,
    NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR
  );
  cmdChar->setCallbacks(new CmdCallbacks());

  pService->start();

  NimBLEAdvertising* pAdv = NimBLEDevice::getAdvertising();
  pAdv->addServiceUUID(SERVICE_UUID);
  pAdv->setName(BLE_DEVICE_NAME);
  pAdv->enableScanResponse(true);
  pAdv->start();

  Serial.printf("✅ BLE 시작: name=%s\n", BLE_DEVICE_NAME);
  Serial.printf("   Service: %s\n", SERVICE_UUID);
  Serial.printf("   Cmd    : %s (write) — {\"cmd\":\"up\"} / {\"cmd\":\"down\"}\n", CHAR_CMD_UUID);
}

void setup() {
  Serial.begin(115200);

  pinMode(UP_RELAY_PIN, OUTPUT);
  pinMode(DOWN_RELAY_PIN, OUTPUT);
  digitalWrite(UP_RELAY_PIN, HIGH);     // Active LOW: HIGH = OFF
  digitalWrite(DOWN_RELAY_PIN, HIGH);

  setupBLE();

  Serial.println("명령어 입력(USB 시리얼):");
  Serial.println("up   → 17번 핀 릴레이 작동");
  Serial.println("down → 16번 핀 릴레이 작동");
}

void loop() {
  // USB 시리얼 테스트 경로 (BLE 와 동일 동작)
  if (Serial.available() > 0) {
    String input = Serial.readStringUntil('\n');
    input.trim();
    if (input.length() > 0) handleAction(input);
  }
}
