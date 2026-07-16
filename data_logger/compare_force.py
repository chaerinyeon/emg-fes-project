#!/usr/bin/env python3
"""
compare_force.py — 'FES O + 힘 X' vs 'FES O + 힘 O' 세션의 자극동기 평균(STA) 비교.

왜 STA인가:
  - 자극 아티팩트는 자극에 동기 → 평균에 그대로 남음 (두 세션 동일해야 함)
  - 자발 EMG 는 자극과 무관(무작위) → 평균에서 상쇄됨
  → 두 STA 의 차이 = '자발 수축이 유발반응(M-wave)을 바꿨는가'

핵심 판정:
  - 아티팩트 구간(0~4ms)이 두 세션에서 같으면 → 자극 세기 동일, 비교 유효
  - 그 뒤 구간(5~15ms)이 다르면 → 그건 근육에서 온 것 = 진짜 M-wave
  - 그 뒤 구간도 같으면 → 전기적 잔향(아티팩트 반동)일 뿐, M-wave 아님

사용: python3 compare_force.py <raw_힘X.csv> <raw_힘O.csv>
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
import pandas as pd

DC_OFFSET = 1862.0
STIM_THRESH = 400.0     # 실측: 진짜 아티팩트 peak ~600~900 (펌웨어 1000 은 너무 높음)
STIM_REFRAC = 25        # ms — 자극주기 31ms 보다 짧게
PRE, POST = 5, 28       # STA 창 (자극 기준 -5 ~ +28ms)


def load_centered(path: Path) -> np.ndarray:
    df = pd.read_csv(path)
    return df["Raw_ADC"].to_numpy(dtype=float) - DC_OFFSET


def find_stim(c: np.ndarray) -> np.ndarray:
    """자극 시점(샘플 인덱스). |centered| 가 문턱을 넘는 첫 표본, refractory 로 중복 제거."""
    idx = np.where(np.abs(c) > STIM_THRESH)[0]
    stim, last = [], -10_000
    for i in idx:
        if i - last >= STIM_REFRAC:
            stim.append(i)
            last = i
    return np.array(stim)


def sta(c: np.ndarray, stim: np.ndarray):
    """자극동기 평균. 반환: (t_ms, 평균, 표준편차, 겹친 횟수)"""
    segs = np.array([c[s - PRE:s + POST] for s in stim
                     if s >= PRE and s + POST < len(c)])
    return np.arange(-PRE, POST), segs.mean(axis=0), segs.std(axis=0), len(segs)


def period_stats(stim: np.ndarray) -> tuple[float, float]:
    iv = np.diff(stim)
    return float(np.median(iv)), float(np.percentile(iv, 75) - np.percentile(iv, 25))


def describe(name: str, c: np.ndarray, stim: np.ndarray) -> dict:
    per, iqr = period_stats(stim)
    t, avg, sd, n = sta(c, stim)
    a = np.abs(c)
    print(f"\n=== {name} ===")
    print(f"  길이 {len(c)/1000:.1f}초   자극 {len(stim):,}개   주기 중앙 {per:.0f}ms "
          f"(IQR {iqr:.0f}) → {1000/per:.1f} Hz")
    print(f"  |centered| : 중앙 {np.median(a):.0f}, 99.9% {np.percentile(a,99.9):.0f}, "
          f"최대 {a.max():.0f}")
    print(f"  STA 겹침   : {n:,}회")
    return {"t": t, "avg": avg, "sd": sd, "n": n, "period": per}


def main() -> None:
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(1)
    p_no, p_yes = Path(sys.argv[1]), Path(sys.argv[2])

    c_no, c_yes = load_centered(p_no), load_centered(p_yes)
    s_no, s_yes = find_stim(c_no), find_stim(c_yes)
    r_no = describe(f"힘 X — {p_no.name}", c_no, s_no)
    r_yes = describe(f"힘 O — {p_yes.name}", c_yes, s_yes)

    t = r_no["t"]
    a_no, a_yes = r_no["avg"], r_yes["avg"]

    print("\n=== 자극동기 평균 비교 (ms: 힘X / 힘O / 차이) ===")
    for i, tt in enumerate(t):
        if tt < -2 or tt > 26:
            continue
        d = a_yes[i] - a_no[i]
        mark = "  ←차이 큼" if abs(d) > max(60.0, 0.3 * abs(a_no[i])) else ""
        print(f"  {tt:+3d} : {a_no[i]:+8.1f} / {a_yes[i]:+8.1f} / {d:+8.1f}{mark}")

    def seg(a, lo, hi):
        m = (t >= lo) & (t <= hi)
        return a[m].max() - a[m].min()

    art_no, art_yes = seg(a_no, 0, 4), seg(a_yes, 0, 4)
    mw_no, mw_yes = seg(a_no, 5, 15), seg(a_yes, 5, 15)

    print("\n=== 구간별 진폭(max-min) ===")
    print(f"  아티팩트(0~4ms)  : 힘X {art_no:7.1f}  힘O {art_yes:7.1f}  "
          f"변화 {(art_yes-art_no)/art_no*100:+6.1f}%")
    print(f"  반응부(5~15ms)   : 힘X {mw_no:7.1f}  힘O {mw_yes:7.1f}  "
          f"변화 {(mw_yes-mw_no)/mw_no*100:+6.1f}%")

    print("\n=== 판정 ===")
    art_same = abs(art_yes - art_no) / art_no < 0.20
    mw_diff = abs(mw_yes - mw_no) / mw_no > 0.20
    if not art_same:
        print("  ⚠️ 아티팩트가 20% 넘게 다름 → 자극 세기/전극이 바뀜. 두 세션 직접비교 주의.")
    elif mw_diff:
        print("  ✅ 아티팩트는 같은데 5~15ms 반응부만 변함")
        print("     → 그 구간은 '근육에서 온 것' = 진짜 M-wave 로 볼 근거")
    else:
        print("  ❌ 아티팩트도 반응부도 그대로")
        print("     → 5~15ms 는 전기적 잔향(아티팩트 반동)일 뿐, M-wave 근거 약함")

    # ---- 그래프 ----
    import matplotlib.pyplot as plt
    plt.rcParams["font.family"] = "AppleGothic"
    plt.rcParams["axes.unicode_minus"] = False
    fig, ax = plt.subplots(1, 2, figsize=(14, 5))

    for a, r, lab, col in ((a_no, r_no, "힘 X (FES만)", "C0"),
                           (a_yes, r_yes, "힘 O (FES+악력)", "C3")):
        ax[0].plot(t, a, color=col, lw=2, label=f"{lab}  (n={r['n']:,})")
        ax[0].fill_between(t, a - r["sd"], a + r["sd"], color=col, alpha=0.12)
    ax[0].axvspan(0, 4, color="gray", alpha=0.18, label="아티팩트 구간")
    ax[0].axvspan(5, 15, color="green", alpha=0.10, label="반응부(M-wave 후보)")
    ax[0].axhline(0, color="black", lw=0.4)
    ax[0].axvline(0, color="black", lw=0.8)
    ax[0].set_xlabel("자극 기준 시간 (ms)")
    ax[0].set_ylabel("centered ADC")
    ax[0].set_title("자극동기 평균 — 자발 EMG는 상쇄되고 유발반응만 남음")
    ax[0].legend(fontsize=8)
    ax[0].grid(alpha=0.25)

    ax[1].plot(t, a_yes - a_no, color="C2", lw=2)
    ax[1].axvspan(0, 4, color="gray", alpha=0.18)
    ax[1].axvspan(5, 15, color="green", alpha=0.10)
    ax[1].axhline(0, color="black", lw=0.4)
    ax[1].axvline(0, color="black", lw=0.8)
    ax[1].set_xlabel("자극 기준 시간 (ms)")
    ax[1].set_ylabel("힘O − 힘X")
    ax[1].set_title("차이 — 아티팩트 구간은 0에 가깝고\n반응부만 벌어지면 그게 M-wave")
    ax[1].grid(alpha=0.25)

    fig.suptitle("FES 자극동기 평균: 힘 X vs 힘 O", fontsize=13)
    fig.tight_layout()
    out = Path.home() / "Desktop" / "data" / "compare_force.png"
    fig.savefig(out, dpi=120)
    print(f"\n그래프 저장 → {out}")


if __name__ == "__main__":
    main()
