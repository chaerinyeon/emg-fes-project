#!/usr/bin/env python3
"""
dataset_catalog.py — 지금까지 뽑은 모든 EMG/FES 세션을 한 표로 정리.

repo 안의 모든 데이터 폴더를 훑어 세션별 메타데이터·피로판정·품질플래그를
하나의 마스터 CSV(dataset_catalog.csv)로 뽑고, 콘솔에 분포 요약을 찍는다.
딥러닝 설계 전 '무슨 데이터가 얼마나, 어떤 라벨로, 쓸만하게 있나'를 판단하는 용도.

두 데이터 계열:
  - iPhone 계열 : 헤더 Time(ms),... — 10Hz(100ms) 피처 스트림, M-wave 포함
  - Logger 계열 : 헤더 wall_time,timestamp_ms,... — 구형 ~1Hz, M-wave 없음

사용:
  python3 dataset_catalog.py                 # repo 전체 스캔 → CSV + 요약
  python3 dataset_catalog.py --out cat.csv    # 저장 경로 지정
"""
from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
import pandas as pd

import fatigue_2sigma as f2  # 같은 폴더의 피로 분석 재사용

ROOT = Path(__file__).resolve().parent.parent

# (라벨, 폴더 glob) — venv/worktree/시뮬레이션 제외
SCAN_DIRS = [
    ("iphone_1차", "data_from_iphone/1차"),
    ("iphone_2차", "data_from_iphone/2차"),
    ("logger_subjectA", "data/subject_A"),
    ("logger_subjectB", "data/subject_B"),
    ("logger_subjectC", "data/subject_C"),
    ("logger_bench", "data_logger/data"),
]

IPHONE_MARK = "Time(ms)"       # iPhone 계열 판별 컬럼
LOGGER_MARK = "timestamp_ms"   # Logger 계열 판별 컬럼


def scan_iphone(path: Path) -> dict:
    """iPhone 계열 한 세션 요약. 피로분석은 fatigue_2sigma 재사용."""
    df = pd.read_csv(path)
    cols = set(df.columns)
    rec = {
        "n_rows": len(df),
        "has_raw": "Raw_ADC" in cols,
        "has_env": "ENV_Value" in cols,
        "has_rms_mdf": {"RMS", "MDF"}.issubset(cols),
        "has_mw": {"MW_Amp", "MW_Area"}.issubset(cols),
    }
    if len(df):
        rec["dur_s"] = (df["Time(ms)"].iloc[-1] - df["Time(ms)"].iloc[0]) / 1000
    else:
        rec["dur_s"] = 0.0
    # 마커
    if "Marker" in cols:
        mk = df["Marker"].dropna().astype(str).str.strip()
        mk = sorted({m for m in mk if m and m.lower() not in ("nan", "none")})
        rec["markers"] = ",".join(mk)
    else:
        rec["markers"] = ""
    # 피로 판정 (분석 가능하면)
    rec.update(_fatigue_verdict(path))
    return rec


def _fatigue_verdict(path: Path) -> dict:
    """fatigue_2sigma 파이프라인으로 M-wave/2σ 판정. 대상 아니면 사유만."""
    try:
        win, st = f2.process(path)
    except f2.SkipFile as e:
        return {"analyzable": False, "skip_reason": str(e)}
    except Exception as e:  # noqa: BLE001
        return {"analyzable": False, "skip_reason": f"오류:{e}"}

    out = {"analyzable": True, "skip_reason": ""}
    if st.get("mw_ok"):
        out["mw_peak_t"] = round(float(st["mw_peak_t"]), 1)
        out["mw_decline_pct"] = round(float(st["mw_decline_pct"]), 1)
        out["mw_saturated"] = bool(st.get("mw_sat"))
        if st["mw_onset_t"] is not None:
            out["verdict"] = "fatigue"
            out["fatigue_onset_t"] = round(float(st["mw_onset_t"]), 1)
        else:
            out["verdict"] = "potentiation"
            out["fatigue_onset_t"] = np.nan
    else:
        out["verdict"] = "no_mwave"
    # RMS/MDF 2σ (참고, 위양성 잦음)
    out["rmsmdf_2sigma_onset_t"] = (
        round(float(st["onset_t"]), 1) if st.get("onset_t") is not None else np.nan)
    return out


def scan_logger(path: Path) -> dict:
    """Logger 계열(구형) 한 세션 요약. M-wave 없음, fatigue_detected 컬럼 사용."""
    df = pd.read_csv(path)
    cols = set(df.columns)
    rec = {
        "n_rows": len(df),
        "has_raw": "emg_raw" in cols,
        "has_env": "emg_env" in cols,
        "has_rms_mdf": {"rms", "mdf"}.issubset(cols),
        "has_mw": False,
        "markers": "",
        "analyzable": False,
        "skip_reason": "logger 계열(M-wave 없음)",
        "verdict": "no_mwave",
    }
    if "timestamp_ms" in cols and len(df) > 1:
        rec["dur_s"] = (df["timestamp_ms"].iloc[-1] - df["timestamp_ms"].iloc[0]) / 1000
    else:
        rec["dur_s"] = 0.0
    if "marker" in cols:
        mk = df["marker"].dropna().astype(str).str.strip()
        mk = sorted({m for m in mk if m and m.lower() not in ("nan", "none")})
        rec["markers"] = ",".join(mk)
    # 펌웨어가 그 자리에서 찍은 fatigue_detected 플래그 개수
    if "fatigue_detected" in cols:
        fd = df["fatigue_detected"].astype(str).str.lower().eq("true").sum()
        rec["fw_fatigue_rows"] = int(fd)
        rec["verdict"] = "fw_fatigue" if fd > 0 else "fw_none"
    return rec


def sampling_hz(dur_s: float, n_rows: int) -> float:
    return round(n_rows / dur_s, 1) if dur_s > 0 else 0.0


def main() -> None:
    ap = argparse.ArgumentParser(description="전체 EMG/FES 세션 마스터 카탈로그")
    ap.add_argument("--out", type=Path, default=ROOT / "dataset_catalog.csv")
    args = ap.parse_args()

    rows = []
    for family, rel in SCAN_DIRS:
        folder = ROOT / rel
        if not folder.exists():
            continue
        for path in sorted(folder.glob("*.csv")):
            try:
                head = pd.read_csv(path, nrows=0).columns
            except Exception as e:  # noqa: BLE001
                print(f"⚠️ 읽기 실패 {path.name}: {e}"); continue
            base = {"family": family, "file": path.name,
                    "path": str(path.relative_to(ROOT))}
            if IPHONE_MARK in head:
                rec = scan_iphone(path)
            elif LOGGER_MARK in head:
                rec = scan_logger(path)
            else:
                rec = {"n_rows": 0, "dur_s": 0, "verdict": "unknown_format",
                       "analyzable": False, "skip_reason": "포맷 미상"}
            rec["sampling_hz"] = sampling_hz(rec.get("dur_s", 0), rec.get("n_rows", 0))
            rows.append({**base, **rec})

    cat = pd.DataFrame(rows)
    # 컬럼 순서 정리
    order = ["family", "file", "dur_s", "n_rows", "sampling_hz",
             "has_raw", "has_env", "has_rms_mdf", "has_mw", "markers",
             "verdict", "fatigue_onset_t", "mw_peak_t", "mw_decline_pct",
             "mw_saturated", "rmsmdf_2sigma_onset_t", "fw_fatigue_rows",
             "analyzable", "skip_reason", "path"]
    cat = cat.reindex(columns=[c for c in order if c in cat.columns])
    cat.to_csv(args.out, index=False)

    # ── 콘솔 요약 ──
    print(f"\n총 세션: {len(cat)}개  →  {args.out}")
    print("\n[계열별]")
    print(cat.groupby("family").agg(
        n=("file", "size"),
        분=("dur_s", lambda s: round(s.sum() / 60, 1)),
        분석가능=("analyzable", lambda s: int(s.sum()) if s.dtype != object else 0),
    ).to_string())

    print("\n[판정 분포]")
    print(cat["verdict"].value_counts().to_string())

    ip = cat[cat["family"].str.startswith("iphone")]
    if len(ip):
        print("\n[iPhone 계열 세션 길이(초)]")
        print(ip["dur_s"].describe().round(1).to_string())
        fat = ip[ip["verdict"] == "fatigue"]
        print(f"\n피로 검출 세션: {len(fat)}/{len(ip)}")
        if len(fat):
            print("  낙폭%  min/median/max: "
                  f"{fat['mw_decline_pct'].min():.0f} / "
                  f"{fat['mw_decline_pct'].median():.0f} / "
                  f"{fat['mw_decline_pct'].max():.0f}")
        print(f"  saturation 세션: {int(ip.get('mw_saturated', pd.Series(dtype=bool)).sum())}")

    # 마커 분포
    allmk = []
    for m in cat["markers"].dropna():
        allmk += [x for x in str(m).split(",") if x]
    if allmk:
        print("\n[마커 분포]")
        print(pd.Series(allmk).value_counts().to_string())


if __name__ == "__main__":
    main()
