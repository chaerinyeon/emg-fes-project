# EMG-FES Closed-Loop System — 프로젝트 전체 분석

> 근전도(EMG) 신호로 **근피로(muscle fatigue)** 를 실시간 감지하고, 그 결과에 따라
> 마사지기/FES(Functional Electrical Stimulation) 장치를 자동으로 제어하는 **closed-loop** 시스템.

---

## 1. 시스템 개요

### 1.1 동작 흐름

```
 ┌──────────────┐   표면전극   ┌──────────────────┐  WiFi/WebSocket  ┌──────────────────┐
 │ 피험자(근육) │ ───────────▶│ MyoWare 2.0 +    │ ─────────────▶ │ PC (data_logger) │
 │              │             │ ESP32 (펌웨어)   │ ◀───────────── │ + Flutter Web UI │
 └──────────────┘             └────────┬─────────┘   start/stop    └──────────────────┘
                                       │ GPIO
                                       ▼
                              ┌──────────────────┐
                              │ PC817 + IRLZ44N  │
                              │  → 마사지기/FES  │
                              └──────────────────┘
```

1. **MyoWare 2.0 Muscle Sensor** 가 근육 표면의 전기 신호를 증폭/필터링
2. **MyoWare2.0WirelessShield** 가 1 kHz로 ADC 샘플링 → 매 1초마다 RMS · RMS · MDF · slope 계산
3. **이중 조건**(RMS slope ↑ AND MDF slope ↓)이 **5회 연속** 만족되면 피로 판정
4. 피로 판정 즉시 마사지기를 자동 **OFF** (피로 회복 유도)


### 1.2 분석 방법 — "방식 3 (RAW + MDF 이중 조건)"

| 지표      | 기반   | 의미                          | 피로 시 변화 |
|----------|-------|------------------------------|------------|
| **RMS**  | ENV   | 근육 활성도(진폭)             | 증가 ▲     |
| **MDF**  | RAW + FFT | 중간주파수(스펙트럼 무게중심) | 감소 ▼     |
| **slope (%)** | 선형회귀 | 1초 단위 시계열의 변화율   | 두 지표가 **동시에** 임계값 초과 시 피로 |

> 단일 지표(RMS만 또는 MDF만)보다 **위양성(false positive)** 이 적음.
> 노이즈로 RMS가 잠시 튀더라도 MDF가 같이 떨어지지 않으면 무시.

---

## 2. 디렉토리 구조

```
emg-fes-project/
├── README.md                                  # 사용 매뉴얼
├── firmware/
│   └── emg_fes_controller/
│       ├── emg_fes_controller.ino             # ESP32 메인 펌웨어 (C++/Arduino)
│       ├── secrets.h.example                  # WiFi 자격증명 템플릿
│       └── secrets.h                          # (gitignore) 실제 SSID/PW
├── data_logger/
│   ├── emg_logger.py                          # 헤드리스 CSV 로거 (GitHub 직접 업로드)
│   ├── emg_live_plot.py                       # 실시간 그래프 + 로컬 CSV 저장
│   ├── analyze.py                             # 단일 세션 시각화 + 통계 요약
│   ├── progression.py                         # 활성화 구간 30s bin 진행 추세
│   ├── requirements.txt
│   ├── data/                                  # 라이브 플롯이 만드는 임시 CSV
│   └── venv/
├── data/
│   ├── subject_A/   *.csv, *.png              # 피험자별 측정 세션
│   ├── subject_B/
│   └── subject_C/
├── flutter_app/                               # 모바일/웹 UI
│   └── lib/main.dart                          # 단일 파일 Flutter Web 앱
└── docs/
    ├── PROJECT_OVERVIEW.md  ← 이 문서
    └── images/
```

---

## 3. 하드웨어 구성

| 부품 | 역할 | 비고 |
|-----|------|------|
| **Myoware 2.0 Wireless Shield** | MCU, WiFi, ADC, WebSocket 서버 | MyoWare 2.0 Wireless Shield 내장 |
| **MyoWare 2.0 Muscle Sensor** | 표면 EMG 증폭/정류 | RAW 출력 + ENV 출력 동시 제공 |
| 표면 전극 | 근육 부착 | 일반적으로 한 근육에 3개(양극·음극·기준) |
| **RELAY** | 옵토커플러 | ESP32 GPIO ↔ 마사지기 버튼 전기적 절연 |
| **IRLZ44N** | N-channel MOSFET | 마사지기 푸시버튼을 short시켜 누름 효과 |
| **오므론 HV-F022-V** | 저주파 마사지기 (FES 대용) | ON/OFF/MODE/UP/DOWN 푸시버튼 4종 |


## 4. 펌웨어 분석 — `emg_fes_controller.ino`

### 4.1 신호처리 파라미터

```cpp
const int SAMPLE_RATE = 1000;     // 1 kHz ADC 샘플링
const int FFT_SIZE    = 256;      // FFT 윈도우 = 256 ms
const int RMS_WINDOW  = 1000;     // RMS 윈도우 = 1 초
const int HISTORY_SIZE = 60;      // 60초 분량 RMS/MDF 히스토리

float RMS_THRESHOLD = 20.0;       // RMS slope > +20%
float MDF_THRESHOLD = -3.0;       // MDF slope < -3%  (노이즈 감안 완화)
const int CONSECUTIVE_TRIGGER = 5;// 5회 연속 만족 시 트리거
const int DC_OFFSET = 1900;       // 12-bit ADC 베이스라인 (피험자별 조정)
```

> ⚠️ **DC_OFFSET 주의** — `emg_fes_controller.ino:42` 의 1900은 본인 전극 부착 상태에서
> 안정 시 ADC 값으로 갱신해야 함. `analyze.py` 의 빨간 점선이 이 값과 일치하지 않으면 재조정 필요.

### 4.2 1 kHz 타이머 인터럽트 — `onSampleTimer()`

`emg_fes_controller.ino:99-115`

```cpp
void IRAM_ATTR onSampleTimer() {
  portENTER_CRITICAL_ISR(&timerMux);
  if (bufferIdx < RMS_WINDOW) {
    int raw = analogRead(PIN_EMG_RAW);
    int env = analogRead(PIN_EMG_ENV);
    rawBuffer[bufferIdx] = raw - DC_OFFSET;   // RAW: DC 제거 → FFT용
    envBuffer[bufferIdx] = env;                // ENV: 평활화 그대로 → RMS용
    bufferIdx++;
    if (bufferIdx >= RMS_WINDOW) bufferReady = true;
  }
  portEXIT_CRITICAL_ISR(&timerMux);
}
```

- `hw_timer_t` 를 1 µs tick으로 설정한 뒤 1000 µs(=1 ms)마다 발화 → **정확한 1 kHz**
- `IRAM_ATTR` 로 인터럽트 코드가 IRAM에 상주(플래시 캐시 미스에 영향 안 받음)
- 임계영역(`portENTER_CRITICAL_ISR`)으로 메인 loop 와의 동시 접근 보호
- 두 채널을 따로 저장하는 이유:
  - **RAW** 는 주파수 정보가 살아있어야 FFT/MDF 의미가 있음
  - **ENV** 는 이미 하드웨어에서 정류·LPF된 값이라 RMS(진폭) 계산에 적합

### 4.3 메인 루프 — `loop()` (`emg_fes_controller.ino:160-237`)

매 초 (`bufferReady == true`) 다음을 수행한다.

1. **RMS 계산** (`calculateRMS()`) — `envBuffer` 1000개의 제곱평균제곱근
2. **MDF 계산** (`calculateMDF()`) — `rawBuffer` 의 첫 256개로 FFT → 누적파워 50% 지점의 주파수
3. **히스토리 저장** — 원형버퍼 `rmsHistory[60]`, `mdfHistory[60]` 에 push
4. **히스토리 ≥ 30** 모이면 slope(%) 계산 → 이중 조건 평가
5. **5회 연속 만족** 이면 `triggerStimulation(false)` 로 마사지기 OFF
6. **베이스라인 수집** — 시작 후 10초간 평균 RMS를 `baselineRMS` 로 고정
7. **근육 상태 분류** — `idle / calibrating / low / normal / high / fatigue`
8. **WebSocket 브로드캐스트** (`sendDataUpdate()`) — JSON 1 Hz 전송
9. **자극 타임아웃** — 자극 ON 후 3분 경과 시 강제 OFF (안전장치)

#### slope(%) 알고리즘 — `calculateSlopePercent()` (`emg_fes_controller.ino:412-429`)

```cpp
float slope = (n·ΣXY − ΣX·ΣY) / (n·ΣX² − (ΣX)²);   // 단순선형회귀
return (slope * count) / meanY * 100.0;             // 평균 대비 %
```

- 일반 단위(/초)가 아닌 **"전체 윈도우 동안의 변화율 %"** 로 정규화
- 평균이 작을 때 폭주를 막기 위해 `meanY < 0.01` 이면 0 반환
- 원형 인덱스 `(historyIdx - count + i + HISTORY_SIZE) % HISTORY_SIZE` 로 가장 최근 N개를 시간순으로 순회

#### MDF (중간주파수) — `calculateMDF()` (`emg_fes_controller.ino:381-407`)

```cpp
FFT.windowing(FFTWindow::Hamming, FFTDirection::Forward);
FFT.compute(FFTDirection::Forward);
FFT.complexToMagnitude();

// 누적 파워의 50% 지점 찾기 → 그 bin의 주파수가 MDF
float totalPower = Σ |FFT[1..N/2]|;
float halfPower = totalPower / 2;
... cumulative sum until cumPower >= halfPower ...
return (float)i * SAMPLE_RATE / FFT_SIZE;   // bin → Hz
```

- 1 bin = `SAMPLE_RATE / FFT_SIZE` = `1000/256 ≈ 3.9 Hz` 해상도
- MDF는 피로 시 **고주파 성분이 감쇠**하므로 값이 줄어드는 경향이 있음
- DC 제거 후의 RAW만 사용 (i=0 bin은 제외)

### 4.4 마사지기 제어 — `triggerStimulation(bool on)`

물리 푸시버튼을 GPIO로 "누름" 시뮬레이션:

| 동작 | 펄스 길이 | 이유 |
|------|----------|-----|
| ON   | 150 ms HIGH → LOW | 짧은 탭 (전원 ON) |
| OFF  | 2000 ms HIGH → LOW (long-press) | 오므론 HV-F022-V 가 long-press로만 꺼짐 |

> 현재 자동 트리거는 **OFF만** 호출 (피로 검출 → 자극 정지).
> ON 은 수동(`s` 명령) 으로 시작하는 흐름을 가정.

### 4.5 WebSocket 프로토콜

**서버 → 클라이언트** (1 Hz `type:"data"` 메시지)

```json
{
  "type": "data",
  "timestamp_ms": 12345,
  "emg_raw": 1923,
  "emg_env": 412,
  "rms": 87.4,
  "mdf": 78.1,
  "rms_slope": 23.4,
  "mdf_slope": -4.2,
  "fatigue_detected": false,
  "is_running": true,
  "is_stimulating": true,
  "history_count": 45,
  "marker": "",
  "baseline_rms": 62.0,
  "rms_ratio": 1.41,
  "muscle_state": "normal"
}
```

**클라이언트 → 서버** (명령)

| `cmd` | 추가 필드 | 효과 |
|-------|----------|------|
| `start` | – | 히스토리·베이스라인 리셋, FES OFF 상태로 10초간 베이스라인 수집 시작 |
| `stop` | – | 시스템 중지, 마사지기 OFF |
| `emergency` | – | 비상정지 |
| `calibrate` | – | 히스토리·베이스라인만 리셋 |
| `marker` | `label` (str) | 다음 데이터 메시지의 `marker` 필드에 한 번 실어 보냄 |
| `set_thresholds` | `rms` (float), `mdf` (float) | 임계값 런타임 변경 |

---

## 5. PC 측 소프트웨어

### 5.1 `data_logger/emg_logger.py` — 헤드리스 로거

- `websockets` (asyncio 기반) 라이브러리 사용
- 두 개의 코루틴을 `asyncio.wait(FIRST_COMPLETED)` 로 병렬 실행:
  - `receive_loop` — JSON 수신 → CSV 한 줄 → 즉시 `flush()`
  - `stdin_loop`  — 키보드 한 줄 입력 → 명령 JSON 전송
- 종료 시 `upload_to_github()` 가 `gh api` (GitHub REST contents API) 로 CSV를
  `data/subject_<X>/<timestamp>.csv` 경로에 **PUT** → 성공 시 로컬 임시파일 삭제
- CSV 헤더는 `FIELDS` 리스트(`emg_logger.py:70-83`)에 정의된 12개 컬럼

**컬럼 정의**

| 컬럼 | 출처 | 의미 |
|-----|------|------|
| `wall_time` | PC | ISO8601 (ms 단위) 수신 시각 |
| `timestamp_ms` | ESP32 | `millis()` 부팅 후 경과 ms |
| `emg_raw` | ESP32 | 12-bit ADC RAW (DC 미제거) |
| `rms` | ESP32 | 1초 envelope RMS |
| `mdf` | ESP32 | 1초 RAW의 MDF (Hz) |
| `rms_slope`, `mdf_slope` | ESP32 | 60초 히스토리 선형회귀 (%) |
| `fatigue_detected` | ESP32 | 이중 조건 5회 연속 만족 여부 |
| `is_running`, `is_stimulating` | ESP32 | 상태 플래그 |
| `history_count` | ESP32 | 히스토리에 쌓인 샘플 수 (slope 신뢰도 판단용) |
| `marker` | PC→ESP32→PC | `m hard` 등 수동 마커 |

### 5.2 `data_logger/emg_live_plot.py` — 실시간 그래프

- 동기 라이브러리 `websocket-client` + `threading` 사용 (matplotlib과 잘 맞음)
- 메인 스레드: matplotlib (`FuncTimer` 200 ms 주기로 화면 갱신)
- 워커 스레드: WebSocket 수신 → `deque(maxlen=60)` 에 push & CSV 즉시 저장
- 키보드: `s/x/e/c` 명령, `1/2/3` 으로 easy/medium/hard 마커, `q` 종료
- `logger.py` 와의 차이점:
  - 로컬에만 저장 (GitHub 업로드 X)
  - **emg_env / baseline_rms / rms_ratio / muscle_state** 추가 컬럼 저장
  - 시각화가 함께 뜸 (분석 단계에 적합)

### 5.3 `data_logger/analyze.py` — 단일 세션 시각화

- `--subject A` → `data/subject_A/` 의 **가장 최근** CSV 자동 선택
- 4개 subplot 생성:
  1. `emg_raw` 원시 ADC + `DC_OFFSET=1900` 가이드라인 → DC 검증용
  2. `rms` (1초 윈도우)
  3. `mdf` (Hz)
  4. `rms_slope`, `mdf_slope` + 두 임계값 점선 (+20%, -10%)
- 마커는 보라색 세로선, `is_stimulating=True` 구간은 주황색 음영
- 텍스트 요약 — 샘플 수, mean/min/max/std, slope 통계, fatigue 횟수, 마커 목록

### 5.4 `data_logger/progression.py` — 진행 추세 분석

- `is_running=True` 인 **활성화 구간만** 추출
- 30초 bin 단위 통계 테이블 (`rms_mean`, `rms_max`, `mdf_mean`, `both_pct`, ...)
- 5회 연속 트리거 조건을 **분석 단계에서 재현** → 실제 펌웨어 트리거와 비교 가능
- 빨간 음영 = 두 조건 동시 만족 구간, 빨간 세로선 = 트리거 시점

> ⚠️ `progression.py:24-26` 의 임계값이 펌웨어와 같아야 함 (현재 `RMS_THR=20.0`, `MDF_THR=-3.0`).
> 펌웨어 측 임계값을 바꾸면 여기도 함께 수정.

---

## 6. Flutter Web 앱 — `flutter_app/lib/main.dart`

- **단일 파일** 720 lines로 구성된 모니터링 UI (web 전용 — `dart:html` import 사용)
- 화면 구성
  - 호스트 입력 바 (기본 `emg-fes.local:81`)
  - 상태 칩 (CONNECTED / RUN / STIM / FATIGUE / hist N / rms_slope %)
  - 라이브 ENV / RMS 큰 숫자 readout
  - **EMG envelope** chart (0–4095 고정 range)
  - **RMS** chart (베이스라인 보정값: `rms - baseline_rms`, 음수는 0으로 clamp)
  - 제어 버튼: Start / Stop / Calibrate / Easy / Medium / Hard / Emergency
- 피로 감지 시:
  - `_onFatigueDetected()` 에서 빨간색 **AlertDialog** + 하단 **SnackBar** 동시 표시
  - 본문에 빨간 banner "🚨 근피로 감지됨 — 자극 자동 정지" 노출
- **Stop** 시 누적 `_log` 를 즉시 CSV로 만들어 `html.AnchorElement` 의 download attr로 다운로드
  - 별도 서버 없이 브라우저 단에서 파일 저장 — `data_logger` 와 독립적
- 의존성: `web_socket_channel`, `fl_chart`, `flutter_blue_plus` (BLE는 아직 미사용)

---

## 7. 데이터 흐름 요약

```
┌─────────────────────────────────────────────────────────────────────┐
│ ESP32 onSampleTimer (1 kHz ISR)                                     │
│   rawBuffer[1000], envBuffer[1000]                                  │
└────────────────────────────┬────────────────────────────────────────┘
                             │ bufferReady == true (1 Hz)
                             ▼
┌─────────────────────────────────────────────────────────────────────┐
│ loop()                                                              │
│   ┌──────────┐  ┌─────────────┐  ┌────────────────────────────┐    │
│   │ RMS(env) │  │ FFT→MDF(raw)│  │ slope% (linreg, 30~60 hist)│    │
│   └────┬─────┘  └─────┬───────┘  └─────────────┬──────────────┘    │
│        └──────────────┴────────────────────────┘                    │
│        ▼                                                            │
│  if (rms_slope > +20% AND mdf_slope < -3%) consecutive++            │
│  if (consecutive >= 5 AND isStimulating) → triggerStimulation(OFF)  │
│        │                                                            │
│        ▼                                                            │
│  sendDataUpdate() → WebSocket broadcast (1 Hz JSON)                 │
└────────────────────────────┬────────────────────────────────────────┘
                             │
                             ▼
                ┌────────────┴────────────┐
                │                         │
        ┌───────▼─────────┐     ┌─────────▼─────────┐
        │ emg_logger.py   │     │ Flutter web app   │
        │  → CSV          │     │  → live chart     │
        │  → GitHub PUT   │     │  → browser CSV DL │
        └─────────────────┘     └───────────────────┘
                │
                ▼
        analyze.py / progression.py (오프라인 통계·그래프)
```

---

## 8. 운영 매뉴얼 (요약)

### 8.1 펌웨어 빌드

```bash
cd firmware/emg_fes_controller
cp secrets.h.example secrets.h
# secrets.h 에 WIFI_SSID / WIFI_PASSWORD 입력
```

Arduino IDE 필요 라이브러리: `WebSocketsServer` (Markus Sattler), `ArduinoJson`, `arduinoFFT`.
업로드 후 시리얼 모니터(115200)에서 IP 확인.

### 8.2 데이터 로깅

```bash
cd data_logger
python -m venv venv && source venv/bin/activate
pip install -r requirements.txt

# 헤드리스 (GitHub 업로드)
python emg_logger.py --host <ESP32_IP> --subject A

# 실시간 그래프
python emg_live_plot.py    # 코드 내 ESP32_IP 수정
```

### 8.3 분석

```bash
python analyze.py --subject A                # 최신 세션
python progression.py --subject A --bin 30   # 30초 bin 진행 추세
```

### 8.4 Flutter Web

```bash
cd flutter_app
flutter run -d chrome
# 호스트 바에 emg-fes.local:81 또는 <IP>:81 입력 → Connect
```

---

## 9. 주의/개선 포인트

- **DC_OFFSET 캘리브레이션** — 피험자/전극 교체 시 `analyze.py` 의 raw 그래프로 확인하고 펌웨어 상수를 맞춰야 RMS/MDF가 의미를 가진다.
- **mDNS 안정성** — macOS Python 환경에서 `emg-fes.local` 이 잘 안 풀리는 경우 IP 직접 사용 권장 (`emg_live_plot.py:34` 주석 참고).
- **펌웨어 ↔ 분석 임계값 동기화** — `progression.py:24-26` 가 펌웨어 임계값과 같아야 트리거 재현이 일치한다.
- **arduinoFFT API 버전** — `ArduinoFFT<double>(...)` 와 `FFT.windowing/compute/complexToMagnitude` 가 v2.x API. v1.x를 쓰면 컴파일 실패한다.
- **ESP32 Core 2.0.x 의존** — `timerBegin(0, 80, true)` 시그니처가 3.x에서 변경됨. Core 버전을 2.0.x로 고정해야 한다.
- **자극 ON 시 노이즈** — 자극이 켜진 동안 EMG에 stim artifact가 섞일 수 있어, 현재는 피로 검출이 `isStimulating` 조건과 결합(`loop()` 의 `if (... && isStimulating)`)되어 있다. ON-실험 설계 시 이 점을 인지할 것.
- **BLE 의존성** — `flutter_blue_plus` 가 `pubspec.yaml` 에 들어있지만 실제 코드는 WebSocket만 사용. BLE fallback 경로는 아직 구현 전.
