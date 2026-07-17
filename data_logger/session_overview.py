#!/usr/bin/env python3
"""
session_overview.py — 한 세션의 세 신호를 '자극을 걷어낸 뒤' 시간축 전체로 본다.

왜 이렇게 뽑는가 (실측으로 확정된 사실):
  - FES 는 32.3Hz(주기 31ms), 1.61초마다 0.49초 버스트.
  - 0~4ms = 자극 아티팩트(근육과 무관한 순수 전기신호)
    5~15ms = M-wave(근육 유발반응)   16~30ms = 자발 EMG 만 있는 깨끗한 창
  - 펌웨어의 RMS/MDF/M-wave 는 자극에 파묻혀 추세가 안 나온다.
    → raw 1kHz 에서 위 시간 구조대로 분리해 다시 구한다.

세 신호와 피로 방향:
  M-wave  ↓ 감소 = 피로 (근섬유 흥분성 저하)
  RMS     ↑ 증가 = 피로 (같은 힘 유지하려 운동단위 추가 동원)
  MDF     ↓ 하강 = 피로 (전도속도 저하)

아티팩트는 근육 상태와 무관하므로 '자극이 일정했는지' 대조군으로 함께 낸다.
아티팩트가 변하면 전극·자극이 흔들린 것이라 나머지 해석을 신뢰할 수 없다.
M-wave 는 아티팩트로 나눠 전극 변화를 보정한다.

세 신호는 기준 대비 % 로 지수화해 비교한다.
기준 = 유부하 시작 직후 첫 블록(무부하 구간은 조건이 달라 기준으로 못 씀).

주의 — 파라미터는 데이터를 보기 '전'에 정한다:
  블록 크기와 분석 구간을 결과를 본 뒤 고르면 편향이 생긴다. 실제로 '정점 이후만'
  + '20초 블록' 조합에선 ρ=-0.76 이, 편향 없는 '유부하 전 구간' + '10초 블록'
  에선 ρ=-0.25 가 나왔다(같은 데이터). 기본값을 바꾸려면 근거를 남길 것.

사용: python3 session_overview.py <raw.csv> [--env <env.csv>] [--block 10]
"""
from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
import pandas as pd

DC_OFFSET = 1862.0
ADC_CEIL = 2233.0
STIM_THRESH = 400.0
STIM_REFRAC = 25
PRE, POST = 5, 28
ART_LO, ART_HI = 0, 4      # 아티팩트 = 자극 세기 대조군
MW_LO, MW_HI = 5, 15       # M-wave = 근육 유발반응
VOL_LO, VOL_HI = 16, 30    # 자발 EMG 만 있는 깨끗한 창
# 실측 자극 기본주파수. 32.26 은 틀린 값이었다 — ISI '중앙값' 31ms 에서 1000/31=32.258 로
# 나온 1ms 양자화 착시다. 진짜는 ISI '평균' 31.185ms → 32.078Hz.
# 60초 FFT(분해능 0.017Hz)에서 배음 봉우리가 64.2·96.2·128.3·…·449.1Hz, 간격 32.08Hz 로 확인.
# 오차 0.182×k 라 32.26 을 쓰면 k=14 에서 2.55Hz 어긋나 ±2Hz 노치가 놓친다.
# 노치가 걷어내는 대역전력: 32.078 이면 81.1%, 32.26 이면 68.9%.
F0 = 32.078
NFFT = 512


def load_raw(path: Path):
    d = pd.read_csv(path)
    t = d["Time(ms)"].to_numpy()
    c = d["Raw_ADC"].to_numpy(dtype=float) - DC_OFFSET
    back = np.where(np.diff(t) < 0)[0]
    if len(back):                      # 이전 세션 잔여 패킷 제거
        c = c[back[-1] + 1:]
    return c


def find_stim(c):
    idx = np.where(np.abs(c) > STIM_THRESH)[0]
    out, last = [], -10_000
    for i in idx:
        if i - last >= STIM_REFRAC:
            out.append(i)
            last = i
    return np.array(out)


def mdf_mask():
    fr = np.fft.rfftfreq(NFFT, 1 / 1000)
    band = (fr >= 20) & (fr <= 450)
    notch = np.zeros(len(fr), bool)
    for k in range(1, 15):             # 자극 배음 제거 — MDF 대역 전력의 85% 를 차지
        if F0 * k > 450:
            break
        notch |= (fr >= F0 * k - 2) & (fr <= F0 * k + 2)
    for fh in (60, 120, 180):          # 전원 노이즈
        notch |= (fr >= fh - 2) & (fr <= fh + 2)
    return fr, band & ~notch


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("raw", type=Path)
    ap.add_argument("--env", type=Path, default=None)
    ap.add_argument("--block", type=float, default=10.0)
    ap.add_argument("--rest-end", type=float, default=15.1, help="무부하 구간 끝(초)")
    args = ap.parse_args()

    c = load_raw(args.raw)
    stim = find_stim(c)
    fr, use = mdf_mask()
    win = np.hamming(NFFT)
    tt = np.arange(-PRE, POST)
    blk = int(args.block * 1000)

    # 자발 EMG 창 마스크
    vol = np.zeros(len(c), bool)
    for s in stim:
        lo, hi = s + VOL_LO, min(s + VOL_HI + 1, len(c))
        if hi > lo:
            vol[lo:hi] = True

    def amp(m, lo, hi):
        k = (tt >= lo) & (tt <= hi)
        return float(m[k].max() - m[k].min())

    rows = []
    for lo in range(0, len(c) - blk + 1, blk):
        sel = stim[(stim >= lo + PRE) & (stim < lo + blk - POST)]
        if len(sel) < 10:
            continue
        segs = np.array([c[s - PRE:s + POST] for s in sel])
        m = segs.mean(axis=0)
        art, mw = amp(m, ART_LO, ART_HI), amp(m, MW_LO, MW_HI)

        seg, mm = c[lo:lo + blk], vol[lo:lo + blk]
        v = seg[mm]
        rms = float(np.sqrt(((v - v.mean()) ** 2).mean())) if mm.sum() > 200 else np.nan

        mdfs = []
        for i in range(0, blk - NFFT, 250):
            s = seg[i:i + NFFT]
            s = s - s.mean()
            P = np.abs(np.fft.rfft(s * win)) ** 2
            p, f = P[use], fr[use]
            if p.sum() > 0:
                cum = np.cumsum(p)
                mdfs.append(f[np.searchsorted(cum, cum[-1] / 2)])
        rows.append({"t": (lo + blk / 2) / 1000.0, "art": art, "mw": mw,
                     "mw_n": mw / art if art > 0 else np.nan,
                     "rms": rms, "mdf": np.nanmedian(mdfs) if mdfs else np.nan})

    df = pd.DataFrame(rows)
    # 기준 = 유부하 시작 직후 첫 블록 (무부하 구간은 조건이 달라 기준으로 못 씀)
    base_i = int((df["t"] > args.rest_end + args.block).idxmax())
    b = df.iloc[base_i]
    for k, col in (("mw_n", "mw_pct"), ("rms", "rms_pct"), ("mdf", "mdf_pct"),
                   ("art", "art_pct")):
        df[col] = df[k] / b[k] * 100

    sat = (np.abs(c) >= ADC_CEIL).mean() * 100
    print(f"=== {args.raw.name} ===")
    print(f"  {len(c)/1000:.0f}초, 자극 {len(stim):,}개, 포화 {sat:.2f}%")
    print(f"  기준 블록 = {b['t']:.0f}초 (유부하 시작 직후)")

    def rho(x, y):
        m = np.isfinite(x) & np.isfinite(y)
        x, y = np.asarray(x)[m], np.asarray(y)[m]
        xr = pd.Series(x).rank().to_numpy() - (len(x) + 1) / 2
        yr = pd.Series(y).rank().to_numpy() - (len(y) + 1) / 2
        d = np.sqrt((xr ** 2).sum() * (yr ** 2).sum())
        return float((xr * yr).sum() / d) if d > 0 else np.nan

    print(f"\n=== {args.block:.0f}초 블록별 (유부하 시작 대비 %) ===")
    print("   시각   M-wave  자발RMS     MDF   [대조군]아티팩트")
    for _, r in df.iterrows():
        print(f"  {r['t']:5.0f}초  {r['mw_pct']:6.1f}  {r['rms_pct']:6.1f}  "
              f"{r['mdf_pct']:6.1f}   {r['art_pct']:6.1f}")

    w = df[df["t"] > args.rest_end]
    print(f"\n  유부하 구간 추세 (ρ):")
    print(f"    M-wave (÷아티팩트) : {rho(w['t'], w['mw_n']):+.2f}   (피로면 −)")
    print(f"    자발 EMG RMS       : {rho(w['t'], w['rms']):+.2f}   (피로면 +)")
    print(f"    MDF (배음제거)     : {rho(w['t'], w['mdf']):+.2f}   (피로면 −)")
    print(f"    아티팩트 [대조군]  : {rho(w['t'], w['art']):+.2f}   (0 에 가까워야 신뢰)")

    # 대조군 검사 — 아티팩트는 근육과 무관하므로 평평해야 한다.
    # 여기가 흔들리면 전극·자극이 변한 것이라 위 추세를 피로로 해석할 수 없다.
    r_art = rho(w["t"], w["art"])
    if abs(r_art) >= 0.5:
        print(f"\n  ⚠️ 대조군 실패: 아티팩트가 시간에 따라 변함(ρ={r_art:+.2f}).")
        print("     전극 접촉/자극 전달이 흔들렸다는 뜻 → 위 추세를 근피로로 해석할 수 없음.")


if __name__ == "__main__":
    main()
