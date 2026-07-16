#!/usr/bin/env python3
"""
onset_trajectory.py — SPC 2σ 온셋 '이전' 궤적 분석 (딥러닝 정당화 go/no-go)

질문: 피로(SPC 2σ 이탈)가 오기 전에 신호가 '서서히' 올라오나(예측 가능),
      아니면 '갑자기' 튀나(예측 불가)?
  - 서서히 램프 → LSTM 조기예측 정당함 (미리 읽을 runway 있음)
  - 절벽처럼 점프 → 미리 읽을 게 없어 LSTM 무의미

두 스트림 각각 분석:
  - 자발(voluntary): vol_z = min(RMS_z, MDF_z)  [AND 규칙 → 둘 다 넘어야 하므로 min이 결정]
  - 유발(M-wave)  : mw_z  = (플래토평균 − MW_Area) / σ_eff  [감소가 피로]

방법: 각 세션의 온셋(z가 2σ 지속 이탈)을 t=0에 정렬 → 이전 45초 z 궤적을
      공통 격자에 보간해 겹침 → 평균±사분위 밴드. 1σ를 넘는 시점과 2σ 넘는
      시점의 간격(lead)로 'runway'를 정량화.

사용: python3 onset_trajectory.py --plot
"""
from __future__ import annotations
import argparse, glob, re
from pathlib import Path
import numpy as np
import pandas as pd
import fatigue_2sigma as f2

ROOT = Path(__file__).resolve().parent.parent
GRID = np.arange(-45, 6, 3.0)        # 온셋 기준 -45~+3초, 3초 간격
CROSS_LO, CROSS_HI = 1.0, 2.0         # 1σ→2σ 도달 간격을 runway로


def stream_z(win: pd.DataFrame, st: dict):
    """두 스트림의 (z 시계열, 온셋시각) 반환. 온셋 없으면 None."""
    t = win["t_center"].to_numpy()
    # 자발: min(rms_z, mdf_z) — 둘 다 2 넘어야 SPC 발동이므로 작은 쪽이 결정적
    vol_z = np.minimum(win["rms_z"].to_numpy(), win["mdf_z"].to_numpy())
    vol_onset = st.get("onset_t")
    # 유발: (플래토평균 − area)/σ_eff, 감소가 +z
    mw_z, mw_onset = None, None
    if st.get("mw_ok"):
        area = win["mw_area"].to_numpy(dtype=float)
        sd_eff = max(st["mw_ref_sd"], 0.05 * st["mw_ref_mu"])
        mw_z = (st["mw_ref_mu"] - area) / sd_eff if sd_eff > 0 else np.zeros_like(area)
        # 플래토 이전(증강 램프)은 area가 낮아 '가짜 +z'가 나오므로 제외.
        mw_z = np.where(t >= st["mw_plateau_end_t"], mw_z, np.nan)
        mw_onset = st.get("mw_onset_t")
    return t, vol_z, vol_onset, mw_z, mw_onset


def lead_time(t, z, onset):
    """온셋에서 뒤로 걸으며 z가 '연속으로' 1σ 이상이던 구간 길이(초).
    순간적 초반 blip이 아니라 온셋 직전의 '지속된 접근'만 runway로 센다.
    작으면 절벽(직전까지 조용), 크면 램프(오래 전부터 서서히 상승)."""
    if onset is None:
        return None
    pre = t <= onset + 1e-9
    if pre.sum() < 2:
        return None
    tt, zz = t[pre], z[pre]
    i = len(tt) - 1                       # 온셋 window
    while i - 1 >= 0 and np.isfinite(zz[i - 1]) and zz[i - 1] >= CROSS_LO:
        i -= 1
    return float(onset - tt[i])


def aligned(t, z, onset):
    """온셋을 0으로 옮겨 공통 격자에 보간한 z 궤적 (없으면 None)."""
    if onset is None:
        return None
    rel = t - onset
    m = (rel >= GRID[0] - 3) & (rel <= GRID[-1] + 3)
    if m.sum() < 3:
        return None
    return np.interp(GRID, rel[m], z[m], left=np.nan, right=np.nan)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--plot", action="store_true")
    args = ap.parse_args()

    files = sorted(glob.glob(str(ROOT / "data_from_iphone/1차/env_*.csv")) +
                   glob.glob(str(ROOT / "data_from_iphone/2차/*.csv")))
    vol_stack, mw_stack, vol_leads, mw_leads = [], [], [], []
    n_vol, n_mw = 0, 0
    for fp in files:
        p = Path(fp)
        try:
            win, st = f2.process(p)
        except Exception:
            continue
        t, vol_z, vol_on, mw_z, mw_on = stream_z(win, st)
        if vol_on is not None:
            n_vol += 1
            a = aligned(t, vol_z, vol_on)
            if a is not None: vol_stack.append(a)
            lt = lead_time(t, vol_z, vol_on)
            if lt is not None: vol_leads.append(lt)
        if mw_z is not None and mw_on is not None:
            n_mw += 1
            a = aligned(t, mw_z, mw_on)
            if a is not None: mw_stack.append(a)
            lt = lead_time(t, mw_z, mw_on)
            if lt is not None: mw_leads.append(lt)

    def summarize(name, stack, leads, n):
        print(f"\n=== {name} 스트림 ===")
        print(f"  온셋 있는 세션: {n}개, 궤적 정렬 가능: {len(stack)}개")
        if leads:
            L = np.array(leads)
            print(f"  1σ→2σ lead(runway): 중앙값 {np.median(L):.0f}초  "
                  f"(25~75%: {np.percentile(L,25):.0f}~{np.percentile(L,75):.0f}초)")
            grad = (L >= 9).mean() * 100    # 3window(9초) 이상 runway = 램프
            cliff = (L <= 3).mean() * 100
            print(f"  램프형(runway≥9초): {grad:.0f}%   절벽형(≤3초): {cliff:.0f}%")
        if stack:
            arr = np.vstack(stack)
            with np.errstate(all="ignore"):
                mean = np.nanmean(arr, axis=0)
            print("  온셋 이전 평균 z (−30→0초):")
            for tt in [-30, -21, -12, -6, -3, 0]:
                idx = np.argmin(np.abs(GRID - tt))
                v = mean[idx]
                print(f"    {tt:+3d}초: z={v:.2f}" if np.isfinite(v) else f"    {tt:+3d}초: -")
        return np.vstack(stack) if stack else None

    vol_arr = summarize("자발 (RMS·MDF)", vol_stack, vol_leads, n_vol)
    mw_arr = summarize("유발 (M-wave)", mw_stack, mw_leads, n_mw)

    if args.plot:
        import matplotlib.pyplot as plt
        plt.rcParams["font.family"] = "AppleGothic"; plt.rcParams["axes.unicode_minus"] = False
        fig, ax = plt.subplots(1, 2, figsize=(13, 5), sharey=True)
        for a, arr, title, c in [(ax[0], vol_arr, "자발 (RMS·MDF)  vol_z=min(RMS_z,MDF_z)", "C0"),
                                 (ax[1], mw_arr, "유발 (M-wave)  mw_z=플래토대비 감소", "C1")]:
            if arr is not None:
                with np.errstate(all="ignore"):
                    mean = np.nanmean(arr, axis=0); q1 = np.nanpercentile(arr, 25, axis=0); q3 = np.nanpercentile(arr, 75, axis=0)
                for row in arr:
                    a.plot(GRID, row, color=c, alpha=0.12, lw=0.8)
                a.plot(GRID, mean, color=c, lw=2.5, label=f"평균 (n={len(arr)})")
                a.fill_between(GRID, q1, q3, color=c, alpha=0.18, label="25~75%")
            a.axhline(2, ls="--", color="red", label="2σ (SPC 발동=온셋)")
            a.axhline(1, ls=":", color="gray", label="1σ")
            a.axvline(0, color="black", lw=0.8)
            a.set_xlabel("온셋 기준 시간 (초, 0=SPC 발동)"); a.set_title(title, fontsize=11)
            a.legend(loc="upper left", fontsize=8); a.grid(alpha=0.25)
        ax[0].set_ylabel("피로방향 z-score")
        fig.suptitle("SPC 온셋 이전 궤적 — 서서히 오르면(램프) LSTM 예측 정당, 절벽이면 무의미", fontsize=12)
        fig.tight_layout()
        out = ROOT / "data_from_iphone" / "onset_trajectory.png"
        fig.savefig(out, dpi=120); print(f"\n그래프 저장 → {out}")


if __name__ == "__main__":
    main()
