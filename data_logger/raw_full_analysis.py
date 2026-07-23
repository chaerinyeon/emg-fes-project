#!/usr/bin/env python3
"""
raw_full_analysis.py — raw 1kHz 전체 세션 분석. 품질 게이트를 통과한 세션만 판정한다.

raw 만 쓰는 이유: env/emg 는 기기가 이미 해석한 값이라 되돌릴 수 없고, env 에는
대조군(자극 스파이크)이 아예 없다. 마커만 env 에서 읽는다.

순서
  1. 품질 게이트 — 통과 못 하면 '피로다/아니다'를 말하지 않고 분석불가로 남긴다.
       G1 자극구조 : 주기 1500~1750ms, 버스트당 펄스 ~20, 버스트내 펄스율 ~32Hz
       G2 STA 정렬 : STA 정점 / 개별 정점 평균 ≥ 0.5  (위상이 흩어지면 0 으로 감)
       G3 대조군포화: 스파이크가 ADC 레일에 닿은 시행 ≤ 5%
                     (포화되면 R 의 분모가 검열돼 전극 이득 약분이 성립하지 않음)
     ※ 스파이크 부호 일관성은 게이트로 쓰지 않는다 — 위 상수 주석 참조.
  2. 창 실측 — M-wave 잠복은 전극 거리에 따라 세션마다 3ms↔11ms 로 변한다.
     고정 창을 쓰면 깨지므로 세션별 STA 에서 잠복과 창을 다시 잰다.
  3. R = M-wave ÷ 스파이크
       스파이크(0~1ms)는 근육이 물리적으로 반응할 수 없는 구간 → 전극 이득의 대조군.
       나누면 전극 이득이 약분된다.
     R 절대값은 전극 기하에 좌우돼 세션끼리 비교 불가 → 세션 내 변화율(%)로만 본다.
  4. 대조군이 평평한지 먼저 보고, 그 다음에만 R 을 해석한다.

사용: python3 raw_full_analysis.py [<raw.csv> ...] [--plot]
"""
from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
import pandas as pd

FS = 1000.0                 # Hz
ENV_WIN = 51                # ms, 포락선 이동평균 창
MIN_BURST_MS = 100
ADC_MIN, ADC_MAX = 0, 4095  # 12bit 레일

# --- G1 자극구조 게이트 (실측: 주기 1621.9ms, 버스트당 20펄스, 32.078Hz) ---
PERIOD_LO, PERIOD_HI = 1500, 1750     # ms
PPB_LO, PPB_HI = 15, 25               # 버스트당 펄스 수
PRATE_LO, PRATE_HI = 25.0, 40.0       # Hz, 버스트 내 펄스율
MIN_BURSTS = 8

# --- G2/G3 게이트 ---
STA_RATIO_GATE = 0.5        # STA 정점 / 개별 정점 평균
# 스파이크 극성 일관성은 게이트가 아니라 진단값으로만 낸다.
# 1kHz 로는 이상성 자극 파형의 어느 로브가 찍힐지가 서브밀리초 위상에 좌우된다.
# 실측: 부호 그룹 간 |스파이크| 크기(648 vs 759)도 M-wave 크기(비 0.87~1.01)도
# 같았다 — 부호는 근육·전극이 아니라 ADC 클럭 대비 자극 위상을 재고 있었다.
CLIP_GATE = 5.0             # %, 스파이크가 ADC 레일에 닿은 시행 비율 상한.
                            # 대조군이 포화되면 R 의 분모가 검열된 값이라
                            # '전극 이득 약분'이 성립하지 않는다.

# 불응기는 펄스주기(실측 31.185ms)보다 짧아야 하되 너무 짧으면 안 된다.
#   40 → 40>31 이라 자극의 절반을 놓침 (검출률 50%)
#   25 → 한 자극의 양극성 두 상(음→양, ~1~3ms 간격)을 두 번 셈. 스파이크가 약한
#        세션에서 25ms 간격 검출이 13~24% 발생 → 버스트내 펄스율이 무너졌다.
#   28 → 진짜 간격 31ms(최소 30)는 통과, 중복만 차단. 실측으로 확인.
PULSE_REFRAC = 28
ART_HI = 2                  # 스파이크 창 0~1ms (대조군)
# STA 창은 펄스주기(최소 30ms)를 넘으면 안 된다. 넘으면 창 안에 이웃 자극이 들어와
# 기준선(t<0)을 오염시키고, 그 기준선으로 잰 스파이크가 통째로 망가진다.
#   5+35=40ms 였을 때: 144215 의 t<0 구간 표본 13.5% 가 자극 문턱을 넘었다(정상 세션은 0%).
#   5+25=30ms = 최소 펄스간격. M-wave 꼬리는 실측 최대 23ms 라 창 안에 다 들어온다.
STA_PRE, STA_POST = 5, 25
LAT_LO, LAT_HI = 3, 25      # ms, M-wave 잠복 탐색 범위 (스파이크 링잉 회피)
LOBE_FRAC = 0.5             # STA 정점의 이 비율 이상인 연속 구간 = M-wave 창

DECOMP_BLOCKS = 12
BLOCK_MIN_S, BLOCK_MAX_S = 10.0, 20.0
MIN_PULSE_PER_BLOCK = 20

RHO_GATE = 0.5              # 추세 인정 문턱 (Spearman)
PCT_GATE = 15.0             # 추세 인정 문턱 (Q1→Q4 %)
ART_FLAT_PCT = 10.0         # 대조군이 이만큼 넘게 변하면 '평평'이라 할 수 없음
ART_FLAT_RHO = 0.5


# ---------------------------------------------------------------- 적재
def load_raw(path: Path):
    """raw CSV → (x=signed, absr, dc, dropped, clip, v). 이전 세션 잔여 패킷 제거."""
    d = pd.read_csv(path)
    t = d["Time(ms)"].to_numpy()
    v = d["Raw_ADC"].to_numpy(dtype=float)
    dropped = 0
    back = np.where(np.diff(t) < 0)[0]
    if len(back):
        dropped = int(back[-1] + 1)
        v = v[dropped:]
    dc = float(np.median(v))
    clip = float(((v <= ADC_MIN) | (v >= ADC_MAX)).mean() * 100)
    return v - dc, np.abs(v - dc), dc, dropped, clip, v


def load_markers(raw_path: Path) -> str:
    """마커는 env 에서만 읽는다 (raw 에는 없다)."""
    env = raw_path.parent / raw_path.name.replace("raw_", "env_")
    if not env.exists():
        return ""
    try:
        d = pd.read_csv(env)
    except Exception:
        return ""
    if "Marker" not in d.columns:
        return ""
    m = d["Marker"].dropna().astype(str)
    m = m[m.str.strip() != ""]
    if m.empty:
        return ""
    return ",".join(f"{k}x{v}" for k, v in m.value_counts().items())


# ---------------------------------------------------------------- 검출
def otsu(x: np.ndarray, nb: int = 256) -> float:
    lo, hi = float(x.min()), float(np.percentile(x, 99.5))
    if hi <= lo:
        return float("inf")
    h, e = np.histogram(np.clip(x, lo, hi), bins=nb, range=(lo, hi))
    p = h.astype(float) / h.sum()
    c = np.cumsum(p)
    m = np.cumsum(p * ((e[:-1] + e[1:]) / 2))
    d = c * (1 - c)
    d[d == 0] = 1e-12
    k = int(np.argmax((m[-1] * c - m) ** 2 / d))
    return float((e[k] + e[k + 1]) / 2)


def find_bursts(absr: np.ndarray) -> list[tuple[int, int]]:
    """포락선 + Otsu. 개별 펄스에 고정문턱을 걸면 자극이 약한 세션을 통째로 놓친다."""
    env = pd.Series(absr).rolling(ENV_WIN, center=True, min_periods=1).mean().to_numpy()
    on = env > otsu(env)
    ch = np.diff(on.astype(np.int8))
    st = list(np.where(ch == 1)[0] + 1)
    en = list(np.where(ch == -1)[0] + 1)
    if on[0]:
        st.insert(0, 0)
    if on[-1]:
        en.append(len(on))
    return [(a, b) for a, b in zip(st, en) if b - a >= MIN_BURST_MS]


def find_pulses(absr: np.ndarray) -> np.ndarray:
    """개별 자극 펄스 시점. 문턱은 파일별 적응."""
    thr = max(50.0, 0.35 * np.percentile(absr, 99.9))
    idx = np.where(absr > thr)[0]
    out, last = [], -10_000
    for i in idx:
        if i - last >= PULSE_REFRAC:
            out.append(i)
            last = i
    return np.array(out, dtype=int)


# ---------------------------------------------------------------- STA / 창 실측
ALIGN_SEARCH = 4        # ms, 문턱교차 이후 스파이크 정점을 찾는 범위


def refine_pulses(x: np.ndarray, pulses: np.ndarray) -> np.ndarray:
    """각 시행을 자기 스파이크 정점(|x| 최대)에 다시 정렬한다.

    자극은 1kHz 샘플링 클럭에 대해 서브밀리초 지터를 갖는다. 실측하면 같은
    이상성 파형이 시행마다 ±1~2 샘플씩 밀려 찍힌다. 문턱교차 시점을 t=0 으로
    쓰면 고정 창이 어떤 시행에선 음의 로브를, 어떤 시행에선 양의 로브를 잡아
    부호가 흩어진다 — 데이터가 나빠서가 아니라 정렬을 안 해서다.
    """
    out = []
    for p in pulses:
        lo, hi = p, min(len(x), p + ALIGN_SEARCH)
        if hi <= lo:
            continue
        out.append(lo + int(np.argmax(np.abs(x[lo:hi]))))
    return np.array(sorted(set(out)), dtype=int)


SIGN_MAJORITY_MIN = 0.55    # 다수파가 이보다 적으면 극성이 반반 = 정렬 불가로 본다
SIGN_KEEP_MIN = 200         # 다수파만 남겼을 때 필요한 최소 시행 수


def build_sta(x: np.ndarray, pulses: np.ndarray):
    """펄스 정렬 평균(STA)과 개별 시행 행렬. 부호를 살린 x 로 낸다.

    스파이크 극성이 시행마다 갈리면 다수파만 평균한다.
    정점 정렬(refine_pulses)로는 이게 안 고쳐진다 — 이상성 펄스의 |최대|가 어떤
    시행에선 음의 상에, 어떤 시행에선 양의 상에 있으면 |x| 로 정렬해도 두 무리가
    남고, 평균하면 서로 지운다. 실측(144215): 음 442개 STA +495, 양 301개 STA −402
    → 섞어 평균하면 64 (정렬비 0.13). 음의 것만 쓰면 정렬비 1.00 으로 완전 복원.
    표본은 40% 줄지만 442개면 STA 에 충분하다.
    """
    sel = pulses[(pulses >= STA_PRE) & (pulses < len(x) - STA_POST)]
    if len(sel) < 50:
        return None, None, sel, {}
    seg = np.stack([x[s - STA_PRE:s + STA_POST] for s in sel])
    sgn = np.sign(seg[:, STA_PRE])                 # 정렬된 t=0 의 부호
    frac_neg = float((sgn < 0).mean())
    keep = (sgn < 0) if frac_neg >= 0.5 else (sgn > 0)
    # 버린 소수파가 세션 특정 구간에 몰렸는지 — 몰렸다면 그 구간이 판정에서 빠져
    # R 궤적이 편향된다. 조용히 버리지 말고 드러낸다(실측 144215: 버린 16%가 초반에 몰림).
    drop_bias = 0.0
    if keep.sum() < len(sel):
        td = sel[~keep].astype(float); span = sel.max() - sel.min()
        if span > 0:
            early = float((td < sel.min() + 0.2 * span).mean())   # 초반 20%에 든 비율
            drop_bias = early - 0.2                                # 0 = 고르게 분포
    info = {"sign_major": float(max(frac_neg, 1 - frac_neg)),
            "n_all": int(len(sel)), "n_kept": int(keep.sum()),
            "drop_bias": float(drop_bias)}
    if info["sign_major"] < SIGN_MAJORITY_MIN or info["n_kept"] < SIGN_KEEP_MIN:
        return None, None, sel, info          # 극성이 반반 → 이 세션은 STA 불가
    return seg[keep].mean(axis=0), seg[keep], sel[keep], info


def measure_window(sta: np.ndarray, seg: np.ndarray) -> dict:
    """세션별 M-wave 잠복·창 실측 + STA 정렬 품질.

    잠복 탐색은 3~25ms — 0~2ms 는 스파이크와 그 링잉이라 근육 반응일 수 없다.
    창은 STA 정점의 50% 이상인 연속 구간(로브)으로 잡는다. 고정 5~15ms 는
    잠복이 3ms 인 세션에선 상승부를, 11ms 인 세션에선 하강부를 놓친다.
    """
    o = STA_PRE                                   # sta[o] == 펄스 t=0
    lo, hi = o + LAT_LO, o + LAT_HI
    seg_a = np.abs(sta[lo:hi])
    if not len(seg_a) or seg_a.max() <= 0:
        return {}
    k = int(np.argmax(seg_a)) + lo               # STA 상 M-wave 정점 인덱스
    pk = abs(sta[k])

    # 로브 경계 — 정점에서 좌우로 50% 아래로 내려갈 때까지
    a = k
    while a > lo and abs(sta[a - 1]) >= LOBE_FRAC * pk:
        a -= 1
    b = k
    while b < hi - 1 and abs(sta[b + 1]) >= LOBE_FRAC * pk:
        b += 1

    # G2: 정렬 품질 — STA 정점 / 개별 시행 정점의 평균 크기
    ind = float(np.mean(np.abs(seg[:, k])))
    sta_ratio = pk / ind if ind > 0 else 0.0

    # 부호 일관성은 build_sta 가 다수파만 남긴 뒤라 항상 1.0 — 여기서 재지 않는다.
    # 원래 비율(sign_major)과 버린 시행의 시간 편향은 build_sta 가 보고한다.
    return {
        "lat_ms": float(k - o),
        "mw_lo": int(a - o), "mw_hi": int(b - o + 1),
        "sta_ratio": float(sta_ratio),
        "sta_peak": float(pk),
    }


# ---------------------------------------------------------------- 추세
def spearman(x, y) -> float:
    xr = pd.Series(x).rank().to_numpy().astype(float)
    yr = pd.Series(y).rank().to_numpy().astype(float)
    xr -= xr.mean()
    yr -= yr.mean()
    d = np.sqrt((xr ** 2).sum() * (yr ** 2).sum())
    return float((xr * yr).sum() / d) if d > 0 else np.nan


NO_TREND = {"rho": np.nan, "pct_min": np.nan, "q1q4": np.nan}


def trend(t_s: np.ndarray, y: np.ndarray) -> dict:
    n = len(y)
    if n < 8:
        return dict(NO_TREND)
    q = max(2, n // 4)
    base = float(np.median(y[:q]))
    last = float(np.median(y[-q:]))
    slope = float(np.polyfit(t_s, y, 1)[0])
    return {
        "rho": spearman(t_s, y),
        "pct_min": slope * 60.0 / base * 100.0 if base > 0 else np.nan,
        "q1q4": (last / base - 1.0) * 100.0 if base > 0 else np.nan,
    }


def decompose(absr: np.ndarray, pulses: np.ndarray, win: dict) -> pd.DataFrame:
    """블록별 art(0~1ms 최대) / mw(실측창 평균) / R = mw/art."""
    lo_ms, hi_ms = win["mw_lo"], win["mw_hi"]
    blk_s = min(BLOCK_MAX_S, max(BLOCK_MIN_S, len(absr) / FS / DECOMP_BLOCKS))
    blk = int(blk_s * FS)
    rows = []
    for lo in range(0, len(absr) - blk + 1, blk):
        sel = pulses[(pulses >= lo) & (pulses < lo + blk - hi_ms)]
        if len(sel) < MIN_PULSE_PER_BLOCK:
            continue
        art = float(np.mean([absr[s:s + ART_HI].max() for s in sel]))
        mw = float(np.mean([absr[s + lo_ms:s + hi_ms].mean() for s in sel]))
        rows.append({"t_s": (lo + blk / 2) / FS, "art": art, "mw": mw,
                     "R": mw / art if art > 0 else np.nan, "n": len(sel)})
    return pd.DataFrame(rows)


# ---------------------------------------------------------------- 판정
def verdict(gate_msg: str, ta: dict, tR: dict) -> str:
    """대조군이 평평한지 먼저, 그 다음에만 R 을 해석한다."""
    if gate_msg:
        return f"분석불가 — {gate_msg}"
    if np.isnan(ta["rho"]) or np.isnan(tR["rho"]):
        return "분석불가 — 블록 부족"

    art_flat = abs(ta["rho"]) < ART_FLAT_RHO and abs(ta["q1q4"]) < ART_FLAT_PCT
    if not art_flat:
        return (f"R 해석보류 — 대조군 불안정 (art ρ={ta['rho']:+.2f}, "
                f"Q1→Q4 {ta['q1q4']:+.0f}%)")

    if tR["rho"] <= -RHO_GATE and tR["q1q4"] <= -PCT_GATE:
        return f"피로 후보 — 대조군 평평 + R {tR['q1q4']:+.0f}%"
    if tR["rho"] >= RHO_GATE and tR["q1q4"] >= PCT_GATE:
        return f"증강(potentiation) — R {tR['q1q4']:+.0f}%"
    return f"추세없음 — R {tR['q1q4']:+.0f}%"


def analyze(path: Path) -> dict:
    x, absr, dc, dropped, clip, v = load_raw(path)
    dur = len(absr) / FS
    bursts = find_bursts(absr)
    pulses = refine_pulses(x, find_pulses(absr))

    period = float(np.median(np.diff([a for a, _ in bursts]))) if len(bursts) > 1 else np.nan
    duty = sum(b - a for a, b in bursts) / len(absr) * 100 if bursts else 0.0
    # 버스트당 펄스 수 / 버스트 내 펄스율
    ppb, prate = np.nan, np.nan
    if bursts:
        cnt = [int(((pulses >= a) & (pulses < b)).sum()) for a, b in bursts]
        ppb = float(np.median(cnt))
        blen = float(np.median([b - a for a, b in bursts])) / FS
        prate = ppb / blen if blen > 0 else np.nan

    out = {
        "session": path.name.replace("raw_", "").replace(".csv", ""),
        "subject": path.parent.name.replace("subject_", "")[-4:],
        "dur_s": dur, "dc": dc, "dropped": dropped, "clip_pct": clip,
        "n_burst": len(bursts), "period_ms": period, "duty_pct": duty,
        "ppb": ppb, "prate_hz": prate, "n_pulse": len(pulses),
        "marker": load_markers(path),
        "lat_ms": np.nan, "mw_lo": np.nan, "mw_hi": np.nan,
        "sta_ratio": np.nan, "sign_cons": np.nan, "spike_clip": np.nan,
        "drop_bias": np.nan, "warn": "",
        "n_block": 0,
        "_dec": pd.DataFrame(),
    }

    # --- G1 자극구조 ---
    fails = []
    if len(bursts) < MIN_BURSTS:
        fails.append(f"버스트 {len(bursts)}개(<{MIN_BURSTS})")
    elif not (PERIOD_LO <= period <= PERIOD_HI):
        fails.append(f"주기 {period:.0f}ms")
    if not np.isnan(ppb) and not (PPB_LO <= ppb <= PPB_HI):
        fails.append(f"버스트당 펄스 {ppb:.0f}")
    if not np.isnan(prate) and not (PRATE_LO <= prate <= PRATE_HI):
        fails.append(f"펄스율 {prate:.1f}Hz")

    # G4: 스파이크(대조군)가 ADC 레일에 포화됐는가
    if len(pulses):
        railed = [(v[p:p + ART_HI] <= ADC_MIN).any() or (v[p:p + ART_HI] >= ADC_MAX).any()
                  for p in pulses if p + ART_HI <= len(v)]
        out["spike_clip"] = float(np.mean(railed) * 100) if railed else np.nan

    warns = []
    sta, seg, sel, sinfo = build_sta(x, pulses)
    if sinfo:
        out["sign_cons"] = sinfo["sign_major"]
        out["drop_bias"] = sinfo.get("drop_bias", np.nan)
        # 극성 다수파만 남길 때, 버린 소수파가 특정 구간에 몰렸으면 R 궤적이 편향된다.
        # 게이트 탈락은 아니지만(판정은 살린다) 반드시 표시한다 — 조용히 버리면 안 된다.
        if sinfo["n_kept"] < sinfo["n_all"]:
            frac = 1 - sinfo["n_kept"] / sinfo["n_all"]
            db = sinfo.get("drop_bias", 0.0)
            note = f"극성 소수파 {frac*100:.0f}% 버림"
            if abs(db) > 0.1:
                note += f" (초반편중 {db:+.0%} — R 시작점 편향)"
            warns.append(note)
    if sta is None:
        if sinfo and sinfo["sign_major"] < SIGN_MAJORITY_MIN:
            # 극성이 반반 = 이상성 펄스의 어느 상에 걸릴지가 시행마다 다름.
            # 다수파를 골라도 건질 게 없다.
            fails.append(f"극성 반반 {sinfo['sign_major']:.2f}(<{SIGN_MAJORITY_MIN})")
        elif sinfo and sinfo["n_kept"] < SIGN_KEEP_MIN:
            fails.append(f"다수파 시행 {sinfo['n_kept']}개(<{SIGN_KEEP_MIN})")
        else:
            fails.append("STA 시행 부족")
        win = {}
    else:
        win = measure_window(sta, seg)
        out.update({k: v for k, v in win.items() if k in
                    ("lat_ms", "mw_lo", "mw_hi", "sta_ratio")})
        if not win:
            fails.append("STA 정점 없음")
        else:
            if win["sta_ratio"] < STA_RATIO_GATE:                    # G2
                fails.append(f"STA 정렬 {win['sta_ratio']:.2f}(<{STA_RATIO_GATE})")
    if not np.isnan(out["spike_clip"]) and out["spike_clip"] > CLIP_GATE:   # G3
        fails.append(f"대조군 포화 {out['spike_clip']:.0f}%")

    out["gate"] = "; ".join(fails)
    out["gate_ok"] = not fails
    out["warn"] = "; ".join(warns)

    ta = dict(NO_TREND)
    tm = dict(NO_TREND)
    tR = dict(NO_TREND)
    if out["gate_ok"]:
        dec = decompose(absr, sel, win)
        out["n_block"] = len(dec)
        out["_dec"] = dec
        if len(dec) >= 8:
            t = dec["t_s"].to_numpy()
            ta = trend(t, dec["art"].to_numpy())
            tm = trend(t, dec["mw"].to_numpy())
            tR = trend(t, dec["R"].to_numpy())
        out["R_med"] = float(dec["R"].median()) if len(dec) else np.nan
    out.update({f"art_{k}": v for k, v in ta.items()})
    out.update({f"mw_{k}": v for k, v in tm.items()})
    out.update({f"R_{k}": v for k, v in tR.items()})
    out["verdict"] = verdict(out["gate"], ta, tR)
    return out


# ---------------------------------------------------------------- 출력
def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("raw", type=Path, nargs="*")
    ap.add_argument("--root", type=Path, default=Path.home() / "emgfes-data")
    ap.add_argument("--plot", action="store_true")
    args = ap.parse_args()

    files = args.raw or sorted(args.root.glob("**/raw_*.csv"))
    df = pd.DataFrame([analyze(f) for f in files]).sort_values("session")
    ok = df[df["gate_ok"]]
    bad = df[~df["gate_ok"]]

    print(f"raw 세션 {len(df)}개 — 게이트 통과 {len(ok)}개, 분석불가 {len(bad)}개\n")

    print("=== 1. 품질 게이트 (자극구조 · STA 정렬 · 대조군 포화) — 부호는 진단값 ===")
    print(f"{'세션':<16}{'대상':>5}{'길이':>7}{'DC':>6}{'클립':>6}{'버스트':>6}{'주기':>8}"
          f"{'펄스/B':>7}{'펄스율':>8}{'STA':>6}{'부호':>6}{'포화':>7}  게이트")
    for _, r in df.iterrows():
        per = f"{r['period_ms']:.0f}ms" if not np.isnan(r["period_ms"]) else "  —  "
        pr = f"{r['prate_hz']:.1f}Hz" if not np.isnan(r["prate_hz"]) else "  — "
        sr = f"{r['sta_ratio']:.2f}" if not np.isnan(r["sta_ratio"]) else "  — "
        sc = f"{r['sign_cons']:.2f}" if not np.isnan(r["sign_cons"]) else "  — "
        cp = f"{r['spike_clip']:.0f}%" if not np.isnan(r["spike_clip"]) else "  — "
        g = "통과" if r["gate_ok"] else r["gate"]
        print(f"{r['session']:<16}{r['subject']:>5}{r['dur_s']:>6.0f}s{r['dc']:>6.0f}"
              f"{r['clip_pct']:>5.2f}%{r['n_burst']:>6.0f}{per:>8}{r['ppb']:>7.0f}"
              f"{pr:>8}{sr:>6}{sc:>6}{cp:>7}  {g}")

    print("\n=== 2. 세션별 실측 창 (M-wave 잠복은 전극 거리 따라 변함) ===")
    print(f"{'세션':<16}{'잠복':>7}{'M-wave 창':>12}{'블록':>6}   마커")
    for _, r in ok.iterrows():
        print(f"{r['session']:<16}{r['lat_ms']:>6.0f}ms"
              f"{f'{r.mw_lo:.0f}~{r.mw_hi:.0f}ms':>12}{r['n_block']:>6.0f}   {r['marker']}")

    print("\n=== 3. 대조군(스파이크 0~1ms) 이 평평한가 — R 해석의 전제 ===")
    print(f"{'세션':<16}{'art ρ':>8}{'art %/min':>11}{'art Q1→Q4':>11}   평평?")
    for _, r in ok.iterrows():
        flat = (abs(r["art_rho"]) < ART_FLAT_RHO and abs(r["art_q1q4"]) < ART_FLAT_PCT)
        print(f"{r['session']:<16}{r['art_rho']:>+8.2f}{r['art_pct_min']:>+10.1f}%"
              f"{r['art_q1q4']:>+10.1f}%   {'예' if flat else '아니오'}")

    print("\n=== 4. R = M-wave ÷ 스파이크 (세션 내 변화율만; 절대값은 세션간 비교 불가) ===")
    print(f"{'세션':<16}{'R 중앙':>8}{'mw Q1→Q4':>10}{'R ρ':>7}{'R %/min':>9}"
          f"{'R Q1→Q4':>9}   판정")
    for _, r in ok.iterrows():
        vd = r["verdict"]
        if r.get("warn"):
            vd += f"  ⚠️ {r['warn']}"
        print(f"{r['session']:<16}{r['R_med']:>8.3f}{r['mw_q1q4']:>+9.1f}%"
              f"{r['R_rho']:>+7.2f}{r['R_pct_min']:>+8.1f}%{r['R_q1q4']:>+8.1f}%   {vd}")

    if len(bad):
        print("\n=== 분석불가 세션 (피로 여부를 말하지 않음) ===")
        for _, r in bad.iterrows():
            print(f"  {r['session']}  {r['gate']}")

    out = Path(__file__).parent / "raw_full_analysis.csv"
    df.drop(columns=["_dec"]).to_csv(out, index=False)
    print(f"\n저장: {out}")

    if args.plot and len(ok):
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        n = len(ok)
        rows_ = (n + 2) // 3
        fig, axes = plt.subplots(rows_, 3, figsize=(15, 3 * rows_), squeeze=False)
        for ax, (_, r) in zip(axes.ravel(), ok.iterrows()):
            d = r["_dec"]
            ax2 = ax.twinx()
            ax.plot(d["t_s"], d["art"] / d["art"].iloc[0] * 100, ".-", ms=3, lw=0.8,
                    color="tab:gray", label="art (control) %")
            ax.plot(d["t_s"], d["mw"] / d["mw"].iloc[0] * 100, ".-", ms=3, lw=0.8,
                    color="tab:blue", label="mw %")
            ax2.plot(d["t_s"], d["R"], ".-", ms=3, lw=1.2, color="tab:red", label="R")
            ax.set_title(f"{r['session']}  lat={r['lat_ms']:.0f}ms  "
                         f"R {r['R_q1q4']:+.0f}%", fontsize=8)
            ax.set_xlabel("s")
            ax.set_ylabel("% of first block")
            ax2.set_ylabel("R", color="tab:red")
            ax.legend(fontsize=6, loc="lower left")
        for ax in axes.ravel()[n:]:
            ax.axis("off")
        fig.tight_layout()
        p = Path(__file__).parent / "raw_full_analysis.png"
        fig.savefig(p, dpi=110)
        print(f"저장: {p}")


if __name__ == "__main__":
    main()
