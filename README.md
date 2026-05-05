# EMG-FES 프로젝트

근피로(muscle fatigue)를 EMG 신호로 실시간 감지해 마사지기/FES 자극을 자동으로 제어하는 closed-loop 시스템.

## 분석 방법

**RAW + MDF 이중 조건** (방식 3)

- RMS slope > **+20%** **AND** MDF slope < **-10%** → 피로 판정
- 5회 연속 만족 시 자극 트리거

## 디렉토리 구조

```
emg-fes-project/
├── firmware/
│   └── emg_fes_controller/
│       ├── emg_fes_controller.ino   # ESP32 메인 펌웨어
│       ├── secrets.h.example        # WiFi 자격증명 템플릿
│       └── secrets.h                # (gitignore) 본인 정보
├── data_logger/
│   ├── emg_logger.py                # ESP32 → CSV 로거
│   └── requirements.txt
├── data/
│   ├── subject_A/
│   ├── subject_B/
│   └── subject_C/
├── flutter_app/                     # (TBD) 모바일 UI
└── docs/
```

## 하드웨어

- **ESP32** (MyoWare 2.0 Wireless Shield 내장)
- **MyoWare 2.0 Muscle Sensor** + 표면전극
- **PC817 + IRLZ44N** → 오므론 HV-F022-V (마사지기/FES)

## 펌웨어 (ESP32)

### 1. WiFi 자격증명 설정

```bash
cd firmware/emg_fes_controller
cp secrets.h.example secrets.h
# secrets.h 를 본인 핫스팟 정보로 수정
```

### 2. Arduino IDE 라이브러리

- `WebSocketsServer` (Markus Sattler)
- `ArduinoJson`
- `arduinoFFT`

### 3. 업로드

`emg_fes_controller.ino` 를 ESP32 보드로 업로드 → 시리얼 모니터(115200 baud)에서 IP 확인.

## 데이터 로거 (PC)

### 설치

```bash
cd data_logger
python -m venv ../venv
source ../venv/bin/activate
pip install -r requirements.txt
```

### 실행

```bash
python emg_logger.py --host 172.20.10.5 --subject A
python emg_logger.py --host 172.20.10.5 --subject A --session rest_day1
```

CSV 는 `data/subject_<X>/YYYYMMDD_HHMMSS[_session].csv` 로 저장됩니다.

### 실행 중 명령 (stdin)

| 키 | 동작 |
|---|---|
| `s` | 자극 시작 |
| `x` | 정지 |
| `e` | 비상정지 |
| `c` | 캘리브레이션 (히스토리 리셋) |
| `m <label>` | 마커 추가 (예: `m hard`) |
| `q` | 종료 |

## CSV 컬럼

`wall_time, timestamp_ms, emg_raw, rms, mdf, rms_slope, mdf_slope, fatigue_detected, is_running, is_stimulating, history_count, marker`

## 통신

PC ⇄ ESP32: **WebSocket** (port 81), JSON 메시지.
