#!/usr/bin/env python3
"""
onset_fine.py — 자발(RMS·MDF) 스트림 온셋 직전을 10Hz 원해상도로 확대.

onset_trajectory.py 는 3초 window라 마지막 3초가 뭉개진다. 여기선 env CSV의
100ms(10Hz) RMS/MDF 원값으로 온셋 −20~+3초를 0.5초 격자로 확대해:
  - 마지막 급점프가 '진짜 순간 절벽'인지 '예측 가능한 빠른 램프'인지 확인
  - RMS·MDF 각각의 사전 신호를 분리해서 봄 (하나가 먼저 움직이나?)

baseline = 세션 초반 30초(10Hz 표본)의 평균·σ. z는 피로방향을 +로:
  RMS_z=(RMS−μ)/σ (상승),  MDF_z=(μ−MDF)/σ (하강),  vol_z=min(둘)
온셋 시각은 fatigue_2sigma 의 RMS/MDF 2σ 판정(3초)에서 그대로 가져온다.

사용: python3 onset_fine.py --plot
"""
from __future__ import annotations
import argparse, glob, re
from pathlib import Path
import numpy as np
import pandas as pd
import fatigue_2sigma as f2

ROOT = Path(__file__).resolve().parent.parent
GRID = np.arange(-20, 3.01, 0.5)      # 온셋 기준 −20~+3초, 0.5초 격자
BASE_S = 30.0


def fine_z(path: Path, onset: float):
    """10Hz RMS/MDF 를 baseline z 로 변환, 온셋 기준 격자에 보간. (rms_z,mdf_z,vol_z) or None."""
    df = f2.load(path)
    base = df[df["t_s"] <= BASE_S]
    if len(base) < 10:
        return None
    rmu, rsd = base["RMS"].mean(), base["RMS"].std()
    mmu, msd = base["MDF"].mean(), base["MDF"].std()
    if rsd <= 0 or msd <= 0:
        return None
    rms_z = ((df["RMS"] - rmu) / rsd).to_numpy()
    mdf_z = ((mmu - df["MDF"]) / msd).to_numpy()
    vol_z = np.minimum(rms_z, mdf_z)
    rel = df["t_s"].to_numpy() - onset
    m = (rel >= GRID[0] - 1) & (rel <= GRID[-1] + 1)
    if m.sum() < 5:
        return None
    def itp(z):
        return np.interp(GRID, rel[m], z[m], left=np.nan, right=np.nan)
    return itp(rms_z), itp(mdf_z), itp(vol_z)


def sustained_lead(vol_row):
    """격자에서 온셋(t=0) 직전, vol_z 가 연속으로 1σ 이상이던 구간 길이(초)."""
    i0 = int(np.argmin(np.abs(GRID - 0.0)))
    i = i0
    while i - 1 >= 0 and np.isfinite(vol_row[i - 1]) and vol_row[i - 1] >= 1.0:
        i -= 1
    return GRID[i0] - GRID[i]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--plot", action="store_true")
    args = ap.parse_args()
    files = sorted(glob.glob(str(ROOT / "data_from_iphone/1차/env_*.csv")) +
                   glob.glob(str(ROOT / "data_from_iphone/2차/*.csv")))
    rows_r, rows_m, rows_v, leads = [], [], [], []
    for fp in files:
        p = Path(fp)
        try:
            win, st = f2.process(p)
        except Exception:
            continue
        onset = st.get("onset_t")
        if onset is None:
            continue
        r = fine_z(p, onset)
        if r is None:
            continue
        rz, mz, vz = r
        rows_r.append(rz); rows_m.append(mz); rows_v.append(vz)
        leads.append(sustained_lead(vz))

    n = len(rows_v)
    print(f"\n자발 온셋 세션(10Hz 확대): {n}개")
    if n == 0:
        return
    R = np.vstack(rows_r); M = np.vstack(rows_m); V = np.vstack(rows_v)
    with np.errstate(all="ignore"):
        vmean = np.nanmean(V, axis=0)
        rmean = np.nanmean(R, axis=0)
        mmean = np.nanmean(M, axis=0)
    L = np.array(leads)
    print(f"지속 runway(연속 1σ): 중앙값 {np.median(L):.1f}초 (25~75%: "
          f"{np.percentile(L,25):.1f}~{np.percentile(L,75):.1f})")
    print("온셋 이전 평균 z (0.5초 해상도):")
    for tt in [-10, -5, -3, -2, -1.5, -1, -0.5, 0]:
        i = int(np.argmin(np.abs(GRID - tt)))
        print(f"  {tt:+4.1f}초: vol_z={vmean[i]:+.2f}  (RMS_z={rmean[i]:+.2f}, MDF_z={mmean[i]:+.2f})")

    # 예측 가능성 요약: 각 lead 에서 이미 경고선 넘었나
    print("\n조기경보 가능성 (온셋 L초 전 vol_z가 이미 임계 이상인 세션 비율):")
    for lead in [1.0, 2.0, 3.0, 5.0]:
        i = int(np.argmin(np.abs(GRID - (-lead))))
        for thr in [1.0, 1.5]:
            frac = np.nanmean(V[:, i] >= thr) * 100
            print(f"  −{lead:.0f}초에 vol_z≥{thr}: {frac:.0f}%", end="   ")
        print()

    if args.plot:
        import matplotlib.pyplot as plt
        plt.rcParams["font.family"] = "AppleGothic"; plt.rcParams["axes.unicode_minus"] = False
        fig, ax = plt.subplots(figsize=(11, 6))
        for row in V:
            ax.plot(GRID, row, color="C0", alpha=0.15, lw=0.8)
        with np.errstate(all="ignore"):
            q1 = np.nanpercentile(V, 25, axis=0); q3 = np.nanpercentile(V, 75, axis=0)
        ax.plot(GRID, vmean, color="C0", lw=2.6, label=f"vol_z 평균 (n={n})")
        ax.fill_between(GRID, q1, q3, color="C0", alpha=0.18, label="25~75%")
        ax.plot(GRID, rmean, color="C2", lw=1.6, ls="--", label="RMS_z 평균")
        ax.plot(GRID, mmean, color="C3", lw=1.6, ls="--", label="MDF_z 평균")
        ax.axhline(2, ls="--", color="red", alpha=0.8, label="2σ (SPC 발동)")
        ax.axhline(1, ls=":", color="gray", label="1σ")
        ax.axvline(0, color="black", lw=0.8)
        ax.set_xlabel("온셋 기준 시간 (초, 0=SPC 발동)"); ax.set_ylabel("피로방향 z-score")
        ax.set_title("자발 스트림 온셋 직전 10Hz 확대 — 급점프가 예측가능한 램프인가?")
        ax.legend(loc="upper left", fontsize=9); ax.grid(alpha=0.25)
        fig.tight_layout()
        out = ROOT / "data_from_iphone" / "onset_fine.png"
        fig.savefig(out, dpi=120); print(f"\n그래프 저장 → {out}")


if __name__ == "__main__":
    main()
