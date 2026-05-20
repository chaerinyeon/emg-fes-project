# EMG-FES 프로젝트

근피로(muscle fatigue)를 EMG 신호로 실시간 감지해 마사지기/FES 자극을 자동으로 제어하는 closed-loop 시스템.

## 분석 방법

**RAW + MDF 이중 조건** (방식 3)

- RMS slope > **+20%** **AND** MDF slope < **-3%** → 피로 판정
- 5회 연속 만족 시 마사지기 OFF

## 디렉토리 구조

```
emg-fes-project/
├── firmware/
│   └── emg_fes_controller/
│       ├── emg_fes_controller.ino          # ESP32 메인 펌웨어 (BLE 버전)
│       ├── emg_fes_controller_wifi.ino.bak # 이전 WiFi/WebSocket 버전 (백업)
│       ├── secrets.h.example               # (구) WiFi 자격증명 템플릿 — BLE 버전엔 불필요
│       └── secrets.h                       # (구, gitignore)
├── data_logger/
│   ├── emg_logger.py                # ESP32 → CSV 로거 (WiFi 버전, 추후 BLE 버전 추가 예정)
│   └── requirements.txt
├── data/
│   ├── subject_A/
│   ├── subject_B/
│   └── subject_C/
├── flutter_app/                     # 모바일 UI (BLE 클라이언트)
└── docs/
```

## 하드웨어

- **ESP32-WROOM** (MyoWare 2.0 Wireless Shield 내장, BLE 4.2 + WiFi 동시 지원)
- **MyoWare 2.0 Muscle Sensor** + 표면전극
- **PC817 + IRLZ44N** → 오므론 HV-F022-V (마사지기/FES)
- **전원**: USB-C 보조배터리 또는 LiPo 배터리 (Wireless Shield 내장 충전회로)

## 펌웨어 (ESP32 / BLE 버전)

### 1. Arduino IDE 라이브러리

Library Manager에서 설치:

- `NimBLE-Arduino` (by h2zero, **v2.x**)
- `ArduinoJson` (v6.x)
- `arduinoFFT` (v2.x)

WiFi/WebSocket 의존성은 BLE 버전에서 제거됨. `secrets.h`는 BLE 버전에선 사용되지 않음.

### 2. 업로드

`emg_fes_controller.ino` 를 ESP32 보드로 업로드.
시리얼 모니터(115200 baud)에서 BLE 광고 시작 메시지 확인.

### 3. BLE 사양

- **Device Name**: `EMG-FES-01`
- **Service UUID**: `6E400001-B5A3-F393-E0A9-E50E24DCCA9E` (Nordic UART Service 호환)
- **DATA Characteristic** (Notify, ESP32→Phone): `6E400003-...`
- **CMD Characteristic** (Write, Phone→ESP32): `6E400002-...`

NUS 호환 UUID라서 [nRF Connect](https://www.nordicsemi.com/Products/Development-tools/nRF-Connect-for-mobile) 같은 앱으로 바로 디버깅 가능.

## 데이터 송신 (BLE Notify, JSON)

매 1초마다 DATA characteristic으로 notify. 짧은 키 이름으로 압축됨:

| 키 | 의미 |
|---|---|
| `ts` | timestamp_ms |
| `raw` | 마지막 raw EMG 샘플 |
| `env` | 현재 ENV 값 |
| `rms` | 1초 RMS |
| `mdf` | 1초 MDF (Hz) |
| `rs` | RMS slope (%) |
| `ms` | MDF slope (%) |
| `fd` | fatigue_detected (bool) |
| `run` | is_running (bool) |
| `stim` | is_stimulating (bool) |
| `hc` | history_count |
| `b` | baseline_rms |
| `rr` | rms_ratio (current/baseline) |
| `st` | muscle_state (idle / calibrating / low / normal / high / fatigue) |
| `mk` | marker (이벤트 1회 전송) |

## 명령 송신 (BLE Write, JSON)

CMD characteristic에 다음 JSON을 write:

| cmd | 동작 | 예시 |
|---|---|---|
| `start` | 측정 시작 (10초 베이스라인 수집) | `{"cmd":"start"}` |
| `stop` | 측정 정지 | `{"cmd":"stop"}` |
| `emergency` | 비상정지 + FES OFF | `{"cmd":"emergency"}` |
| `marker` | 세션 마커 추가 | `{"cmd":"marker","label":"hard"}` |
| `calibrate` | 베이스라인 리셋 | `{"cmd":"calibrate"}` |
| `set_thresholds` | 임계값 갱신 | `{"cmd":"set_thresholds","rms":20,"mdf":-3}` |
| `trigger_stim` | 마사지기 수동 ON/OFF | `{"cmd":"trigger_stim","on":true}` |

## 통신

Phone ⇄ ESP32: **BLE GATT** (NUS 호환), JSON 메시지.

이전 WiFi/WebSocket 버전은 `emg_fes_controller_wifi.ino.bak`로 백업되어 있음.
