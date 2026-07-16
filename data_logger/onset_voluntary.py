#!/usr/bin/env python3
"""
onset_voluntary.py — RMS·MDF 자발 온셋궤적. M-wave 없는 구형 logger 데이터까지 합쳐 n 확대.

onset_5signal.py 의 자발 패널(RMS·MDF)은 M-wave 포맷 iPhone 세션(자발 온셋 7개)만 썼다.
여기선 'RMS·MDF만 있는' 구형 logger 포맷(timestamp_ms,rms,mdf..., ~1Hz)도 어댑터로 읽어
자발 온셋궤적에 추가한다.  출처(iPhone 10Hz vs logger 1Hz)를 색으로 구분해 함께 그린다.

z: baseline=초반 30초.  RMS_z=(RMS−μ)/σ (상승=피로),  MDF_z=(μ−MDF)/σ (하강=피로)

사용: python3 onset_voluntary.py
"""
from __future__ import annotations
import glob
from pathlib import Path
import numpy as np
import pandas as pd
import fatigue_2sigma as f2

ROOT = Path(__file__).resolve().parent.parent
GRID = np.arange(-40, 5.1, 1.0)
BASE_S = 30.0


def load_logger(path: Path):
    """구형 logger CSV(timestamp_ms,rms,mdf) → f2 호환 df(Time(ms),RMS,MDF,t_s)."""
    df = pd.read_csv(path)
    if not {"timestamp_ms", "rms", "mdf"}.issubset(df.columns):
        return None
    out = pd.DataFrame()
    out["Time(ms)"] = pd.to_numeric(df["timestamp_ms"], errors="coerce")
    out["RMS"] = pd.to_numeric(df["rms"], errors="coerce")
    out["MDF"] = pd.to_numeric(df["mdf"], errors="coerce")
    out = out.dropna(subset=["Time(ms)", "RMS", "MDF"])
    if len(out) < 40:
        return None
    out["t_s"] = (out["Time(ms)"] - out["Time(ms)"].iloc[0]) / 1000.0
    out = out[(out["RMS"] > 0) & (out["MDF"] > 0)].reset_index(drop=True)
    return out if len(out) >= 40 else None


def aligned(t, z, onset):
    if onset is None:
        return None
    rel = np.asarray(t) - onset
    m = np.isfinite(z) & (rel >= GRID[0] - 1) & (rel <= GRID[-1] + 1)
    if m.sum() < 4:
        return None
    return np.interp(GRID, rel[m], np.asarray(z)[m], left=np.nan, right=np.nan)


def zbase(series, mask, invert=False):
    b = series[mask].dropna()
    if len(b) < 5:
        return None
    mu, sd = b.mean(), b.std()
    sd = max(sd if sd and sd > 0 else 0.0, 0.05 * abs(mu))
    if sd <= 0:
        return None
    z = (mu - series) / sd if invert else (series - mu) / sd
    return z.to_numpy()


def collect(df, onset, stacks, tag):
    tt = df["t_s"]; base = tt <= BASE_S
    rz = zbase(df["RMS"], base, invert=False)
    mz = zbase(df["MDF"], base, invert=True)
    if rz is not None:
        a = aligned(tt, rz, onset)
        if a is not None:
            stacks["RMS"][tag].append(a)
    if mz is not None:
        a = aligned(tt, mz, onset)
        if a is not None:
            stacks["MDF"][tag].append(a)


def main():
    stacks = {"RMS": {"iphone": [], "logger": []},
              "MDF": {"iphone": [], "logger": []}}

    # --- iPhone (M-wave 포맷) ---
    for fp in sorted(glob.glob(str(ROOT / "data_from_iphone/1차/env_*.csv")) +
                     glob.glob(str(ROOT / "data_from_iphone/2차/*.csv"))):
        try:
            win, st = f2.process(Path(fp))
        except Exception:
            continue
        onset = st.get("onset_t")
        if onset is not None:
            collect(f2.load(Path(fp)), onset, stacks, "iphone")

    # --- logger (RMS/MDF만) ---
    logger_files = (glob.glob(str(ROOT / "data/subject_A/*.csv")) +
                    glob.glob(str(ROOT / "data/subject_B/*.csv")) +
                    glob.glob(str(ROOT / "data/subject_C/*.csv")) +
                    glob.glob(str(ROOT / "data_logger/data/*.csv")) +
                    glob.glob(str(ROOT / "data_from_iphone/1차/emg_*.csv")))
    n_logger_ok = 0
    for fp in sorted(logger_files):
        df = load_logger(Path(fp))
        if df is None:
            continue
        dt = np.median(np.diff(df["Time(ms)"].to_numpy())) / 1000.0
        if dt <= 0:
            dt = 1.0
        try:
            win = f2.window_reduce(df, dt)
            st = f2.analyze(win)
        except Exception:
            continue
        onset = st.get("onset_t")
        if onset is not None:
            n_logger_ok += 1
            collect(df, onset, stacks, "logger")

    # --- 리포트 ---
    for k in ("RMS", "MDF"):
        ni = len(stacks[k]["iphone"]); nl = len(stacks[k]["logger"])
        print(f"{k}: iPhone {ni} + logger {nl} = {ni+nl} 세션")

    # --- 플롯 ---
    import matplotlib.pyplot as plt
    plt.rcParams["font.family"] = "AppleGothic"; plt.rcParams["axes.unicode_minus"] = False
    fig, axes = plt.subplots(1, 2, figsize=(14, 6))
    titles = {"RMS": "자발 · RMS (상승=피로)", "MDF": "자발 · MDF (하강=피로)"}
    for ax, key in zip(axes, ["RMS", "MDF"]):
        allrows = []
        for tag, col in [("iphone", "C0"), ("logger", "C1")]:
            rows = [a for a in stacks[key][tag] if a is not None]
            allrows += rows
            for row in rows:
                ax.plot(GRID, row, color=col, alpha=0.10, lw=0.7)
            if rows:
                with np.errstate(all="ignore"):
                    mean = np.nanmean(np.vstack(rows), axis=0)
                lbl = "iPhone 10Hz" if tag == "iphone" else "logger 1Hz"
                ax.plot(GRID, mean, color=col, lw=2.4, label=f"{lbl} 평균 (n={len(rows)})")
        if allrows:
            with np.errstate(all="ignore"):
                cmean = np.nanmean(np.vstack(allrows), axis=0)
            ax.plot(GRID, cmean, color="black", lw=2.8, ls=(0, (4, 2)),
                    label=f"합친 평균 (n={len(allrows)})")
        ax.axhline(2, ls="--", color="red", alpha=.8, label="2σ (SPC 온셋)")
        ax.axhline(1, ls=":", color="gray"); ax.axhline(0, color="black", lw=.4)
        ax.axvline(0, color="black", lw=.8); ax.set_ylim(-4, 8)
        ax.set_title(titles[key], fontsize=12); ax.set_xlabel("온셋 기준 시간(초)")
        ax.set_ylabel("피로방향 z"); ax.legend(loc="upper left", fontsize=8); ax.grid(alpha=.25)
    fig.suptitle("자발(RMS·MDF) 온셋궤적 — M-wave 없는 logger 데이터 추가", fontsize=13)
    fig.tight_layout()
    out = ROOT / "data_from_iphone" / "onset_voluntary.png"
    fig.savefig(out, dpi=120); print(f"\n그래프 저장 → {out}  (logger 온셋 세션 {n_logger_ok}개)")


if __name__ == "__main__":
    main()
