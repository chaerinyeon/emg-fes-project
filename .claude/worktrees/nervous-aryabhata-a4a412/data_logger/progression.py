"""
근피로도 진행 분석 — 활성화(is_running) 구간만 추출해 30초 bin 단위로 변화 추세 표시.

사용:
    python progression.py --subject A
    python progression.py --file path/to/session.csv
    python progression.py --subject A --bin 30   # bin 크기 변경
"""

from __future__ import annotations

import argparse
from pathlib import Path

import matplotlib.pyplot as plt
import pandas as pd

plt.rcParams["font.family"] = "AppleGothic"
plt.rcParams["axes.unicode_minus"] = False

ROOT = Path(__file__).resolve().parent.parent

# 펌웨어 임계값 (현재 코드와 동기화)
RMS_THR = 20.0
MDF_THR = -3.0
CONSECUTIVE = 5


def latest_csv(subject: str) -> Path:
    folder = ROOT / "data" / f"subject_{subject}"
    csvs = sorted(folder.glob("*.csv"))
    if not csvs:
        raise SystemExit(f"no CSV in {folder}")
    return csvs[-1]


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--subject", default="A")
    ap.add_argument("--file", default=None)
    ap.add_argument("--bin", type=float, default=30.0, help="bin 크기 (초)")
    args = ap.parse_args()

    csv_path = Path(args.file) if args.file else latest_csv(args.subject)
    print(f"reading {csv_path}\n")

    df = pd.read_csv(csv_path)
    df["is_running_b"] = df["is_running"].astype(str).str.lower() == "true"
    active = df[df["is_running_b"]].reset_index(drop=True)
    if len(active) == 0:
        raise SystemExit("활성화(is_running=True) 구간이 없음")

    active["t"] = (active["timestamp_ms"] - active["timestamp_ms"].iloc[0]) / 1000
    active["valid_slope"] = active["history_count"] >= 30
    active["rms_pass"] = active["rms_slope"] > RMS_THR
    active["mdf_pass"] = active["mdf_slope"] < MDF_THR
    active["both_pass"] = active["rms_pass"] & active["mdf_pass"] & active["valid_slope"]

    # 5회 연속 트리거 재현
    consec, trig_idx = 0, []
    for i, b in enumerate(active["both_pass"].values):
        consec = consec + 1 if b else 0
        if consec >= CONSECUTIVE:
            trig_idx.append(i)
            consec = 0  # 트리거 후 카운트 리셋 (실제 펌웨어는 아님 — 분석 단순화)

    # ===== 텍스트 요약 =====
    duration = active["t"].iloc[-1]
    print(f"=== 활성화 구간 ===")
    print(f"  지속시간     : {duration:.1f} 초 ({len(active)} samples)")
    print(f"  RMS slope > +{RMS_THR}%  통과: {active['rms_pass'].sum()} / {active['valid_slope'].sum()}")
    print(f"  MDF slope < {MDF_THR}%   통과: {active['mdf_pass'].sum()} / {active['valid_slope'].sum()}")
    print(f"  두 조건 AND 동시 만족   : {active['both_pass'].sum()} 회 ({active['both_pass'].mean()*100:.1f}%)")
    print(f"  → {CONSECUTIVE}회 연속 만족(=피로 트리거): {len(trig_idx)} 회")
    if trig_idx:
        for ti in trig_idx[:5]:
            print(f"      t={active['t'].iloc[ti]:.1f}s  RMS slope={active['rms_slope'].iloc[ti]:+.1f}%  MDF slope={active['mdf_slope'].iloc[ti]:+.1f}%")

    # ===== bin 통계 =====
    print(f"\n=== {args.bin:.0f}초 bin 진행 추세 ===")
    active["bin"] = (active["t"] // args.bin).astype(int)
    g = active.groupby("bin").agg(
        n=("rms", "size"),
        rms_mean=("rms", "mean"),
        rms_max=("rms", "max"),
        mdf_mean=("mdf", "mean"),
        rms_slope_mean=("rms_slope", "mean"),
        rms_slope_max=("rms_slope", "max"),
        mdf_slope_mean=("mdf_slope", "mean"),
        mdf_slope_min=("mdf_slope", "min"),
        both_pct=("both_pass", lambda s: s.mean() * 100),
    ).round(2)
    g.index = [f"{int(i)*int(args.bin):3d}~{(int(i)+1)*int(args.bin):3d}s" for i in g.index]
    print(g.to_string())

    # ===== 그래프 =====
    fig, axes = plt.subplots(3, 1, figsize=(13, 9), sharex=True)

    ax = axes[0]
    ax.plot(active["t"], active["rms"], color="C0", lw=0.8, alpha=0.5, label="RMS")
    ax.plot(active["t"], active["rms"].rolling(5, min_periods=1).mean(), color="C0", lw=2, label="RMS (5s 이동평균)")
    ax.set_ylabel("RMS")
    ax.set_title("RMS — 근활성도 (값 자체가 클수록 강하게 수축)")
    ax.legend(loc="upper right")

    ax = axes[1]
    ax.plot(active["t"], active["mdf"], color="C2", lw=0.8, alpha=0.5, label="MDF")
    ax.plot(active["t"], active["mdf"].rolling(5, min_periods=1).mean(), color="C2", lw=2, label="MDF (5s 이동평균)")
    ax.set_ylabel("MDF (Hz)")
    ax.set_title("MDF — 중간주파수 (피로 시 감소 경향)")
    ax.legend(loc="upper right")

    ax = axes[2]
    valid = active[active["valid_slope"]]
    ax.plot(valid["t"], valid["rms_slope"], color="C0", lw=1.5, label="RMS slope %")
    ax.plot(valid["t"], valid["mdf_slope"], color="C2", lw=1.5, label="MDF slope %")
    ax.axhline(RMS_THR, ls="--", color="C0", alpha=0.5, label=f"RMS thr +{RMS_THR}%")
    ax.axhline(MDF_THR, ls="--", color="C2", alpha=0.5, label=f"MDF thr {MDF_THR}%")
    ax.axhline(0, color="black", lw=0.3)
    # 두 조건 동시 만족 구간 음영
    ax.fill_between(active["t"], -300, 300, where=active["both_pass"],
                    alpha=0.25, color="red", label="둘 다 만족")
    # 트리거 시점 세로선
    for ti in trig_idx:
        ax.axvline(active["t"].iloc[ti], color="red", lw=1.5, alpha=0.7)
    ax.set_ylabel("slope (%)")
    ax.set_xlabel("time (s, 활성화 시작 기준)")
    ax.set_title("Slope — 빨간 영역 = 두 조건 동시 만족 / 빨간 세로선 = 5회 연속 트리거")
    ax.legend(loc="upper right", fontsize=8, ncol=2)
    ax.set_ylim(-100, 200)

    fig.tight_layout()
    out_path = csv_path.parent / (csv_path.stem + "_progression.png")
    fig.savefig(out_path, dpi=120)
    print(f"\n그래프 저장 → {out_path}")


if __name__ == "__main__":
    main()
