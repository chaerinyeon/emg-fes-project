#!/usr/bin/env python3
"""
onset_projected.py — "FES 주기 들쭉날쭉을 걷어냈다면?" 온셋궤적 예상.

onset_5signal.py 는 10Hz 원신호 z(주기 진동 포함). 여기선 각 신호를 자극주기
(~1.5초, 넉넉히 3초=2주기) 이동평균으로 먼저 평활 → 주기 노이즈 제거 후 z·정렬.
'주기 노이즈가 유일한 문제였다면' 나올 온셋궤적의 낙관적 상한을 보여준다.
(주의: saturation·검출정지·자발오염은 이 방법으로 복구 안 됨 → 실제는 이보다 나쁠 수 있음)

비교용으로 원신호(옅게)와 평활(굵게)을 겹쳐 그린다.
사용: python3 onset_projected.py
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
SMOOTH_S = 3.0        # 자극주기(1.5초)×2 → 주기 노이즈 제거


def aligned(t, z, onset):
    if onset is None or z is None:
        return None
    rel = np.asarray(t) - onset
    m = np.isfinite(z) & (rel >= GRID[0] - 1) & (rel <= GRID[-1] + 1)
    if m.sum() < 4:
        return None
    return np.interp(GRID, rel[m], np.asarray(z)[m], left=np.nan, right=np.nan)


def zof(series, mask, dt, invert, smooth):
    # baseline μ·σ 는 항상 '원신호'에서 산출 → raw·평활을 같은 눈금(원래 노이즈 단위)으로 비교.
    # (평활 신호로 σ를 재면 σ가 작아져 z가 인위적으로 부풀려짐)
    b = series[mask].dropna()
    if len(b) < 5:
        return None
    mu, sd = b.mean(), b.std()
    sd = max(sd if sd and sd > 0 else 0.0, 0.05 * abs(mu))
    if sd <= 0:
        return None
    s = series
    if smooth:
        n = max(1, round(SMOOTH_S / (dt if dt > 0 else 0.1)))
        s = series.rolling(n, center=True, min_periods=max(1, n // 2)).mean()
    z = (mu - s) / sd if invert else (s - mu) / sd
    return z.to_numpy()


def main():
    keys = [("RMS", "RMS", False, "vol"), ("MDF", "MDF", True, "vol"),
            ("MW_Amp", "MW_Amp", True, "mw"), ("MW_Area", "MW_Area", True, "mw"),
            ("MW_Latency", "MW_Latency", False, "mw")]
    raw = {k[0]: [] for k in keys}
    smo = {k[0]: [] for k in keys}

    for fp in sorted(glob.glob(str(ROOT / "data_from_iphone/1차/env_*.csv")) +
                     glob.glob(str(ROOT / "data_from_iphone/2차/*.csv"))):
        p = Path(fp)
        try:
            win, st = f2.process(p)
        except Exception:
            continue
        df = f2.load(p); tt = df["t_s"]; dt = f2.infer_dt(df)
        vol_on = st.get("onset_t")
        mw_on = st.get("mw_onset_t")
        # M-wave baseline = 증강 플래토
        platmask = None
        if st.get("mw_ok") and "mw_plateau" in win:
            pl = win[win["mw_plateau"]]
            if len(pl):
                platmask = (tt >= pl["t_center"].min()) & (tt <= pl["t_center"].max())
        for col, name, inv, stream in keys:
            if col not in df.columns:
                continue
            if stream == "vol":
                onset = vol_on; base = tt <= BASE_S
            else:
                onset = mw_on; base = platmask
            if onset is None or base is None:
                continue
            zr = zof(df[col], base, dt, inv, smooth=False)
            zs = zof(df[col], base, dt, inv, smooth=True)
            ar = aligned(tt, zr, onset); asm = aligned(tt, zs, onset)
            if ar is not None: raw[name].append(ar)
            if asm is not None: smo[name].append(asm)

    import matplotlib.pyplot as plt
    plt.rcParams["font.family"] = "AppleGothic"; plt.rcParams["axes.unicode_minus"] = False
    titles = {"RMS": "RMS (상승=피로)", "MDF": "MDF (하강=피로)",
              "MW_Amp": "M-wave 진폭 (하강=피로)", "MW_Area": "M-wave 면적 (하강=피로)",
              "MW_Latency": "M-wave 잠복기 (상승=피로)"}
    colors = {"RMS": "C0", "MDF": "C2", "MW_Amp": "C0", "MW_Area": "C1", "MW_Latency": "C3"}
    fig, axes = plt.subplots(2, 3, figsize=(16, 8.5))
    axl = axes.flatten()
    for ax, (col, name, _, _) in zip(axl, keys):
        rr = [a for a in raw[name] if a is not None]
        ss = [a for a in smo[name] if a is not None]
        with np.errstate(all="ignore"):
            if rr:
                ax.plot(GRID, np.nanmean(np.vstack(rr), axis=0), color=colors[name],
                        alpha=0.35, lw=1.3, label=f"원신호 (주기포함) n={len(rr)}")
            if ss:
                S = np.vstack(ss)
                mean = np.nanmean(S, axis=0); q1 = np.nanpercentile(S, 25, axis=0); q3 = np.nanpercentile(S, 25, axis=0)
                ax.plot(GRID, mean, color=colors[name], lw=2.8, label=f"주기 걷어냄 n={len(ss)}")
        ax.axhline(2, ls="--", color="red", alpha=.8); ax.axhline(1, ls=":", color="gray")
        ax.axhline(0, color="black", lw=.4); ax.axvline(0, color="black", lw=.8); ax.set_ylim(-4, 8)
        ax.set_title(titles[name], fontsize=11); ax.set_xlabel("온셋 기준 시간(초)")
        ax.set_ylabel("피로방향 z"); ax.legend(loc="upper left", fontsize=8); ax.grid(alpha=.25)
    ax6 = axl[5]; ax6.axis("off")
    ax6.text(0.02, 0.92,
             "‘FES 주기 들쭉날쭉을 걷어냈다면’\n예상 온셋궤적 (낙관적 상한)\n\n"
             "• 굵은선 = 주기 3초 평활 후\n• 옅은선 = 원신호(주기 포함)\n\n"
             "평활 후에도 평평하면\n→ 주기 노이즈가 문제 아님\n   (신호 자체가 없음)\n\n"
             "평활하니 램프가 드러나면\n→ 깨끗이 모으면 예측 여지\n\n"
             "※ saturation·검출정지·자발오염은\n  이 방법으로 복구 안 됨",
             fontsize=9.5, va="top", transform=ax6.transAxes)
    fig.suptitle("FES 주기 노이즈 제거 시 예상 온셋궤적 — 수집계획 판단용", fontsize=13)
    fig.tight_layout()
    out = ROOT / "data_from_iphone" / "onset_projected.png"
    fig.savefig(out, dpi=120); print(f"그래프 저장 → {out}")
    for col, name, _, _ in keys:
        print(f"  {titles[name]}: 원 {len([a for a in raw[name] if a is not None])} / 평활 {len([a for a in smo[name] if a is not None])} 세션")


if __name__ == "__main__":
    main()
