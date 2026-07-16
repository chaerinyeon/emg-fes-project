#!/usr/bin/env python3
"""
spc_individual.py — 한 세션에서 5개 신호를 '각자 자기 2σ 관리한계'로 개별 표시.
AND 조합 없이 신호 하나하나가 언제 자기 한계를 넘는지(=각자의 온셋) 본다.

각 신호 방향(관리한계):
  RMS↑=UCL, MDF↓=LCL, M-wave 진폭↓=LCL, 면적↓=LCL, 잠복기↑=UCL
baseline: RMS·MDF=초반 30초, M-wave 3개=증강 정점 플래토
읽기 편하게 1.5초(자극주기) 평활 후 표시.

사용: python3 spc_individual.py [세션이름조각]   (기본: 20260614_010038)
"""
from __future__ import annotations
import sys, glob, re
from pathlib import Path
import numpy as np
import pandas as pd
import fatigue_2sigma as f2

ROOT = Path(__file__).resolve().parent.parent
SIGMA = 2.0
SMOOTH_S = 1.5


def smooth(s, dt):
    n = max(1, round(SMOOTH_S / (dt if dt > 0 else 0.1)))
    return s.rolling(n, center=True, min_periods=max(1, n // 2)).mean()


def find_file(frag):
    for fp in glob.glob(str(ROOT / "data_from_iphone/1차/env_*.csv")) + \
              glob.glob(str(ROOT / "data_from_iphone/2차/*.csv")):
        if frag in fp:
            return Path(fp)
    return None


def main():
    frag = sys.argv[1] if len(sys.argv) > 1 else "20260614_010038"
    path = find_file(frag)
    if path is None:
        print(f"세션 못 찾음: {frag}"); return
    win, st = f2.process(path)
    df = f2.load(path); dt = f2.infer_dt(df); t = df["t_s"].to_numpy()

    # M-wave baseline = 플래토 시간범위
    platmask = None
    if st.get("mw_ok") and "mw_plateau" in win:
        pl = win[win["mw_plateau"]]
        if len(pl):
            platmask = (t >= pl["t_center"].min()) & (t <= pl["t_center"].max())

    # (컬럼, 표시명, 방향'up'/'down', baseline mask)
    base30 = t <= 30
    sigs = [("RMS", "RMS", "up", base30),
            ("MDF", "MDF (Hz)", "down", base30),
            ("MW_Amp", "M-wave 진폭", "down", platmask),
            ("MW_Area", "M-wave 면적", "down", platmask),
            ("MW_Latency", "M-wave 잠복기 (ms)", "up", platmask)]

    import matplotlib.pyplot as plt
    plt.rcParams["font.family"] = "AppleGothic"; plt.rcParams["axes.unicode_minus"] = False
    fig, axes = plt.subplots(5, 1, figsize=(13, 13), sharex=True)
    for ax, (col, name, direction, bmask) in zip(axes, sigs):
        if col not in df.columns or bmask is None:
            ax.text(0.5, 0.5, f"{name}: baseline 없음", transform=ax.transAxes, ha="center")
            ax.set_ylabel(name, fontsize=9); continue
        sig = smooth(df[col].astype(float), dt)
        v = sig.to_numpy()
        b = sig[bmask].dropna()
        if len(b) < 5:
            ax.text(0.5, 0.5, f"{name}: baseline 부족", transform=ax.transAxes, ha="center")
            ax.set_ylabel(name, fontsize=9); continue
        mu, sd = b.mean(), b.std()
        sd = max(sd if sd > 0 else 0.0, 0.05 * abs(mu))
        if direction == "up":
            limit = mu + SIGMA * sd; beyond = v > limit; ltxt = f"UCL(+2σ)={limit:.0f}"
        else:
            limit = mu - SIGMA * sd; beyond = v < limit; ltxt = f"LCL(−2σ)={limit:.0f}"

        ax.plot(t, v, color="C0", lw=1.4)
        ax.axhline(mu, ls=":", color="gray", alpha=.7, label=f"baseline={mu:.0f}")
        ax.axhline(limit, ls="--", color="red", label=ltxt)
        # 한계 이탈 구간 음영
        ax.fill_between(t, ax.get_ylim()[0], ax.get_ylim()[1], where=np.nan_to_num(beyond),
                        color="red", alpha=0.10)
        # baseline 구간 음영
        if direction and bmask is base30:
            ax.axvspan(0, 30, color="gray", alpha=0.06)
        # 첫 지속 이탈(2개 연속) = 개별 온셋. 단 baseline 구간 이후만(그 안 크로싱은 노이즈).
        elig_after = 30.0 if bmask is base30 else float(t[bmask].max())
        onset_t = None
        run = 0
        for i, x in enumerate(beyond):
            if t[i] <= elig_after:
                run = 0; continue
            run = run + 1 if x else 0
            if run >= 2:
                onset_t = t[i - 1]; break
        if onset_t is not None:
            ax.axvline(onset_t, color="purple", lw=1.4)
            ax.text(onset_t, ax.get_ylim()[1], f" 이탈 {onset_t:.0f}s",
                    color="purple", fontsize=8, va="top")
        ax.set_ylabel(name, fontsize=9); ax.legend(loc="upper right", fontsize=7)
        ax.grid(alpha=.2)
    axes[-1].set_xlabel("time (s)")
    fig.suptitle(f"{re.search(r'(env_[0-9_]+)', path.name).group(1)} — 5개 신호 개별 2σ SPC "
                 f"(AND 없이 각자 이탈 시점)", fontsize=13)
    fig.tight_layout()
    out = ROOT / "data_from_iphone" / "spc_individual.png"
    fig.savefig(out, dpi=120); print(f"그래프 저장 → {out}")


if __name__ == "__main__":
    main()
