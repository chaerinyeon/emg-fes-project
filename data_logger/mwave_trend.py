#!/usr/bin/env python3
"""
mwave_trend.py — raw 1kHz 에서 '진짜 M-wave' 를 복원해 세션 동안의 추세를 본다.

배경(실측으로 확정된 사실):
  - FES 는 32.3Hz(주기 31ms), 1.61초마다 0.49초 버스트로 나간다.
  - 자극 아티팩트는 0~4ms, 근육에서 오는 반응(M-wave)은 5~15ms 에 있다.
    (같은 세션 내 무부하 vs 유부하 비교에서 아티팩트는 -14.5% 로 그대로인데
     5~15ms 만 +102% 로 변해, 그 구간이 근육 신호임이 확인됨)
  - 펌웨어의 실시간 M-wave 검출은 문턱(1000)이 실제 아티팩트보다 높아 자발 EMG 를
    오인하고 있으므로 신뢰할 수 없다 → raw 에서 오프라인으로 다시 구한다.

방법:
  자극 시점에 맞춰 겹쳐 평균(STA). 자극에 동기된 유발반응은 남고, 자극과 무관한
  자발 EMG 는 상쇄된다. 이를 시간 블록마다 반복해 M-wave 크기의 추세를 본다.

피로 판정:
  M-wave 는 보통 초반에 커졌다가(증강/potentiation) 피로가 오면 감소한다.
  아티팩트(0~4ms)는 근육 상태와 무관하므로 '자극이 일정했는지'의 대조군으로 쓴다.
  → 아티팩트는 그대로인데 M-wave 만 줄면 그건 근피로다.

사용: python3 mwave_trend.py <raw.csv> [--block 20]
"""
from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
import pandas as pd

DC_OFFSET = 1862.0
ADC_CEIL = 2233.0        # 12bit ADC 상한 - DC_OFFSET (포화 판정용)
STIM_THRESH = 400.0
STIM_REFRAC = 25         # ms, 자극주기 31ms 보다 짧게
PRE, POST = 5, 28
ART_LO, ART_HI = 0, 4    # 아티팩트 구간(ms) — 자극 세기의 대조군
MW_LO, MW_HI = 5, 15     # M-wave 구간(ms) — 근육 반응


def load_raw(path: Path):
    """raw CSV 로드. 세션 시작 직전의 '이전 세션 잔여 패킷'(인덱스가 뒤로 감)을 제거."""
    d = pd.read_csv(path)
    t = d["Time(ms)"].to_numpy()
    c = d["Raw_ADC"].to_numpy(dtype=float) - DC_OFFSET
    back = np.where(np.diff(t) < 0)[0]
    if len(back):
        cut = back[-1] + 1
        t, c = t[cut:], c[cut:]
        print(f"  (이전 세션 잔여 {cut}행 제거)")
    return t, c


def find_stim(c: np.ndarray) -> np.ndarray:
    idx = np.where(np.abs(c) > STIM_THRESH)[0]
    out, last = [], -10_000
    for i in idx:
        if i - last >= STIM_REFRAC:
            out.append(i)
            last = i
    return np.array(out)


def sta(c: np.ndarray, sel: np.ndarray):
    segs = np.array([c[s - PRE:s + POST] for s in sel
                     if s >= PRE and s + POST < len(c)])
    if len(segs) == 0:
        return None, 0
    return segs.mean(axis=0), len(segs)


def amp(avg: np.ndarray, tt: np.ndarray, lo: int, hi: int) -> float:
    m = (tt >= lo) & (tt <= hi)
    return float(avg[m].max() - avg[m].min())


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("raw", type=Path)
    ap.add_argument("--block", type=float, default=20.0, help="블록 길이(초)")
    args = ap.parse_args()

    print(f"=== {args.raw.name} ===")
    t, c = load_raw(args.raw)
    dur = len(c) / 1000.0
    stim = find_stim(c)
    sat = (np.abs(c) >= ADC_CEIL).mean() * 100
    print(f"  {dur:.0f}초, 자극 {len(stim):,}개, 포화 {sat:.2f}%")

    tt = np.arange(-PRE, POST)
    blk = int(args.block * 1000)
    rows = []
    for lo in range(0, len(c) - blk + 1, blk):
        sel = stim[(stim >= lo + PRE) & (stim < lo + blk - POST)]
        if len(sel) < 20:
            continue
        avg, n = sta(c, sel)
        if avg is None:
            continue
        rows.append({
            "t": (lo + blk / 2) / 1000.0,
            "art": amp(avg, tt, ART_LO, ART_HI),
            "mw": amp(avg, tt, MW_LO, MW_HI),
            "n": n,
        })
    df = pd.DataFrame(rows)
    if df.empty:
        print("  블록이 부족해 추세를 낼 수 없음")
        return

    # 기준: 첫 블록 대비 %
    base_mw = df["mw"].iloc[0]
    base_art = df["art"].iloc[0]
    df["mw_pct"] = df["mw"] / base_mw * 100
    df["art_pct"] = df["art"] / base_art * 100

    print(f"\n=== {args.block:.0f}초 블록별 (첫 블록 대비 %) ===")
    print("   시각    아티팩트      M-wave     겹침")
    for _, r in df.iterrows():
        bar = "#" * int(max(0, r["mw_pct"]) / 8)
        print(f"  {r['t']:5.0f}초  {r['art_pct']:6.1f}%   {r['mw_pct']:6.1f}%  {r['n']:5.0f}  {bar}")

    # 추세 (Spearman)
    def rho(x, y):
        xr = pd.Series(x).rank().to_numpy()
        yr = pd.Series(y).rank().to_numpy()
        xr = xr - xr.mean()
        yr = yr - yr.mean()
        d = np.sqrt((xr ** 2).sum() * (yr ** 2).sum())
        return float((xr * yr).sum() / d) if d > 0 else np.nan

    r_mw = rho(df["t"], df["mw"])
    r_art = rho(df["t"], df["art"])
    peak_i = int(df["mw"].idxmax())
    print(f"\n=== 추세 ===")
    print(f"  아티팩트 : 시간상관 ρ={r_art:+.2f}   (자극이 일정했는지의 대조군)")
    print(f"  M-wave   : 시간상관 ρ={r_mw:+.2f}")
    print(f"  M-wave 정점 : {df['t'].iloc[peak_i]:.0f}초 ({df['mw_pct'].iloc[peak_i]:.0f}%)")
    print(f"  마지막 블록 : {df['mw_pct'].iloc[-1]:.0f}%  (정점 대비 "
          f"{df['mw'].iloc[-1]/df['mw'].iloc[peak_i]*100-100:+.0f}%)")

    print(f"\n=== 해석 ===")
    art_stable = abs(r_art) < 0.5
    if not art_stable:
        print(f"  ⚠️ 아티팩트가 시간에 따라 변함(ρ={r_art:+.2f}) → 자극/전극이 안 일정.")
        print("     M-wave 변화를 근피로로 단정할 수 없음.")
    elif r_mw < -0.5:
        print("  ✅ 자극(아티팩트)은 일정한데 M-wave 만 감소 → 근피로의 근거")
    elif r_mw > 0.5:
        print("  ↗ M-wave 가 증가 중(증강/potentiation) → 아직 피로 아님")
    else:
        print("  → M-wave 에 뚜렷한 추세 없음 (이 세션에선 피로 미검출)")



if __name__ == "__main__":
    main()
