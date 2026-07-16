#!/usr/bin/env python3
"""
cycle_trend.py — 자극주기(1.5초) 평균으로 노이즈를 걷어내고
                 '세션 전체(분 단위) 피로 추세'가 깨끗하게 보이는지 검증.

앞선 onset_fine.py 결과: 10Hz 원신호는 1.5초 FES 주기 진동에 덮여
초 단위 예측 신호가 안 보였다. 여기선 목표를 바꿔 —
자극주기로 평균 → 느린 추세만 남기고, 그 추세가 LSTM으로 추적할 만큼
깨끗한지(매끄러운 단조 하강인지)를 정량화한다.

지표(세션별):
  - MDF, M-wave Area 를 1.5초(=주기) 이동평균으로 cycle-average
  - trend_clarity = var(9초 추세) / var(1.5초 평균)  → 1에 가까울수록 노이즈 대비 추세 지배
  - 단조성(Spearman ρ vs 시간): M-wave는 정점 이후 구간에서, MDF는 전체에서

사용: python3 cycle_trend.py --plot
"""
from __future__ import annotations
import argparse, glob, re
from pathlib import Path
import numpy as np
import pandas as pd
import fatigue_2sigma as f2

ROOT = Path(__file__).resolve().parent.parent
CYCLE_S = 1.5     # FES 주기
TREND_S = 9.0     # 느린 추세 창


def spearman(x, y):
    """의존성 없는 간단 Spearman ρ."""
    m = np.isfinite(x) & np.isfinite(y)
    if m.sum() < 5:
        return np.nan
    xr = pd.Series(x[m]).rank().to_numpy()
    yr = pd.Series(y[m]).rank().to_numpy()
    xr = xr - xr.mean(); yr = yr - yr.mean()
    d = np.sqrt((xr**2).sum() * (yr**2).sum())
    return float((xr*yr).sum()/d) if d > 0 else np.nan


def smooth(series, win_s, dt_s):
    n = max(1, round(win_s/dt_s))
    return series.rolling(n, center=True, min_periods=max(1, n//2)).mean()


def analyze_session(path: Path):
    df = f2.load(path)
    if len(df) < 100:
        return None
    dt = f2.infer_dt(df)
    t = df["t_s"].to_numpy()
    name = re.search(r"(env_\d+_\d+)", path.name).group(1)

    def trend(col, post_peak):
        """한 신호의 주기평균·9초추세·지배도·단조ρ 계산. post_peak면 정점 이후 ρ."""
        if col not in df.columns or df[col].notna().sum() < 20:
            return None
        sig = df[col].astype(float)
        c = smooth(sig, CYCLE_S, dt); tr = smooth(sig, TREND_S, dt)
        ca = c.to_numpy(); ta = tr.to_numpy()
        if np.isfinite(ta).sum() < 5 or np.isfinite(ca).sum() < 5:
            return None
        vc = np.nanvar(ca)
        clarity = np.nanvar(ta)/vc if vc > 0 else np.nan
        if post_peak and np.isfinite(ta).sum() >= 5:
            pk = int(np.nanargmax(ta))
            rho = spearman(t[pk:], ta[pk:]); peak_t = t[pk]
        else:
            rho = spearman(t, ta); peak_t = np.nan
        return {"c": ca, "tr": ta, "clarity": clarity, "rho": rho, "peak_t": peak_t}

    # 신호별 (피로방향, 정점이후만 볼지)
    out = {"t": t, "name": name, "dur": t[-1],
           "rms":  trend("RMS", False),          # 피로=상승
           "mdf":  trend("MDF", False),          # 피로=하강
           "mwamp": trend("MW_Amp", True),       # 피로=정점후 하강
           "mwarea": trend("MW_Area", True),     # 피로=정점후 하강
           "mwlat": trend("MW_Latency", False)}  # 피로=상승
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--plot", action="store_true")
    args = ap.parse_args()
    files = sorted(glob.glob(str(ROOT / "data_from_iphone/1차/env_*.csv")) +
                   glob.glob(str(ROOT / "data_from_iphone/2차/*.csv")))
    res = []
    for fp in files:
        try:
            r = analyze_session(Path(fp))
        except Exception:
            r = None
        if r: res.append(r)

    print(f"\n분석 세션: {len(res)}개  (1.5초 주기평균 → 9초 추세)")

    def summ(label, key, mono_sign, note):
        vals = [r[key] for r in res if r.get(key) is not None]
        clar = np.array([v["clarity"] for v in vals])
        rho = np.array([v["rho"] for v in vals])
        clar = clar[np.isfinite(clar)]; rho = rho[np.isfinite(rho)]
        if len(rho) == 0:
            print(f"\n[{label}] 유효 세션 없음"); return
        d = "하강" if mono_sign < 0 else "상승"
        strong = np.mean((mono_sign*rho) > 0.5)*100
        print(f"\n[{label}]  ({note})")
        print(f"  세션 {len(rho)}개 · 추세 지배도 중앙 {np.median(clar):.2f}")
        print(f"  피로방향({d}) 뚜렷(|ρ|>0.5): {strong:.0f}%   중앙 ρ={np.median(rho):+.2f}")

    print("\n=== 자발 스트림 ===")
    summ("RMS", "rms", +1, "피로=상승")
    summ("MDF", "mdf", -1, "피로=하강")
    print("\n=== 유발(M-wave) 스트림 ===")
    summ("M-wave 진폭(정점후)", "mwamp", -1, "피로=하강")
    summ("M-wave 면적(정점후)", "mwarea", -1, "피로=하강")
    summ("M-wave 잠복기", "mwlat", +1, "피로=상승")

    if args.plot:
        import matplotlib.pyplot as plt
        plt.rcParams["font.family"] = "AppleGothic"; plt.rcParams["axes.unicode_minus"] = False
        # M-wave 3지표가 다 있는 세션 중 긴 것 6개
        ex = sorted([r for r in res if r["mwarea"] is not None and r["mwamp"] is not None],
                    key=lambda r: -r["dur"])[:6]
        fig, axes = plt.subplots(3, 2, figsize=(14, 11))
        for ax, r in zip(axes.flat, ex):
            axL = ax.twinx()   # 잠복기용 오른쪽 축
            # 진폭·면적: 정규화(각자 최대=1)해서 한 축에 겹쳐 봄
            def norm(v):
                m = np.nanmax(np.abs(v));  return v/m if m and np.isfinite(m) else v
            ax.plot(r["t"], norm(r["mwamp"]["tr"]), color="C0", lw=2.0, label="진폭(정규화)")
            ax.plot(r["t"], norm(r["mwarea"]["tr"]), color="C1", lw=2.0, label="면적(정규화)")
            axL.plot(r["t"], r["mwlat"]["tr"], color="C3", lw=1.6, ls="--", label="잠복기(ms)")
            if np.isfinite(r["mwarea"]["peak_t"]):
                ax.axvline(r["mwarea"]["peak_t"], color="gray", ls=":", lw=1)
            ax.set_title(f"{r['name']} ({r['dur']:.0f}s)  "
                         f"진폭ρ={r['mwamp']['rho']:+.2f} 면적ρ={r['mwarea']['rho']:+.2f} "
                         f"잠복ρ={r['mwlat']['rho']:+.2f}", fontsize=8.5)
            ax.set_ylabel("진폭·면적(정규화)", fontsize=8)
            axL.set_ylabel("잠복기(ms)", color="C3", fontsize=8)
            ax.tick_params(labelsize=7); axL.tick_params(labelsize=7)
            if ax is axes.flat[0]:
                ax.legend(loc="lower left", fontsize=7); axL.legend(loc="lower right", fontsize=7)
        fig.suptitle("M-wave 3지표 세션 추세 — 진폭↓·면적↓·잠복기↑ 면 피로 (점선=정점)", fontsize=12)
        fig.tight_layout()
        out = ROOT / "data_from_iphone" / "cycle_trend.png"
        fig.savefig(out, dpi=120); print(f"\n그래프 저장 → {out}")


if __name__ == "__main__":
    main()
