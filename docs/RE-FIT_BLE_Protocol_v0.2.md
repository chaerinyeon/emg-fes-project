# RE:FIT BLE 프로토콜 v0.2

`firmware/emg_fes_controller/emg_fes_controller.ino` ↔ 폰(또는 `scripts/refit_ble_bench.py`) 사이의
바이트 계약. **이 문서와 펌웨어 패킹 코드가 어긋나면 문서가 아니라 코드가 정답이다** — 고칠 때 둘을
같이 고친다.

## 0. 왜 v0.2 인가

v0.1 은 문서가 없었고(코드 헤더가 존재하지 않는 파일을 참조했다), 그 사이 세 가지가 어긋나 있었다.

| 문제 | v0.1 | v0.2 |
|---|---|---|
| JUDGMENT 최소 길이 | 펌웨어가 21B 요구, 실제 파싱은 12B 페이로드(=19B) | **19B 로 통일** |
| EPOCH 의 `t_ms` | 샘플카운터에서 합성 → STATUS(millis)와 정렬 불가 | **자극 onset 의 실제 `millis()`** |
| 샘플 인덱스 | 전송 안 함 → 샘플링 지연 탐지 불가 | **`sample_index` 신설** |

버전 바이트를 올린 이유: 레이아웃이 바뀌었는데 버전이 같으면 구펌웨어 + 신툴 조합이 CRC 를
통과하면서 엉뚱한 오프셋을 읽는다. 수신측은 `version != 0x02` 를 **폐기** 한다.

## 1. 전송 계층

| 항목 | 값 |
|---|---|
| 광고 이름 | `REFIT-FES-01` |
| Service UUID | `6E400001-B5A3-F393-E0A9-E50E24DCCA9E` |
| UP (MCU→폰, notify) | `6E400003-B5A3-F393-E0A9-E50E24DCCA9E` |
| DOWN (폰→MCU, write) | `6E400002-B5A3-F393-E0A9-E50E24DCCA9E` |
| 바이트 순서 | little-endian |
| MTU 요청 | 247 (최대 패킷 53B 라 여유 충분) |

> macOS 스캔은 광고에 이름이 안 실릴 때가 있다. 이름과 Service UUID 둘 다로 매칭할 것.

## 2. 공통 헤더 (모든 메시지 6바이트)

| off | 타입 | 필드 | 비고 |
|---|---|---|---|
| 0 | u8 | `version` | `0x02` |
| 1 | u8 | `msg_type` | 업링크 `0x0X` / 다운링크 `0x1X` |
| 2..3 | u16 | `seq` | 방향별 독립 증가, 랩어라운드 허용 |
| 4..5 | u16 | `session_id` | `0` = 와일드카드(다운링크에서만) |

**모든 메시지의 마지막 1바이트는 CRC8** — 그 앞 전체 바이트에 대해 계산한다.

```
CRC8: poly=0x07, init=0x00, 반사 없음, 최종 XOR 없음
c = 0
for byte in data[:-1]:
    c ^= byte
    for _ in range(8):
        c = ((c << 1) ^ 0x07) & 0xFF if c & 0x80 else (c << 1) & 0xFF
```

## 3. 업링크 (MCU → 폰)

### 3.1 EPOCH `0x01` — 24 + 2n + 1 바이트 (1kHz, n=14 → 53B)

자극 1회당 1패킷. **판정에 쓰는 유일한 데이터다.**

| off | 타입 | 필드 | 의미 |
|---|---|---|---|
| 6..9 | u32 | `stim_index` | 세션 누적 자극 번호, 1부터. 결번 = 에폭 유실 |
| 10..13 | u32 | `t_ms` | 자극 onset 의 **실제 `millis()`** |
| 14..17 | u32 | `sample_index` | 자극 onset 의 샘플 인덱스 (세션 시작 시 0) |
| 18..19 | i16 | `spike` | 자극 스파이크 진폭 `max\|centered\|`, **onset ~ +2ms 구간에서만** |
| 20..21 | i16 | `p2p` | M-wave 창의 peak-to-peak |
| 22 | u8 | `flags` | bit0 `valid` · bit1 `sat_window` · bit2 `sat_spike` · bit3 예약 |
| 23 | u8 | `n` | 표본 개수 (1kHz = 14) |
| 24.. | i16×n | `samples` | DC 제거된 ADC 값, **+2 ~ +15ms** |
| 24+2n | u8 | `crc8` | |

**`spike` 가 왜 별도 필드인가.** 검증된 피로 지표는 M-wave 면적 자체가 아니라 `면적 ÷ spike` 다.
전극 드리프트는 분자·분모를 같이 움직이므로 이 비로 나누면 상쇄되고, 근육 피로만 남는다.
정규화 없이 생 M-wave 를 보면 전극이 밀린 것만으로 위양성이 난다.

**`spike` 측정 창이 `+2ms` 이전으로 제한된 이유.** 그 뒤는 M-wave 구간이라, 창을 넓히면 M-wave 가
분모에 섞여 비가 평평해진다 — 정규화가 잡으려는 신호를 정규화가 지운다.

**포화 플래그 (bit1 · bit2).** 12bit ADC 라 원 표본이 0 또는 4095 에 닿으면 그 값은 잘린 것이다.
MCU 는 `dcOffset` 으로 역산하지 않고 원 `raw` 를 직접 본다 — 오프셋이 세션마다 달라도 레일은
항상 0/4095 라 판정이 흔들리지 않는다.

| 비트 | 이름 | 의미 | 결과 |
|---|---|---|---|
| 1 | `sat_window` | +2~+15ms 표본이 레일에 닿음 | 면적이 실제보다 **작게** 나온다 |
| 2 | `sat_spike` | onset~+2ms 가 레일에 닿음 | **R 의 분모가 상수가 되어 정규화가 무력화된다** |

`sat_spike` 가 더 위험하다. 스파이크가 레일에 고정되면 `면적 ÷ 스파이크` 가 사실상 면적에
비례하는 값이 되어, 전극 드리프트 상쇄라는 목적 자체가 사라진다. **폰은 두 비트 중 하나라도
서면 그 에폭을 추세에서 빼야 한다** — `valid` 만 보고 넣으면 잘린 값이 그대로 판정에 들어간다.

포화율이 높으면 코드가 아니라 아날로그 문제다: MyoWare 게인을 낮추거나, 전극을 다시 잡거나,
자극 아티팩트 꼬리가 +2ms 를 넘어 살아 있다면 창 시작점을 늦춰야 한다.

> 예약 비트를 채운 것이므로 프로토콜 버전은 `0x02` 그대로다. 구 리더는 이 비트를 무시하며,
> `valid` 의 의미도 바뀌지 않았다.

**두 시계 정렬.** `EV_SESSION_START` 의 `t_ms` 를 세션 t0 로 잡으면:

```
expected_ms = sample_index * 1000 / sample_rate     # STATUS 의 sample_rate 사용
drift_ms    = (t_ms - t0_ms) - expected_ms
```

`drift_ms` 가 단조 증가하면 샘플링 태스크가 벽시계 대비 밀리고 있다는 뜻이다 — 이때 샘플 인덱스로
만든 시간축은 실제보다 압축돼 있다. **CSV 에 `drift_ms` 를 남길 것.** 한쪽 시계만 받으면 이 상태를
탐지할 방법이 아예 없다.

### 3.2 STATUS `0x02` — 22바이트, 5Hz

| off | 타입 | 필드 | 의미 |
|---|---|---|---|
| 6..9 | u32 | `t_ms` | `millis()` |
| 10 | u8 | `mcu_state` | 0 IDLE · 1 CALIBRATING · 2 RUNNING · 3 SAFE_HOLD · 4 STIM_OFF · 5 FAULT |
| 11 | u8 | `current_level` | **개루프 추정치** (§6 참조) |
| 12 | u8 | `stim_on` | bit0 |
| 13 | u8 | `health_flags` | bit0 watchdog · bit1 hardlimit · bit2 batt · bit3 sensor |
| 14..15 | u16 | `last_cmd_seq_ack` | 마지막으로 수락한 다운링크 `seq` |
| 16..17 | u16 | `sample_rate` | Hz |
| 18 | i8 | `mw_window_start_ms` | +2 |
| 19 | i8 | `mw_window_end_ms` | +15 |
| 20 | u8 | `max_level` | |
| 21 | u8 | `crc8` | |

`last_cmd_seq_ack` 가 보낸 `seq` 를 따라오지 않으면 **그 명령은 거부됐다** (§5).

### 3.3 EVENT `0x03` — 13바이트

| off | 타입 | 필드 |
|---|---|---|
| 6..9 | u32 | `t_ms` |
| 10 | u8 | `event_id` |
| 11 | u8 | `detail` |
| 12 | u8 | `crc8` |

| id | 이름 | detail | 비고 |
|---|---|---|---|
| 1 | `SESSION_START` | 0 | **이 패킷의 `t_ms` 가 세션 t0** |
| 2 | `REST_END` | 0 | 예약(미사용) |
| 3 | `SESSION_STOP` | 0 | |
| 4 | `FAULT` | 1 deadman · 2 자극시간 초과 | |
| 5 | `CALIB_DONE` | `dcOffset >> 4` | DC 캘리브 완료 → RUNNING |

## 4. 다운링크 (폰 → MCU)

`session_id` 는 STATUS/EVENT 에서 받은 값을 쓰거나 `0`(와일드카드)을 쓴다. 불일치하면 폐기된다.

### 4.1 JUDGMENT `0x11` — 19바이트

| off | 타입 | 필드 | 의미 |
|---|---|---|---|
| 6..9 | u32 | `t_ref_ms` | 이 판정이 근거한 에폭의 `t_ms` |
| 10..13 | u32 | `stim_index_ref` | 이 판정이 근거한 에폭의 `stim_index` |
| 14 | u8 | `stage` | 폰 판정 단계(펌웨어는 기록만) |
| 15 | u8 | `action` | 0 HOLD · 1 DECREASE · 2 INCREASE · 3 STOP |
| 16 | u8 | `target_level` | **절대 목표 세기** (상대 증감 아님) |
| 17 | u8 | `reliability` | 0 HIGH · 1 MED · 2 LOW |
| 18 | u8 | `crc8` | |

**절대 목표를 쓰는 이유.** 장치 세기를 읽을 수 없어 `current_level` 은 추정치다. 상대 증감(`+1`)은
오차가 누적되기만 하지만, 절대 목표는 추정이 맞는 한 수렴한다.

### 4.2 HEARTBEAT `0x12` — 11바이트

| off | 타입 | 필드 |
|---|---|---|
| 6..9 | u32 | `t_phone_ms` (펌웨어는 무시) |
| 10 | u8 | `crc8` |

**목적은 워치독 유지뿐이다.** 자극이 켜진 동안 `T_WATCHDOG_MS`(2s) 넘게 유효 다운링크가 없으면
SAFE_HOLD, `T_DEADMAN_MS`(8s) 넘으면 STIM_OFF. 500ms 주기 권장. JUDGMENT 도 워치독을 리셋한다.

### 4.3 SESSION_CONTROL `0x14` — 8바이트

| off | 타입 | 필드 |
|---|---|---|
| 6 | u8 | `cmd` |
| 7 | u8 | `crc8` |

| cmd | 이름 | 효과 |
|---|---|---|
| 1 | `REQUEST_START` | **기록** 시작 — 샘플링·에폭 송신. 자극은 켜지 않는다. 이미 진행 중이면 무시 |
| 2 | `REQUEST_STOP` | 세션 종료. 자극이 켜져 있었으면 전원도 끈다 |
| 3 | `STIM_ENABLE` | **자극 투입** — 레벨 0에서 전원 on. `ST_RUNNING` 일 때만 |
| 4 | `STIM_DISABLE` | 자극 차단 |

**START 와 STIM_ENABLE 이 분리된 이유.** 자극 없이 에폭만 모으는 로그 전용 검증이 별도 빌드 없이
가능해야 한다. 그리고 마사지기 전원·세기는 현재 사람이 직접 조작하므로, START 가 전원을 켠 것으로
가정하면 `stim_on` 이 실물과 어긋난다 — 그러면 INCREASE 게이트의 안전 조건이 거짓으로 통과한다.

## 5. 안전 비대칭 (비협상)

완전마비 대상은 과자극에 대한 감각 피드백이 없다. **감소는 즉시, 증가는 게이트를 통과할 때만.**

| 방향 | 조건 |
|---|---|
| `STOP` | 무조건 즉시 |
| `DECREASE` 또는 `target < current` | 무조건 즉시 |
| `HOLD` 또는 `target == current` | 동작 없음 |
| `INCREASE` | 아래 **전부** 만족해야 실행 |

INCREASE 게이트:

1. **신선도** — 도착 후 `T_STALE_MS`(3s) 이내이고, `stim_index - stim_index_ref <= 40`
2. **상태** — `mcu_state == RUNNING` **이고** `stim_on`
3. **신뢰도** — `reliability != LOW`
4. **변화율** — 한 판정당 최대 1단계
5. **하드리밋** — `target_level` 은 `max_level` 로 clamp

하나라도 어긋나면 **조용히 거부** 된다. 거부는 별도 패킷으로 알리지 않으므로, 폰은 STATUS 의
`current_level` 과 `last_cmd_seq_ack` 로 반영 여부를 확인해야 한다.

이 파라미터들은 **전부 MCU 소유이며 BLE 로 변경할 수 없다.** 폰이 아무리 요청해도 MCU 가 자체
조건을 만족하지 못하면 올라가지 않는다.

## 6. 알려진 한계

- **`current_level` 은 개루프 추정이다.** HV-F022-V 는 현재 세기를 읽어주지 않는다. 사람이 기기
  버튼을 직접 누르면 추정과 실물이 어긋나며, MCU 는 그것을 알 방법이 없다. 세션 시작 시 레벨 0
  가정에 의존한다.
- **`MAX_LEVEL = 10` 은 미확정치다.** HV-F022-V 의 실제 단계 수로 확인해야 한다.
- **`STIM_OFF` 는 그 세션에서 복귀 불가다.** deadman 이나 자극시간 초과로 진입하면
  `REQUEST_STOP` → `REQUEST_START` 로 새 세션을 열어야 한다.
- **자극 액추에이션 경로는 실물 미검증이다.** 마사지기가 아직 배선되지 않았다.

## 7. 폐기 규칙 (수신측)

다음은 **응답 없이 조용히 버린다.** 폰은 STATUS 의 `last_cmd_seq_ack` 로만 수락 여부를 안다.

| 조건 | 적용 |
|---|---|
| `len < 7` | 모든 메시지 |
| `version != 0x02` | 모든 메시지 |
| CRC8 불일치 | 모든 메시지 |
| `session_id` 불일치 (0 제외) | 다운링크 |
| `len < 19` | JUDGMENT |
| `len < 8` | SESSION_CONTROL |
| 알 수 없는 `cmd` | SESSION_CONTROL |

CRC 를 통과한 모든 다운링크는 타입과 무관하게 **워치독을 리셋한다.**

## 8. 검증

```bash
pip install bleak
python scripts/refit_ble_bench.py monitor        # 연결·STATUS 확인 (세션 없이도 5Hz로 온다)
python scripts/refit_ble_bench.py start          # 기록 시작 → EPOCH 흐르기 시작
python scripts/refit_ble_bench.py judge --action decrease --level 2
python scripts/refit_ble_bench.py watchdog-test  # stim-on 후 하트비트 끊어 SAFE_HOLD→STIM_OFF 관찰
```

`monitor` 는 `stim_index` 결번과 `drift_ms` 를 같이 찍는다. 이 둘이 계약이 지켜지는지 보는 1차 지표다.
