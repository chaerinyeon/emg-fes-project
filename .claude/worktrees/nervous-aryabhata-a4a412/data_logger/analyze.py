"""
EMG 세션 분석 — RMS / MDF / slope 시각화 + 통계 요약

사용:
    python analyze.py --subject A                 # subject_A 의 가장 최근 CSV
    python analyze.py --file path/to/session.csv  # 특정 파일
"""

from __future__ import annotations

import argparse
from pathlib import Path

import matplotlib.pyplot as plt
import pandas as pd

plt.rcParams["font.family"] = "AppleGothic"
plt.rcParams["axes.unicode_minus"] = False

ROOT = Path(__file__).resolve().parent.parent


def latest_csv(subject: str) -> Path:
    folder = ROOT / "data" / f"subject_{subject}"
    csvs = sorted(folder.glob("*.csv"))
    if not csvs:
        raise SystemExit(f"no CSV in {folder}")
    return csvs[-1]


def summarize(df: pd.DataFrame) -> None:
    duration = (df["timestamp_ms"].iloc[-1] - df["timestamp_ms"].iloc[0]) / 1000
    print(f"\n=== 세션 요약 ===")
    print(f"  샘플 수      : {len(df)} rows ({duration:.1f}초)")
    print(f"  emg_raw      : mean={df['emg_raw'].mean():.1f}  "
          f"min={df['emg_raw'].min()}  max={df['emg_raw'].max()}  "
          f"std={df['emg_raw'].std():.1f}")
    print(f"  RMS          : mean={df['rms'].mean():.2f}  "
          f"min={df['rms'].min():.2f}  max={df['rms'].max():.2f}  "
          f"std={df['rms'].std():.2f}")
    print(f"  MDF (Hz)     : mean={df['mdf'].mean():.2f}  "
          f"min={df['mdf'].min():.2f}  max={df['mdf'].max():.2f}")

    valid = df[df["history_count"] >= 30]
    if len(valid):
        print(f"  RMS slope    : mean={valid['rms_slope'].mean():+.2f}%  "
              f"max=+{valid['rms_slope'].max():.2f}%")
        print(f"  MDF slope    : mean={valid['mdf_slope'].mean():+.2f}%  "
              f"min={valid['mdf_slope'].min():.2f}%")

    fatigue = df["fatigue_detected"].sum() if df["fatigue_detected"].dtype == bool \
              else (df["fatigue_detected"].astype(str).str.lower() == "true").sum()
    stim_on = df["is_stimulating"].astype(str).str.lower().eq("true").sum()
    markers = df[df["marker"].astype(str).str.len() > 0]
    print(f"  fatigue=True : {fatigue} 회")
    print(f"  자극 중 행   : {stim_on}")
    if len(markers):
        print(f"  마커         : {markers['marker'].tolist()}")


def plot(df: pd.DataFrame, out_path: Path) -> None:
    t = (df["timestamp_ms"] - df["timestamp_ms"].iloc[0]) / 1000  # 초

    fig, axes = plt.subplots(4, 1, figsize=(12, 10), sharex=True)

    axes[0].plot(t, df["emg_raw"], lw=0.6, color="gray")
    axes[0].axhline(1900, ls="--", color="red", alpha=0.5, label="DC_OFFSET=1900")
    axes[0].set_ylabel("emg_raw (ADC)")
    axes[0].legend(loc="upper right")
    axes[0].set_title("EMG raw (DC offset 확인용)")

    axes[1].plot(t, df["rms"], color="C0")
    axes[1].set_ylabel("RMS")
    axes[1].set_title("RMS (1초 윈도우)")

    axes[2].plot(t, df["mdf"], color="C2")
    axes[2].set_ylabel("MDF (Hz)")
    axes[2].set_title("MDF — 피로 시 감소")

    valid = df[df["history_count"] >= 30]
    if len(valid):
        tv = (valid["timestamp_ms"] - df["timestamp_ms"].iloc[0]) / 1000
        axes[3].plot(tv, valid["rms_slope"], label="RMS slope %", color="C0")
        axes[3].plot(tv, valid["mdf_slope"], label="MDF slope %", color="C2")
        axes[3].axhline(20, ls="--", color="C0", alpha=0.4, label="RMS thr +20%")
        axes[3].axhline(-10, ls="--", color="C2", alpha=0.4, label="MDF thr -10%")
        axes[3].axhline(0, color="black", lw=0.3)
        axes[3].set_ylabel("slope (%)")
        axes[3].legend(loc="upper right", fontsize=8)
        axes[3].set_title("Slope — 두 임계 동시 만족 시 피로 판정")

    # 마커/자극 구간 표시
    for ax in axes:
        for _, row in df[df["marker"].astype(str).str.len() > 0].iterrows():
            tm = (row["timestamp_ms"] - df["timestamp_ms"].iloc[0]) / 1000
            ax.axvline(tm, color="purple", lw=0.5, alpha=0.6)
        stim_mask = df["is_stimulating"].astype(str).str.lower() == "true"
        if stim_mask.any():
            ax.fill_between(t, *ax.get_ylim(), where=stim_mask,
                            alpha=0.08, color="orange")

    axes[3].set_xlabel("time (s)")
    fig.tight_layout()
    fig.savefig(out_path, dpi=120)
    print(f"\n그래프 저장 → {out_path}")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--subject", default="A")
    ap.add_argument("--file", default=None)
    args = ap.parse_args()

    csv_path = Path(args.file) if args.file else latest_csv(args.subject)
    print(f"reading {csv_path}")
    df = pd.read_csv(csv_path)

    summarize(df)
    out = csv_path.with_suffix(".png")
    plot(df, out)


if __name__ == "__main__":
    main()
