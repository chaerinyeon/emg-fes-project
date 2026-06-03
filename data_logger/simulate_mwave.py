"""
mwave_SIMULATED.csv 생성기

emg_fes_controller.ino 의 1kHz 샘플링 + RMS/MDF/slope 파이프라인 + M-wave 검출 로직을
파이썬으로 재현해 1kHz 모의 EMG를 만들고 CSV로 저장한다.

시나리오:
  t = 0 ~ 10s : 휴식(베이스라인 수집), FES OFF
  t = 10s     : 지속수축 시작 + FES 20Hz ON (M-wave 유발)
  t = 10 ~ 70s : 피로 진행 — RMS 점점 상승, MDF 점점 하강
  t ≈ 60s     : RMS slope > +20% AND MDF slope < -3% 가 5초 연속 만족 → 근피로 검출
  t = 70 ~ 80s : 자극 정지, 휴식 복귀
"""

from __future__ import annotations

import csv
import math
from datetime import datetime, timedelta
from pathlib import Path

import numpy as np

# ===== .ino 와 동일한 파라미터 =====
SAMPLE_RATE = 1000
FFT_SIZE = 256
RMS_WINDOW = 1000
HISTORY_SIZE = 60
DC_OFFSET = 1900
RMS_THRESHOLD = 20.0
MDF_THRESHOLD = -3.0
CONSECUTIVE_TRIGGER = 5

BASELINE_SAMPLES = 10
MUSCLE_LOW_RATIO = 0.7
MUSCLE_HIGH_RATIO = 1.5

# M-wave 검출 파라미터
MW_ARTIFACT_THRESHOLD = 1500
MW_WINDOW_START_MS = 5
MW_WINDOW_END_MS = 30
MW_WINDOW_LEN = (MW_WINDOW_END_MS - MW_WINDOW_START_MS) + 1
MW_REFRACTORY_MS = 40

# Envelope LPF
ENV_LPF_ALPHA = 0.03

# ===== 시뮬레이션 시나리오 =====
T_BASELINE_S = 10
T_CONTRACT_S = 60
T_POST_S = 10
T_TOTAL_S = T_BASELINE_S + T_CONTRACT_S + T_POST_S    # 80s
N_TOTAL = T_TOTAL_S * SAMPLE_RATE

FES_RATE_HZ = 20
FES_PERIOD_MS = int(round(1000 / FES_RATE_HZ))        # 50ms

WALL_T0 = datetime(2026, 6, 2, 14, 0, 0, 0)
TIMESTAMP_BASE_MS = 5000

OUT_PATH = Path(__file__).resolve().parent.parent / "data" / "mwave_SIMULATED.csv"


def synthesize_raw_emg(rng: np.random.Generator) -> np.ndarray:
    """1kHz raw EMG (12-bit ADC counts) 시뮬레이션."""
    t = np.arange(N_TOTAL) / SAMPLE_RATE                 # 초 단위
    emg = np.zeros(N_TOTAL, dtype=np.float64)

    # ----- 1) 자발적 EMG: 대역제한 잡음 → 시간에 따라 진폭↑, 평균주파수↓ -----
    # 백색잡음에 시변 1차 IIR 대역필터(좁은 폭) 적용
    white = rng.standard_normal(N_TOTAL)
    contract_mask = (t >= T_BASELINE_S) & (t < T_BASELINE_S + T_CONTRACT_S)

    # 시변 중심주파수: 수축구간 80Hz → 55Hz 로 선형 하강 (피로 모사)
    contract_progress = np.clip(
        (t - T_BASELINE_S) / T_CONTRACT_S, 0.0, 1.0
    )
    center_hz = 80.0 - 25.0 * contract_progress

    # 좁은 대역 효과를 1kHz 단순 IIR 공명기로 흉내
    # y[n] = 2 r cos(2π f/fs) y[n-1] - r^2 y[n-2] + (1-r) x[n]
    r = 0.985
    bp = np.zeros(N_TOTAL, dtype=np.float64)
    y1 = y2 = 0.0
    fs = SAMPLE_RATE
    for n in range(N_TOTAL):
        a = 2 * r * math.cos(2 * math.pi * center_hz[n] / fs)
        b = r * r
        y = a * y1 - b * y2 + (1 - r) * white[n]
        bp[n] = y
        y2 = y1
        y1 = y

    # 시변 진폭: 휴식 ≈ 0.3, 수축 시작 1.0 → 60s 후 4.0 (RMS slope > +20%/30s 보장)
    amp = np.full(N_TOTAL, 0.3)
    amp[contract_mask] = 1.0 + 3.0 * contract_progress[contract_mask]
    # 자극 종료 후 빠르게 감쇠
    post_mask = t >= T_BASELINE_S + T_CONTRACT_S
    amp[post_mask] = 4.0 * np.exp(-(t[post_mask] - (T_BASELINE_S + T_CONTRACT_S)) / 2.0) + 0.3

    emg += bp * amp * 160.0                              # ADC counts 스케일

    # 약한 광역 잡음 (전 구간)
    emg += rng.standard_normal(N_TOTAL) * 6.0

    # ----- 2) FES 자극에 의한 M-wave -----
    stim_active = contract_mask
    if stim_active.any():
        # 자극 시작 시각 (수축 시작 = 10s) 이후 50ms 주기
        stim_start_idx = int(T_BASELINE_S * SAMPLE_RATE)
        stim_end_idx = int((T_BASELINE_S + T_CONTRACT_S) * SAMPLE_RATE)
        pulse_idxs = list(range(stim_start_idx, stim_end_idx, FES_PERIOD_MS))

        for p in pulse_idxs:
            # 큰 자극 아티팩트 1샘플 (양극성)
            artifact = 1800.0 + rng.standard_normal() * 120.0
            if p < N_TOTAL:
                emg[p] += artifact
                # 다음 1ms 에 빠른 반동 (-) — artifact 두께
                if p + 1 < N_TOTAL:
                    emg[p + 1] += -artifact * 0.45

            # M-wave 응답파 (5~30ms 윈도우, 이중상)
            # 피로가 진행될수록 진폭이 약간 증가 (전형적 모델)
            stim_progress = (p - stim_start_idx) / max(1, stim_end_idx - stim_start_idx)
            mw_scale = 1.0 + 0.4 * stim_progress
            for k_ms in range(MW_WINDOW_START_MS, MW_WINDOW_END_MS + 1):
                idx = p + k_ms
                if idx >= N_TOTAL:
                    break
                # 양극성: 8ms 양, 16ms 음
                pos = 420.0 * math.exp(-((k_ms - 8) ** 2) / 18.0)
                neg = -260.0 * math.exp(-((k_ms - 17) ** 2) / 32.0)
                emg[idx] += (pos + neg) * mw_scale

    # ----- 3) DC offset + 12-bit clamp -----
    raw = np.round(emg + DC_OFFSET).astype(np.int32)
    raw = np.clip(raw, 0, 4095)
    return raw


def calc_rms(window: np.ndarray) -> float:
    """ino calculateRMS() — 평균 제거 후 RMS."""
    centered = window.astype(np.float64) - DC_OFFSET
    mean = centered.mean()
    return float(np.sqrt(((centered - mean) ** 2).mean()))


def calc_mdf(window: np.ndarray) -> float:
    """ino calculateMDF() — FFT_SIZE 샘플로 누적전력 절반 지점 주파수."""
    seg = window[:FFT_SIZE].astype(np.float64)
    seg = seg - seg.mean()
    # Hamming window
    seg = seg * np.hamming(FFT_SIZE)
    spec = np.abs(np.fft.rfft(seg))
    # ino 는 bin 1 ~ FFT_SIZE/2 - 1 누적
    bins = spec[1:FFT_SIZE // 2]
    total = bins.sum()
    if total <= 0:
        return 0.0
    cum = np.cumsum(bins)
    idx = int(np.searchsorted(cum, total / 2.0)) + 1     # +1: ino 는 i=1 부터
    return idx * SAMPLE_RATE / FFT_SIZE


def slope_percent(history: list[float]) -> float:
    """ino calculateSlopePercent() — 선형회귀 기울기를 평균값으로 정규화한 %."""
    n = len(history)
    if n < 2:
        return 0.0
    x = np.arange(n, dtype=np.float64)
    y = np.asarray(history, dtype=np.float64)
    mean_y = y.mean()
    if mean_y < 0.01:
        return 0.0
    sum_xy = (x * y).sum()
    sum_x = x.sum()
    sum_y = y.sum()
    sum_x2 = (x * x).sum()
    denom = n * sum_x2 - sum_x * sum_x
    if denom == 0:
        return 0.0
    slope = (n * sum_xy - sum_x * sum_y) / denom
    return float(slope * n / mean_y * 100.0)


def detect_mwaves(raw: np.ndarray, stim_window_s: tuple[float, float]):
    """ino sampling task 의 M-wave 검출을 후처리로 재현.
    반환: list of (timestamp_ms, amp, area, latency_ms)."""
    centered = raw.astype(np.int32) - DC_OFFSET
    abs_c = np.abs(centered)
    s0 = int(stim_window_s[0] * SAMPLE_RATE)
    s1 = int(stim_window_s[1] * SAMPLE_RATE)

    last_at_ms = -10_000
    events = []
    i = s0
    while i < s1:
        if abs_c[i] > MW_ARTIFACT_THRESHOLD and (i - last_at_ms) > MW_REFRACTORY_MS:
            last_at_ms = i
            seg_start = i + MW_WINDOW_START_MS
            seg_end = min(i + MW_WINDOW_END_MS + 1, len(centered))
            if seg_end - seg_start >= 5:
                seg = centered[seg_start:seg_end]
                amp = float(seg.max() - seg.min())
                area = float(np.abs(seg).sum())
                peak_offset = int(np.argmax(seg))
                latency = float(MW_WINDOW_START_MS + peak_offset)
                events.append((i, amp, area, latency))
            i += MW_REFRACTORY_MS
        else:
            i += 1
    return events


def main() -> None:
    rng = np.random.default_rng(42)
    print(f"[sim] generating {N_TOTAL} samples ({T_TOTAL_S}s @ {SAMPLE_RATE}Hz)…")
    raw = synthesize_raw_emg(rng)

    # M-wave 이벤트 후처리 검출
    print("[sim] detecting M-waves…")
    mw_events = detect_mwaves(raw, (T_BASELINE_S, T_BASELINE_S + T_CONTRACT_S))
    print(f"[sim]   → {len(mw_events)} M-wave events")
    # 검출 시각(샘플 idx, ms) → 이벤트 정보
    mw_by_idx = {ev[0]: ev for ev in mw_events}

    # 1초 슬라이딩 처리 (ino 와 동일: 1초 윈도우 모이면 RMS/MDF 계산 후 history 누적)
    rms_history: list[float] = []
    mdf_history: list[float] = []

    # 누적 상태
    consecutive = 0
    fatigue_detected = False
    fatigue_latched_until_s: float | None = None
    FATIGUE_LATCH_S = 10.0

    baseline_ready = False
    baseline_rms = 0.0

    # envelope (LPF)
    env_lpf = 0.0

    # 누적 M-wave 카운트 / 최신 메트릭 / 1초 집계 (다음 1초 boundary 에서 출력)
    mw_count_running = 0
    last_mw_metrics: tuple[float, float, float] | None = None

    # 1초마다 갱신되는 집계값 — 다음 boundary 까지 모든 1ms 행에 그대로 채움
    cur_rms = 0.0
    cur_mdf = 0.0
    cur_rs = 0.0
    cur_ms = 0.0
    cur_state = "calibrating"
    cur_ratio = 1.0
    history_count = 0

    print("[sim] computing per-second metrics + writing 1kHz CSV…")
    # ----- 1초 단위로 집계를 미리 계산해 두기 -----
    sec_metrics: list[dict] = []
    for sec in range(T_TOTAL_S):
        s0 = sec * SAMPLE_RATE
        s1 = s0 + SAMPLE_RATE
        win = raw[s0:s1]

        is_running = True
        is_stimulating = T_BASELINE_S <= sec < T_BASELINE_S + T_CONTRACT_S

        rms = calc_rms(win)
        mdf = calc_mdf(win)
        rms_history.append(rms)
        mdf_history.append(mdf)
        if len(rms_history) > HISTORY_SIZE:
            rms_history.pop(0)
            mdf_history.pop(0)

        if len(rms_history) >= 30:
            rs = slope_percent(rms_history)
            ms = slope_percent(mdf_history)
        else:
            rs = 0.0
            ms = 0.0

        if len(rms_history) >= 30 and is_running:
            fatigue_cond = (rs > RMS_THRESHOLD) and (ms < MDF_THRESHOLD)
            if fatigue_cond:
                consecutive += 1
                if consecutive >= CONSECUTIVE_TRIGGER and not fatigue_detected:
                    fatigue_detected = True
                    fatigue_latched_until_s = sec + FATIGUE_LATCH_S
                    print(f"[sim] ⚠️ fatigue at t={sec}s  RMS slope=+{rs:.1f}%  MDF slope={ms:.1f}%")
            else:
                consecutive = 0

        if fatigue_detected and fatigue_latched_until_s is not None:
            if sec >= fatigue_latched_until_s:
                fatigue_detected = False

        if not baseline_ready and len(rms_history) >= BASELINE_SAMPLES:
            baseline_rms = float(np.mean(rms_history[:BASELINE_SAMPLES]))
            baseline_ready = True

        rms_ratio = (rms / baseline_rms) if baseline_ready and baseline_rms > 0.01 else 1.0
        if not is_running:
            muscle_state = "idle"
        elif not baseline_ready:
            muscle_state = "calibrating"
        elif fatigue_detected:
            muscle_state = "fatigue"
        elif rms_ratio > MUSCLE_HIGH_RATIO:
            muscle_state = "high"
        elif rms_ratio < MUSCLE_LOW_RATIO:
            muscle_state = "low"
        else:
            muscle_state = "normal"

        sec_metrics.append({
            "rms": rms,
            "mdf": mdf,
            "rs": rs,
            "ms": ms,
            "consecutive": consecutive,
            "fatigue_detected": fatigue_detected,
            "is_running": is_running,
            "is_stimulating": is_stimulating,
            "baseline_rms": baseline_rms,
            "rms_ratio": rms_ratio,
            "muscle_state": muscle_state,
            "history_count": len(rms_history),
        })

    # ----- 이제 1kHz 행을 쓰면서 1초 boundary 에서 집계값 / 마커 / M-wave 메트릭 채움 -----
    rows: list[dict] = []
    sec_idx = -1                                            # 아직 어떤 1초도 끝나지 않음
    for i in range(N_TOTAL):
        t_ms_offset = i + 1                                 # 0-indexed 샘플 i 는 1ms 후 시점
        ts_ms = TIMESTAMP_BASE_MS + t_ms_offset
        wall = WALL_T0 + timedelta(milliseconds=t_ms_offset)
        wall_str = wall.strftime("%Y-%m-%dT%H:%M:%S.") + f"{wall.microsecond // 1000:03d}"

        # envelope LPF (1kHz 업데이트)
        centered = int(raw[i]) - DC_OFFSET
        env_lpf = ENV_LPF_ALPHA * abs(centered) + (1.0 - ENV_LPF_ALPHA) * env_lpf

        # 새 M-wave 이벤트가 정확히 이 샘플 위치에서 검출됐다면 메트릭 갱신
        mw_new = False
        mw_amp_out = ""
        mw_area_out = ""
        mw_lat_out = ""
        if i in mw_by_idx:
            _, amp, area, lat = mw_by_idx[i]
            mw_count_running += 1
            last_mw_metrics = (amp, area, lat)
            mw_amp_out = round(amp, 2)
            mw_area_out = round(area, 2)
            mw_lat_out = round(lat, 2)
            mw_new = True

        # 1초 boundary: 이 샘플이 1초 윈도우의 마지막 샘플이면 집계값을 다음 1초 동안 사용
        if (i + 1) % SAMPLE_RATE == 0:
            sec_idx += 1
            m = sec_metrics[sec_idx]
            cur_rms = m["rms"]
            cur_mdf = m["mdf"]
            cur_rs = m["rs"]
            cur_ms = m["ms"]
            cur_state = m["muscle_state"]
            cur_ratio = m["rms_ratio"]
            history_count = m["history_count"]
            cur_consecutive = m["consecutive"]
            cur_fatigue = m["fatigue_detected"]
            cur_is_running = m["is_running"]
            cur_is_stim = m["is_stimulating"]
            cur_baseline = m["baseline_rms"]
        else:
            # 아직 첫 1초가 안 모였으면 0
            if sec_idx < 0:
                cur_consecutive = 0
                cur_fatigue = False
                cur_is_running = True
                cur_is_stim = False
                cur_baseline = 0.0
            else:
                m = sec_metrics[sec_idx]
                cur_consecutive = m["consecutive"]
                cur_fatigue = m["fatigue_detected"]
                cur_is_running = m["is_running"]
                cur_is_stim = m["is_stimulating"]
                cur_baseline = m["baseline_rms"]

        # 마커는 정확한 시각에 한 행만
        cur_sec = (i + 1) // SAMPLE_RATE
        if i == 0:
            marker = "session_start"
        elif i + 1 == T_BASELINE_S * SAMPLE_RATE:
            marker = "stim_on"
        elif i + 1 == (T_BASELINE_S + T_CONTRACT_S) * SAMPLE_RATE:
            marker = "stim_off"
        elif i + 1 == N_TOTAL:
            marker = "session_stop"
        else:
            marker = ""

        rows.append({
            "wall_time": wall_str,
            "timestamp_ms": ts_ms,
            "emg_raw": int(raw[i]),
            "emg_env": round(env_lpf, 2),
            "rms": round(cur_rms, 4) if sec_idx >= 0 else "",
            "mdf": round(cur_mdf, 4) if sec_idx >= 0 else "",
            "rms_slope": round(cur_rs, 4) if sec_idx >= 0 else "",
            "mdf_slope": round(cur_ms, 4) if sec_idx >= 0 else "",
            "fatigue_detected": cur_fatigue,
            "consecutive": cur_consecutive,
            "is_running": cur_is_running,
            "is_stimulating": cur_is_stim,
            "history_count": history_count,
            "baseline_rms": round(cur_baseline, 4) if cur_baseline else "",
            "rms_ratio": round(cur_ratio, 4) if sec_idx >= 0 else "",
            "muscle_state": cur_state if sec_idx >= 0 else "calibrating",
            "mw_amp": mw_amp_out,
            "mw_area": mw_area_out,
            "mw_latency_ms": mw_lat_out,
            "mw_count": mw_count_running,
            "mw_new": mw_new,
            "marker": marker,
        })

    # ----- CSV 저장 -----
    fieldnames = list(rows[0].keys())
    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    with OUT_PATH.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames)
        w.writeheader()
        w.writerows(rows)

    print(f"[sim] wrote {len(rows)} rows → {OUT_PATH}")
    print(f"[sim]   M-wave 누적 검출: {mw_count_running}")
    fatigue_idxs = [i for i, r in enumerate(rows) if r["fatigue_detected"]]
    if fatigue_idxs:
        t0 = fatigue_idxs[0] / SAMPLE_RATE
        t1 = fatigue_idxs[-1] / SAMPLE_RATE
        print(f"[sim]   fatigue True 구간: t={t0:.2f}s ~ t={t1:.2f}s")


if __name__ == "__main__":
    main()
