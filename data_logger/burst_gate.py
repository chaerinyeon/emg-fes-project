#!/usr/bin/env python3
"""
burst_gate.py — 버스트(힘 주는 구간)에서만 MDF/RMS를 뽑아 세션 추세가 나아지는지 검증.

프로토콜 A: FES 자극 순간에 맞춰 악력 → 모든 활동이 ~1.5초 버스트에 몰림, 사이는 조용.
지금 펌웨어는 조용한 구간까지 무차별로 MDF/RMS를 계산해 값이 엉망(절벽).
여기선 오프라인에서 ENV(포락선)로 버스트를 찾아, 각 버스트의 '활동 정점' 행에서만
MDF/RMS를 뽑아(=버스트당 값 1개) 깨끗한 ~0.67Hz 시계열을 만든 뒤 추세를 본다.

비교: 게이팅 없음(전 구간) vs 버스트 정점만.  시간상관 ρ (MDF 하강<0, RMS 상승>0).
사용: python3 burst_gate.py --plot
"""
from __future__ import annotations
import argparse, glob, re
from pathlib import Path
import numpy as np
import pandas as pd
import fatigue_2sigma as f2

ROOT = Path(__file__).resolve().parent.parent


def spearman(x, y):
    m = np.isfinite(x) & np.isfinite(y)
    if m.sum() < 5:
        return np.nan
    xr = pd.Series(x[m]).rank().to_numpy(); yr = pd.Series(y[m]).rank().to_numpy()
    xr = xr - xr.mean(); yr = yr - yr.mean()
    d = np.sqrt((xr**2).sum() * (yr**2).sum())
    return float((xr*yr).sum()/d) if d > 0 else np.nan


def burst_peaks(df):
    """ENV로 버스트를 찾아 각 버스트의 ENV-정점 행 인덱스 리스트 반환."""
    if "ENV_Value" not in df.columns:
        return None
    env = df["ENV_Value"].to_numpy(dtype=float)
    p95 = np.nanpercentile(env, 95)
    thr = 0.2 * p95 if p95 > 0 else 0
    active = env > thr
    peaks = []
    i, n = 0, len(env)
    while i < n:
        if active[i]:
            j = i
            while j < n and active[j]:
                j += 1
            seg = env[i:j]
            peaks.append(i + int(np.argmax(seg)))    # 이 버스트의 정점 행
            i = j
        else:
            i += 1
    return peaks


def analyze(path):
    df = f2.load(path)
    if len(df) < 100 or "ENV_Value" not in df.columns:
        return None
    t = df["t_s"].to_numpy()
    mdf = df["MDF"].to_numpy(dtype=float); rms = df["RMS"].to_numpy(dtype=float)
    peaks = burst_peaks(df)
    if not peaks or len(peaks) < 8:
        return None
    tp = t[peaks]; mdf_p = mdf[peaks]; rms_p = rms[peaks]
    return {
        "name": re.search(r"(env_\d+_\d+)", path.name).group(1), "dur": t[-1],
        "n_burst": len(peaks),
        # 게이팅 없음(전 구간) vs 버스트 정점만
        "mdf_rho_all": spearman(t, mdf), "mdf_rho_gate": spearman(tp, mdf_p),
        "rms_rho_all": spearman(t, rms), "rms_rho_gate": spearman(tp, rms_p),
        "t": t, "mdf": mdf, "rms": rms, "tp": tp, "mdf_p": mdf_p, "rms_p": rms_p,
    }


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--plot", action="store_true")
    args = ap.parse_args()
    files = sorted(glob.glob(str(ROOT / "data_from_iphone/1차/env_*.csv")) +
                   glob.glob(str(ROOT / "data_from_iphone/2차/*.csv")))
    res = []
    for fp in files:
        try:
            r = analyze(Path(fp))
        except Exception:
            r = None
        if r:
            res.append(r)

    def summ(name, ka, kg, sign):
        a = np.array([r[ka] for r in res]); g = np.array([r[kg] for r in res])
        a = a[np.isfinite(a)]; g = g[np.isfinite(g)]
        d = "하강" if sign < 0 else "상승"
        print(f"\n[{name}] (피로={d}, ρ이 {'−' if sign<0 else '+'}쪽으로 뚜렷하면 좋음)")
        print(f"  게이팅 없음 : 중앙 ρ={np.median(a):+.2f}, 뚜렷(|ρ|>0.5) {np.mean(sign*a>0.5)*100:.0f}%")
        print(f"  버스트 정점만: 중앙 ρ={np.median(g):+.2f}, 뚜렷(|ρ|>0.5) {np.mean(sign*g>0.5)*100:.0f}%")

    print(f"분석 세션: {len(res)}개")
    summ("MDF", "mdf_rho_all", "mdf_rho_gate", -1)
    summ("RMS", "rms_rho_all", "rms_rho_gate", +1)

    if args.plot:
        import matplotlib.pyplot as plt
        plt.rcParams["font.family"] = "AppleGothic"; plt.rcParams["axes.unicode_minus"] = False
        ex = sorted(res, key=lambda r: -r["dur"])[:4]
        fig, axes = plt.subplots(2, 2, figsize=(14, 9))
        for ax, r in zip(axes.flat, ex):
            ax.plot(r["t"], r["mdf"], color="C2", alpha=0.25, lw=0.7, label="MDF 전구간(무차별)")
            ax.plot(r["tp"], r["mdf_p"], color="C3", lw=1.8, marker="o", ms=3,
                    label="MDF 버스트 정점만")
            ax.set_title(f"{r['name']} ({r['dur']:.0f}s, 버스트 {r['n_burst']}개)\n"
                         f"MDF ρ: 전구간 {r['mdf_rho_all']:+.2f} → 버스트 {r['mdf_rho_gate']:+.2f}",
                         fontsize=9)
            ax.set_ylabel("MDF (Hz)"); ax.set_xlabel("time (s)")
            ax.legend(fontsize=7); ax.grid(alpha=.25)
        fig.suptitle("버스트 게이팅 효과 — 조용한 구간 빼고 힘 주는 정점의 MDF만", fontsize=12)
        fig.tight_layout()
        out = ROOT / "data_from_iphone" / "burst_gate.png"
        fig.savefig(out, dpi=120); print(f"\n그래프 저장 → {out}")


if __name__ == "__main__":
    main()
