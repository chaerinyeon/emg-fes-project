#!/usr/bin/env python3
"""
spc_multi.py — 5개 신호 각각의 '개별 2σ SPC'를 여러 세션에 걸쳐 본다.

각 신호가 '혼자서(AND 없이) 자기 2σ 한계를 넘은' 세션을 모아, 그 신호의 z궤적을
자기 온셋(t=0)에 정렬해 겹쳐 그린다. → 어떤 신호가 몇 세션에서 피로를 잡는지,
겹치는지(예: RMS만 잡힌 세션)를 한 눈에.

baseline: RMS·MDF=초반30초, M-wave 3개=증강 정점 플래토
방향(피로=+z): RMS·잠복기 상승, MDF·진폭·면적 하강.  온셋=z>2가 2연속(baseline 이후).
사용: python3 spc_multi.py
"""
from __future__ import annotations
import glob, re
from pathlib import Path
import numpy as np
import pandas as pd
import fatigue_2sigma as f2

ROOT = Path(__file__).resolve().parent.parent
GRID = np.arange(-40, 10.1, 1.0)
SMOOTH_S = 1.5
SUSTAIN_S = 5.0        # 이 시간 이상 연속으로 2σ 넘어야 온셋(순간 노이즈 스파이크 배제)
SIGS = [("RMS", "RMS", "up"), ("MDF", "MDF", "down"),
        ("MW_Amp", "M-wave 진폭", "down"), ("MW_Area", "M-wave 면적", "down"),
        ("MW_Latency", "M-wave 잠복기", "up")]


def smooth(s, dt):
    n = max(1, round(SMOOTH_S / (dt if dt > 0 else 0.1)))
    return s.rolling(n, center=True, min_periods=max(1, n // 2)).mean()


def fatigue_z(sig, bmask, direction):
    b = sig[bmask].dropna()
    if len(b) < 5:
        return None, None
    mu, sd = b.mean(), b.std()
    sd = max(sd if sd > 0 else 0.0, 0.05 * abs(mu))
    if sd <= 0:
        return None, None
    z = (sig - mu) / sd if direction == "up" else (mu - sig) / sd
    return z.to_numpy(), float(b.index.max())  # z, baseline 마지막 위치(미사용)


def find_onset(t, z, base_end, dt):
    need = max(2, round(SUSTAIN_S / (dt if dt > 0 else 0.1)))   # 5초 = 연속 표본 수
    run = 0
    for i in range(len(z)):
        if t[i] <= base_end:
            run = 0; continue
        run = run + 1 if (np.isfinite(z[i]) and z[i] > 2) else 0
        if run >= need:
            return t[i - need + 1]      # 지속 시작 시각
    return None


def main():
    files = sorted(glob.glob(str(ROOT / "data_from_iphone/1차/env_*.csv")) +
                   glob.glob(str(ROOT / "data_from_iphone/2차/*.csv")))
    stacks = {k[0]: [] for k in SIGS}          # 신호별 정렬 z궤적
    fired = {}                                  # 세션 -> 잡힌 신호 집합
    for fp in files:
        p = Path(fp)
        try:
            win, st = f2.process(p)
        except Exception:
            continue
        df = f2.load(p); dt = f2.infer_dt(df); t = df["t_s"].to_numpy()
        base30 = t <= 30
        plat = None
        if st.get("mw_ok") and "mw_plateau" in win:
            pl = win[win["mw_plateau"]]
            if len(pl):
                plat = (t >= pl["t_center"].min()) & (t <= pl["t_center"].max())
        name = re.search(r"(env_\d+_\d+)", p.name).group(1)
        for col, disp, direction in SIGS:
            if col not in df.columns:
                continue
            bmask = base30 if col in ("RMS", "MDF") else plat
            if bmask is None or bmask.sum() == 0:
                continue
            base_end = 30.0 if col in ("RMS", "MDF") else float(t[bmask].max())
            sig = smooth(df[col].astype(float), dt)
            z, _ = fatigue_z(sig, bmask, direction)
            if z is None:
                continue
            onset = find_onset(t, z, base_end, dt)
            if onset is None:
                continue
            fired.setdefault(name, set()).add(col)
            rel = t - onset
            m = np.isfinite(z) & (rel >= GRID[0] - 1) & (rel <= GRID[-1] + 1)
            if m.sum() >= 4:
                stacks[col].append(np.interp(GRID, rel[m], z[m], left=np.nan, right=np.nan))

    # ---- 표: 신호별 세션 수 + 조합 ----
    print("\n[신호별 '혼자 2σ 이탈' 세션 수]")
    for col, disp, _ in SIGS:
        print(f"  {disp:14s}: {len(stacks[col]):2d}세션")
    only = {col: [] for col, _, _ in SIGS}
    combos = {}
    for name, s in fired.items():
        if len(s) == 1:
            only[list(s)[0]].append(name)
        key = "+".join(d for c, d, _ in SIGS if c in s)
        combos[key] = combos.get(key, 0) + 1
    print("\n['이 신호에서만' 피로 잡힌 세션]")
    for col, disp, _ in SIGS:
        n = only[col]
        print(f"  {disp:14s} 만: {len(n)}세션" + (f"  ({', '.join(x[4:] for x in n)})" if n else ""))
    print("\n[잡힌 신호 조합 분포]")
    for k, v in sorted(combos.items(), key=lambda x: -x[1]):
        print(f"  {v}세션: {k or '(없음)'}")

    # ---- 플롯 ----
    import matplotlib.pyplot as plt
    plt.rcParams["font.family"] = "AppleGothic"; plt.rcParams["axes.unicode_minus"] = False
    fig, axes = plt.subplots(2, 3, figsize=(16, 8.5))
    axl = axes.flatten()
    colors = {"RMS": "C0", "MDF": "C2", "MW_Amp": "C0", "MW_Area": "C1", "MW_Latency": "C3"}
    for ax, (col, disp, _) in zip(axl, SIGS):
        arr = [a for a in stacks[col] if a is not None]
        for row in arr:
            ax.plot(GRID, row, color=colors[col], alpha=0.25, lw=0.9)
        if arr:
            with np.errstate(all="ignore"):
                mean = np.nanmean(np.vstack(arr), axis=0)
            ax.plot(GRID, mean, color=colors[col], lw=2.8, label=f"평균 (n={len(arr)})")
        ax.axhline(2, ls="--", color="red", alpha=.8, label="2σ")
        ax.axhline(0, color="black", lw=.4); ax.axvline(0, color="black", lw=.8)
        ax.set_ylim(-3, 8); ax.set_title(f"{disp} — 혼자 2σ 5초지속 이탈", fontsize=10.5)
        ax.set_xlabel("자기 온셋 기준 시간(초)"); ax.set_ylabel("피로방향 z")
        ax.legend(loc="upper left", fontsize=8); ax.grid(alpha=.2)
    axl[5].axis("off")
    axl[5].text(0.02, 0.9, "각 패널 = 그 신호가\n'혼자서 자기 2σ'를 넘은 세션들\n\n"
                "그 신호의 z를 자기 온셋(0)에\n정렬해 겹침 + 평균\n\n"
                "n = 그 신호로 피로 잡힌 세션 수\n\n"
                "왼쪽 콘솔 표에\nRMS만/MDF만/M-wave만\n세션 목록 있음",
                fontsize=10, va="top", transform=axl[5].transAxes)
    fig.suptitle("신호별 개별 2σ SPC (5초 지속) — 여러 세션", fontsize=13)
    fig.tight_layout()
    out = ROOT / "data_from_iphone" / "spc_multi.png"
    fig.savefig(out, dpi=120); print(f"\n그래프 저장 → {out}")


if __name__ == "__main__":
    main()
