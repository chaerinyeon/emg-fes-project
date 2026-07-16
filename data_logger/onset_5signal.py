#!/usr/bin/env python3
"""
onset_5signal.py — 5개 신호(RMS·MDF·M-wave 진폭·면적·잠복기)의 SPC 온셋궤적.

각 신호를 baseline z-score로 바꿔(피로를 +방향), 해당 스트림의 온셋(t=0)에
정렬해 겹친 뒤 평균±사분위 밴드로 그린다.
  - RMS·MDF : baseline=초반 30초, 자발 SPC 온셋(RMS>UCL AND MDF<LCL)에 정렬
  - M-wave  : baseline=증강 정점 플래토, M-wave SPC 온셋에 정렬
z 방향: RMS·잠복기 = 상승이 피로(+), MDF·진폭·면적 = 하강이 피로(+)

사용: python3 onset_5signal.py
"""
from __future__ import annotations
import glob
from pathlib import Path
import numpy as np
import pandas as pd
import fatigue_2sigma as f2

ROOT = Path(__file__).resolve().parent.parent
GRID = np.arange(-40, 5.1, 1.0)     # 온셋 −40~+5초, 1초 격자
BASE_S = 30.0


def aligned(t, z, onset):
    if onset is None:
        return None
    rel = np.asarray(t) - onset
    m = np.isfinite(z) & (rel >= GRID[0] - 1) & (rel <= GRID[-1] + 1)
    if m.sum() < 4:
        return None
    return np.interp(GRID, rel[m], np.asarray(z)[m], left=np.nan, right=np.nan)


def zbase(series, mask, invert=False):
    """mask 구간을 baseline 으로 z. invert=True 면 (μ−x)/σ (감소가 +)."""
    b = series[mask].dropna()
    if len(b) < 5:
        return None
    mu, sd = b.mean(), b.std()
    # σ 하한(평균의 5%): 플래토가 거의 평평하면 σ≈0 → z 폭발. saturation 보정과 동일 취지.
    sd = max(sd if sd and sd > 0 else 0.0, 0.05 * abs(mu))
    if sd <= 0:
        return None
    z = (mu - series) / sd if invert else (series - mu) / sd
    return z.to_numpy()


def main():
    files = sorted(glob.glob(str(ROOT / "data_from_iphone/1차/env_*.csv")) +
                   glob.glob(str(ROOT / "data_from_iphone/2차/*.csv")))
    # 신호별 정렬 궤적 누적
    stacks = {k: [] for k in ["RMS", "MDF", "MW_Amp", "MW_Area", "MW_Latency"]}
    for fp in files:
        p = Path(fp)
        try:
            win, st = f2.process(p)
        except Exception:
            continue
        df = f2.load(p)
        tt = df["t_s"]

        # --- 자발: baseline 초반 30초, 자발 온셋 ---
        vol_on = st.get("onset_t")
        if vol_on is not None:
            base = tt <= BASE_S
            rz = zbase(df["RMS"], base, invert=False)   # 상승=피로
            mz = zbase(df["MDF"], base, invert=True)    # 하강=피로
            if rz is not None:
                a = aligned(tt, rz, vol_on);  stacks["RMS"].append(a) if a is not None else None
            if mz is not None:
                a = aligned(tt, mz, vol_on);  stacks["MDF"].append(a) if a is not None else None

        # --- M-wave: baseline=증강 플래토, M-wave 온셋 ---
        if st.get("mw_ok") and st.get("mw_onset_t") is not None and "mw_plateau" in win:
            pl = win[win["mw_plateau"]]
            if len(pl):
                p0, p1 = pl["t_center"].min(), pl["t_center"].max()
                platmask = (tt >= p0) & (tt <= p1)
                mw_on = st["mw_onset_t"]
                for col, inv in [("MW_Amp", True), ("MW_Area", True), ("MW_Latency", False)]:
                    if col in df.columns:
                        z = zbase(df[col], platmask, invert=inv)   # 진폭·면적 하강=+, 잠복 상승=+
                        if z is not None:
                            a = aligned(tt, z, mw_on)
                            if a is not None:
                                stacks[col].append(a)

    # --- 플롯 ---
    import matplotlib.pyplot as plt
    plt.rcParams["font.family"] = "AppleGothic"; plt.rcParams["axes.unicode_minus"] = False
    panels = [("RMS", "자발 · RMS (상승=피로)", "C0"),
              ("MDF", "자발 · MDF (하강=피로)", "C2"),
              ("MW_Amp", "M-wave 진폭 (하강=피로)", "C0"),
              ("MW_Area", "M-wave 면적 (하강=피로)", "C1"),
              ("MW_Latency", "M-wave 잠복기 (상승=피로)", "C3")]
    fig, axes = plt.subplots(2, 3, figsize=(16, 8.5))
    axl = axes.flatten()
    for ax, (key, title, c) in zip(axl, panels):
        arr = [a for a in stacks[key] if a is not None]
        if arr:
            A = np.vstack(arr)
            with np.errstate(all="ignore"):
                mean = np.nanmean(A, axis=0); q1 = np.nanpercentile(A, 25, axis=0); q3 = np.nanpercentile(A, 75, axis=0)
            for row in A:
                ax.plot(GRID, row, color=c, alpha=0.12, lw=0.7)
            ax.plot(GRID, mean, color=c, lw=2.6, label=f"평균 (n={len(A)})")
            ax.fill_between(GRID, q1, q3, color=c, alpha=0.18, label="25~75%")
        ax.axhline(2, ls="--", color="red", alpha=.8, label="2σ (SPC 온셋)")
        ax.axhline(1, ls=":", color="gray"); ax.axhline(0, color="black", lw=.4)
        ax.axvline(0, color="black", lw=.8)
        ax.set_ylim(-4, 8)   # 모든 신호 동일 축(2σ 기준 비교)
        ax.set_title(title, fontsize=11); ax.set_xlabel("온셋 기준 시간(초)")
        ax.set_ylabel("피로방향 z"); ax.legend(loc="upper left", fontsize=8); ax.grid(alpha=.25)
    # 6번째 칸: 설명
    ax6 = axl[5]
    ax6.axis("off")
    ax6.text(0.02, 0.95, "정렬 기준\n"
             "• RMS·MDF → 자발 SPC 온셋\n   (baseline=초반 30초)\n"
             "• M-wave 3개 → M-wave 온셋\n   (baseline=증강 정점 플래토)\n\n"
             "서서히 오르면(램프)=예측 가능\n갑자기=절벽\n\n"
             "M-wave도 z로 계산 (플래토 기준)",
             fontsize=10, va="top", transform=ax6.transAxes)
    fig.suptitle("5개 신호 SPC 온셋궤적 — 각 신호 z-score, 온셋(t=0)에 정렬", fontsize=13)
    fig.tight_layout()
    out = ROOT / "data_from_iphone" / "onset_5signal.png"
    fig.savefig(out, dpi=120)
    print(f"그래프 저장 → {out}")
    for key, title, _ in panels:
        n = len([a for a in stacks[key] if a is not None])
        print(f"  {title}: {n}세션")


if __name__ == "__main__":
    main()
