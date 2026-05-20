# EMG-FES — 코드 QA 분석 & 사용자 맞춤 UI/UX 제안

> 펌웨어(`emg_fes_controller.ino`) · Python 로거 · Flutter Web 앱을 정독한 뒤 발견한
> **품질 이슈(QA)** 와, 페르소나별로 다듬은 **UI/UX 개선안** 을 정리.

---

## Part 1. 코드 QA 분석

### 1.1 펌웨어 (`firmware/emg_fes_controller/emg_fes_controller.ino`)

#### 🔴 Critical — 데이터 정확성/안전성 직결

| # | 위치 | 이슈 | 영향 | 권장 수정 |
|---|------|------|------|----------|
| F-1 | `onSampleTimer()` L102-106 | **ISR 안에서 `analogRead()` 두 번 호출**. ESP32의 `analogRead` 는 내부적으로 뮤텍스/세마포어를 사용하므로 ISR 컨텍스트에서 호출하면 워치독 리셋·샘플 누락 위험 | 1 kHz 샘플링 신뢰도 저하 | ISR에서는 플래그만 set, 메인 루프에서 `micros()` 기반으로 1 ms 폴링하며 ADC 읽기. 또는 `adc1_get_raw()` (ESP-IDF 저수준 API) 사용 |
| F-2 | `triggerStimulation()` L349-365 | **`delay(150)` / `delay(2000)`** — 메인 루프 블로킹. 2초 long-press 동안 WebSocket·샘플버퍼 응답 정지 | 자극 OFF 시 1~2초 데이터 손실, 클라이언트 핑 타임아웃 가능 | 상태머신으로 변환: `pendingOffUntil = millis()+2000` 후 매 loop에서 비교, `bufferIdx`/`bufferReady` 정합성 보장 |
| F-3 | `loop()` L191-198 | 피로 검출이 `isStimulating == true` 일 때만 트리거. 자극 OFF 상태에서도 피로하면 마사지기 OFF 명령이 무의미하지만, **`currentFatigueDetected` 자체도 false 로 남음** → CSV에 피로 미기록 | 분석 시 자극 OFF 구간의 피로 이벤트가 누락 | 검출(`currentFatigueDetected = true`)과 액션(`triggerStimulation(false)`)을 분리 |
| F-4 | `handleCommand("set_thresholds")` L339-343 | `doc["rms"]` 키가 없으면 `as<float>()` 가 0 반환 → 임계값 0으로 덮어쓸 위험 | 잘못된 메시지 1번에 시스템 무력화 | `containsKey()` 체크 + 합리적 범위(예: 5~50%) 검증 후 적용 |

#### 🟡 Major — 알고리즘/성능

| # | 위치 | 이슈 | 권장 수정 |
|---|------|------|----------|
| F-5 | `calculateMDF()` L383-386 | `rawBuffer[1000]` 중 처음 **256개(256 ms)만** FFT 입력. 나머지 744 ms 데이터는 버려짐 | (a) Welch's method로 4×256 윈도우 평균, 또는 (b) FFT 윈도우를 512/1024로 키워 1 Hz 해상도 향상 |
| F-6 | `DC_OFFSET = 1900` L42 | 하드코딩. 전극/피험자 교체 시 매번 펌웨어 재업로드 필요 | 부팅 직후 2초간 입력 평균을 자동 DC로 계산, 또는 `set_dc_offset` 명령 추가 |
| F-7 | `RMS_THRESHOLD = 20.0`, `MDF_THRESHOLD = -3.0` L39-40 | **README/주석은 `-10%`** 라고 적혀 있으나 실제 코드는 `-3.0`. 분석 스크립트(`progression.py:25`)는 코드와 일치(`-3.0`) → 문서 불일치 | README/주석 갱신, 임계값의 출처/실험적 근거 주석화 |
| F-8 | `calculateSlopePercent()` L425 | `meanY < 0.01` 가드만 있고 음수 가드 없음. MDF가 0~수십 Hz 범위라 안전하지만 일반화 시 위험 | `fabsf(meanY) < 1e-3` 으로 변경 |
| F-9 | `String sessionMarker`, `String cmd = doc["cmd"].as<String>()` L93, L294 | Arduino `String` 동적할당 → 장시간 운용 시 힙 단편화 (`ESP32 free heap` 감소) | `char marker[24]`, `const char* cmd = doc["cmd"]` 로 변경 |

#### 🟢 Minor — 코드 품질

| # | 위치 | 이슈 |
|---|------|-----|
| F-10 | `loop()` L206-212 | 베이스라인 수집이 `historyCount >= BASELINE_SAMPLES(10)` 으로 트리거되지만, 첫 10초의 RMS는 워밍업 중(envelope 안정화 전)일 수 있음 → 베이스라인이 비현실적으로 낮을 가능성 |
| F-11 | `loop()` L233-236 | `STIM_TIMEOUT_MS = 180000` (3분) 안전장치 OK. 단 타임아웃 발생 시 마사지기 OFF 만 호출 — CSV `marker` 에 `"timeout"` 기록 권장 |
| F-12 | `setupWiFi()` L252 | 연결 실패 시 `while(1) delay(1000)` 무한루프 — WDT 리셋 의존. 차라리 `ESP.restart()` 가 명확 |
| F-13 | `sendDataUpdate()` L440 | `doc["emg_raw"] = rawBuffer[RMS_WINDOW - 1] + DC_OFFSET` — DC_OFFSET 복원 시점이 `rawBuffer` 가 다음 사이클로 들어간 상태일 수 있음(buffer 리셋 후 호출). 메인루프 흐름상 `bufferIdx=0` 직후이므로 **이전 사이클 마지막 샘플**이 맞지만 헷갈리는 코드 — 변수에 따로 저장 권장 |
| F-14 | 전반 | 이모지 `Serial.printf("⚠️ ...")` — 한글 시리얼 인코딩이 깨지는 IDE/터미널이 흔함 |

---

### 1.2 Python 로거 (`data_logger/`)

| # | 파일 | 이슈 | 권장 수정 |
|---|------|------|----------|
| P-1 | `emg_logger.py:107` | `msg.get(k, "")` — 펌웨어가 키를 안 보내면 빈 문자열로 저장됨. 누락 사실이 눈에 안 띔 | 누락 키 1회 로깅(warning) |
| P-2 | `emg_logger.py:42-68` | 종료 시 `gh api` 동기 호출이 실패하면 stderr만 출력, **로컬 파일은 삭제 안 함** (finally `except OSError: pass`). 동작은 안전한데 사용자에게 "어디 남았는지" 안내가 약함 | 실패 시 `Saved locally → /tmp/...` 명시적 안내 |
| P-3 | `emg_logger.py:165` | `ping_interval=20` 만 설정, `ping_timeout` 미지정 → ESP32 `delay(2000)` 블로킹 중 핑 누락 시 끊김 | `ping_timeout=30` 명시 |
| P-4 | `emg_live_plot.py:34` | `ESP32_IP` 하드코딩. CLI 인자로 받게 통일 (`emg_logger.py` 처럼) | `argparse` 추가 |
| P-5 | `emg_live_plot.py:139-155` | 재연결 루프가 `time.sleep(2)` 만으로 무한 재시도 — 지수백오프 없음 | `min(60, 2 * attempt)` 백오프 |
| P-6 | `analyze.py:51-53`, `progression.py:48` | `fatigue_detected` 가 bool/문자열 둘 다 들어오는 케이스를 매번 ad-hoc 처리 | 로더 한 곳에서 `df["fatigue_detected"] = df[...].astype(str).str.lower().eq("true")` 통일 |
| P-7 | `progression.py:24-26` | 임계값이 **펌웨어와 별도로 하드코딩** → 두 곳을 같이 안 고치면 분석 결과가 펌웨어 동작과 어긋남 | 공통 상수를 `data_logger/_constants.py` 로 분리하거나 CSV header comment 로 펌웨어가 자기 임계값을 기록 |
| P-8 | `emg_logger.py:36` | `GITHUB_REPO = "chaerinyeon/emg-fes-project"` — 다른 사람이 fork하면 매번 수정해야 함 | 환경변수 fallback (`os.getenv("EMG_REPO", ...)`) |

---

### 1.3 Flutter Web 앱 (`flutter_app/lib/main.dart`)

| # | 위치 | 이슈 | 권장 수정 |
|---|------|------|----------|
| U-1 | L4 | `import 'dart:html'` — **웹 전용**. iOS/Android/Desktop 빌드 즉시 실패. `pubspec.yaml` 에 `flutter_blue_plus` 가 있는데 모순 | `kIsWeb` 분기 + `package:universal_html` 또는 `share_plus`/`path_provider` 로 추상화 |
| U-2 | L73, L75 | `_log` 가 무한히 적재됨 (Stop 전까지) — 1시간 세션 = 3600 rows × ~13 키 → 메모리 압박 일정 수준 | 1만 row 초과 시 자동 부분 다운로드 또는 IndexedDB 캐싱 |
| U-3 | L94-122 | 연결 실패 시 사용자가 직접 Reconnect 버튼 눌러야 함 | 자동 재연결 (`Timer.periodic` + 백오프) |
| U-4 | L173 | `(r - _st.baselineRms).clamp(0.0, ∞)` — 베이스라인보다 낮으면 0으로 잘림. 분석 컬럼 `rms_ratio` 와 호환 안 됨 (이미 펌웨어가 비율을 보내고 있음) | 음수 영역도 표시(쉬는 구간 확인용) 혹은 ratio 그래프로 전환 |
| U-5 | L249-257 | 마커가 `easy/medium/hard` 3종 하드코딩 → 자유 입력 마커 보낼 방법 없음 (펌웨어는 받음) | TextField 다이얼로그 추가 |
| U-6 | L141 | `try { ... } catch (_) {}` — 파싱 에러 완전 무시. 디버깅 어려움 | `debugPrint('parse fail: $raw')` |
| U-7 | L60 | 호스트가 한 곳에 저장 안 됨 → 새로고침마다 재입력 | `localStorage` (web) 또는 `shared_preferences` |
| U-8 | L289-301 | Start 후 베이스라인 10초 수집 중인데 화면에는 단지 RMS 가 0으로 보임 (`is_running=true` 이지만 의미 있는 값 없음) | "베이스라인 수집 중 9s…" 카운트다운 오버레이 |
| U-9 | L708-714 | Emergency 버튼이 다른 버튼들과 한 줄에 같이 배치 → **오터치 위험** | 우측 상단에 별도 floating action button + 1초 long-press 확인 |
| U-10 | L143-152 | `timestamp_ms` 기준 단조성(`ts < _t0`) 만 체크. ESP32 재부팅 시(`millis()` 리셋)만 catch — 짧은 시계 점프는 못 잡음 | `wall_time` 도 함께 검사 |
| U-11 | L18-30 | 다크 테마 강제 — 측정실 조명에서는 라이트가 가독성 더 나을 수 있음 | `ThemeMode.system` |

---

### 1.4 보안/운영

| # | 영역 | 이슈 |
|---|------|-----|
| S-1 | WebSocket | **인증 없음**. 같은 WiFi에 누구든 접속해 `cmd:start` / `cmd:emergency` 전송 가능 | 토큰 헤더 검증 또는 첫 메시지 핸드셰이크 |
| S-2 | `secrets.h` | `.gitignore` 되어 있다 가정 — 실제로 커밋된 적 없는지 `git log --all -- firmware/emg_fes_controller/secrets.h` 확인 권장 |
| S-3 | GitHub 업로드 | `gh api` 가 사용자의 PAT로 동작 → 같은 로그인이 데이터+코드 권한 동일. 의료 데이터(EMG) 라면 별도 데이터 저장소·계정 분리 권장 |

---

## Part 2. 사용자 맞춤 UI/UX 제안

### 2.1 사용자 페르소나

이 시스템에는 **세 가지 명확히 다른 사용자** 가 있다. 한 UI로 다 처리하려다 보니 현재
Flutter 앱이 어중간하다.

| 페르소나 | 누구 | 주 관심사 | 필요한 정보량 |
|---------|------|---------|------------|
| 🧑‍🦰 **P1. 피험자(본인)** | 전극 부착하고 운동하는 사람 | "지금 피곤한가?" 만 알고 싶음 / 자극 멈추면 알림 / 비상정지 손쉽게 | **최소 (값 2~3개)** |
| 🧑‍🔬 **P2. 연구자/실험자** | 세션 운영 · 마커 입력 · 임계값 조정 | 라이브 그래프 / 마커 / 베이스라인 / 세션 메타데이터 | **풀 그래프** |
| 🩺 **P3. 임상가/리뷰어** | 측정 후 데이터 분석 | 진행 추세 · bin 통계 · 트리거 시점 | **오프라인 (analyze.py)** |

→ **UI를 3개 모드로 분리**: `Patient` / `Operator` / (analyze.py가 P3 담당).

---

### 2.2 Patient 모드 — 피험자 화면

**디자인 원칙:** 숫자 대신 상태 색, 글자 크게, 단일 빨간 버튼.

```
┌──────────────────────────────────────────────┐
│  ⬤ 연결됨 (emg-fes.local)         00:03:42  │ ← 상단: 상태 + 경과 시간만
├──────────────────────────────────────────────┤
│                                              │
│        ┌──────────────────────┐              │
│        │                      │              │ ← 거대한 원형 게이지
│        │       NORMAL         │              │   muscle_state 필드 그대로
│        │   ████████░░░░░░     │              │   색: idle=회 / low=청 /
│        │                      │              │       normal=녹 / high=황 /
│        │   근육 활성도 92%    │              │       fatigue=적 (깜빡임)
│        └──────────────────────┘              │
│                                              │
│       마사지 🟢 ON  ·  남은 안전시간 2:34    │
│                                              │
├──────────────────────────────────────────────┤
│  [    🚨   비 상 정 지   (꾹 누르세요)    ]  │ ← 1초 long-press
└──────────────────────────────────────────────┘
```

**핵심 변경점**

| 항목 | 현재 | 제안 |
|-----|------|------|
| 표시값 | ENV/RMS 숫자 (의미 모름) | `muscle_state` 한글 라벨 + 색 |
| 그래프 | 2개 차트 | **없음** (인지부담↓) |
| 피로 알람 | AlertDialog "근피로 감지" + SnackBar | 화면 전체 빨간 펄스 + 진동(`HapticFeedback.heavyImpact`) + 음성 "잠시 쉬세요" (TTS) |
| 비상정지 | 7개 버튼 중 하나 (오터치) | **하단 전폭 빨간 버튼, 1초 long-press 필수** |
| 폰트 | 32 pt | 48 pt + tabular figures + 동공거리 1m 가시 |

---

### 2.3 Operator 모드 — 연구자/실험자 화면

**디자인 원칙:** 데이터는 다 보여주되 **결정해야 할 것** 을 우선 배치.

```
┌─ Connect ──────────┬─ Session ──────────────┬─ Marker ──────────┐
│ host: 172.20.10.5 │ Subject [A▾]  Day [3▾] │ [Easy][Med][Hard]│ ← 최상단: 메타 입력
│ [ Connect 🔗 ]    │ [ ● Start ][ ■ Stop ]  │ [+ 커스텀…]      │
├────────────────────┴────────────────────────┴───────────────────┤
│ ⬤ RUN  ⬤ STIM  baseline=62.1  hist 48/60  rms_slope +18.2%    │
├─────────────────────────────────────────────────────────────────┤
│  EMG envelope                                        [↓ CSV]    │
│  ─╱╲─╱╲╱╲──╱╲╱╲╱╲╲╱─                                            │ ← 4개 차트
│                                                                 │   (env / rms /
│  RMS (1s)                       — baseline                      │    mdf / slope)
│  ────────────╱──────                                            │
│                                                                 │
│  MDF (Hz)                                                       │
│  ─────╲──╲──╲──────                                             │
│                                                                 │
│  Slope %     ┄┄┄ RMS +20%   ┄┄┄ MDF -3%                         │
│  ────────────────────────────                                   │
│                                                                 │
├─────────────────────────────────────────────────────────────────┤
│ Thresholds  RMS [ 20.0 ▴▾ ]  MDF [ -3.0 ▴▾ ]  [ Apply ]         │ ← 임계값 인라인
│                                                                 │
│ Notes                                                           │
│ ┌─────────────────────────────────────────────────────────────┐ │ ← 자유 텍스트
│ │ 12:34 - 피험자 "왼팔 저림" 호소                              │ │   타임스탬프 자동
│ └─────────────────────────────────────────────────────────────┘ │
│                                              [🛑 Emergency]    │ ← 우측 격리
└─────────────────────────────────────────────────────────────────┘
```

**핵심 변경점**

| 항목 | 현재 | 제안 |
|-----|------|------|
| Subject/Session 입력 | 없음 (`emg_logger.py` CLI에서만) | 상단 메타 패널, CSV 파일명·GitHub path 에 반영 |
| 마커 | Easy/Medium/Hard 3개 | + 자유 입력 + 자동 타임스탬프 노트 |
| 임계값 | 펌웨어 재업로드 | 인라인 spinner + Apply (펌웨어 `set_thresholds` 명령 활용) |
| 차트 | 2개 (env, rms) | 4개 (+ mdf, slope with threshold lines) |
| 베이스라인 수집 중 표시 | 없음 (run 켜졌으나 값 0) | **"베이스라인 수집 중 8/10초"** 진행바 |
| Stop 후 CSV | 자동 다운로드만 | 다운로드 + "GitHub 업로드" 토글 + 마지막 세션 5개 히스토리 |
| Emergency | 같은 줄 7번째 버튼 | 우측 하단 격리, 색 = 빨강만 |
| 자동 재연결 | 없음 | 토글 ON/OFF + 마지막 시도 시각 |
| 호스트 기억 | 새로고침 시 초기화 | `localStorage` 최근 5개 드롭다운 |

---

### 2.4 모드 전환

```
앱 시작
   │
   ▼
┌────────────────────────────────┐
│  EMG-FES 시작                  │
│                                │
│  [ 🧑‍🦰 피험자 모드 ]            │ ← Patient (큰 게이지, 비상정지만)
│                                │
│  [ 🧑‍🔬 실험자 모드 ]            │ ← Operator (풀 컨트롤, PIN 4자리)
│                                │
│  [ 📈 데이터 분석 (오프라인) ]  │ ← analyze.py 안내 / 또는 임베드된 차트
└────────────────────────────────┘
```

- Operator 모드는 PIN 4자리 (`secrets.h` 와 비슷한 위치에 저장) → 환자 손에서 임계값 변경 방지
- 피험자 모드에서도 우측 위 "👤" 누르면 PIN 입력 후 실험자 모드 전환

---

### 2.5 알람·피드백 채널 정리

피로 감지 같은 중요한 이벤트는 **다중 채널** 로 알려야 놓치지 않는다.

| 채널 | 모드 | 현재 | 제안 |
|-----|------|-----|------|
| 시각 | Patient | AlertDialog (덮음) | 전체화면 빨간 펄스 (3초) |
| 시각 | Operator | AlertDialog (작업 차단) | 우상단 토스트 + 슬로프 차트 빨간 ▼ 마커 |
| 청각 | – | 없음 | Web Audio API beep (440 Hz, 200 ms × 3) |
| 진동 | – | 없음 | 모바일 전환 시 `HapticFeedback` |
| 로그 | – | CSV `fatigue_detected` 컬럼만 | `events.jsonl` 별도 파일에 `{t, kind:"fatigue", rms_slope, mdf_slope}` |

---

### 2.6 접근성/현장 운영

- **시야** — 모니터를 2 m 떨어진 곳에서 봐도 인식 가능한 폰트 크기(피험자 모드 48 pt+, Operator 모드 16 pt+)
- **장갑/땀** — 터치 타깃 최소 48 dp (Material 가이드라인). 현재 OutlinedButton 들이 살짝 작음.
- **색맹** — 빨/녹 단독 의존 X. `🔴` 아이콘과 글자 라벨 동시 사용 ("FATIGUE", "OK")
- **실험실 환경** — 다크 테마 강제 해제, 시스템 따름
- **마이그레이션** — 한국어 hardcode 분리 (`l10n` 폴더) — 다국어 피험자 대응

---

## Part 3. 우선순위 로드맵

빠르게 임팩트 큰 것부터.

### 🔥 1주차 (안전·정확성)
1. **F-1**: ISR `analogRead` 제거 → 메인 루프 폴링 (1 kHz 신뢰성)
2. **F-2**: `triggerStimulation` 의 `delay()` → non-blocking 상태머신
3. **U-9**: Emergency 버튼 격리 + long-press
4. **F-7**: 임계값 문서 일치 (코드 vs README vs progression.py)

### 🌱 2주차 (UX 가시성)
5. **U-8**: 베이스라인 수집 진행바
6. **U-3**: 자동 재연결 + 백오프
7. **2.2 Patient 모드** 프로토타입 (단일 게이지)
8. **2.5 알람 다중채널** (소리/진동)

### 🌿 3주차 (생산성)
9. **2.3 Operator 모드** 메타패널 (Subject/Session/Notes)
10. **F-4 + 2.3**: 임계값 인라인 조정 (`set_thresholds` 검증 추가)
11. **U-5**: 자유 입력 마커
12. **P-7**: 임계값 공통 상수 모듈

### 🌳 4주차+ (장기)
13. **F-5**: Welch's method로 MDF 안정화
14. **F-6**: DC offset 자동 캘리브레이션
15. **U-1**: 모바일 빌드 지원 (`dart:html` 추상화)
16. **S-1**: WebSocket 토큰 인증
