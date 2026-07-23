#!/usr/bin/env python3
"""spc_multi_raw.py — spc_multi.py 와 같은 그림을 '최근 raw/STA 지표'로 다시 그린다.

spc_multi 는 옛 env(폰이 해석한 포락선) 기반 RMS·MDF·M-wave 5신호였다.
이건 raw 1kHz 파형에서 raw_full_analysis 의 검출·STA·창실측을 재사용해
아래 신호를 슬라이딩창(6s, 1s step)으로 뽑아 같은 방식으로 본다.

  R    = M-wave ÷ 자극스파이크   (전극이득 약분; 최근 검증된 핵심 지표)  피로=하강
  진폭  = M-wave 창 평균                                              피로=하강
  면적  = M-wave 창 Σ|.|                                              피로=하강
  잠복기 = M-wave 정점까지 시간(ms)                                    피로=상승
  대조군 = 자극 스파이크(0~1ms) 크기  — 근육이 못 만드는 순수 전극신호   (평평해야 정상)

방법(= spc_multi 동일):
  · 각 신호를 자기 '기준선'의 평균 ± 2σ 로 표준화(z). 피로방향으로 +z.
    기준선: M-wave 계열(R·진폭·면적)은 증강 정점(플래토), 잠복/대조군은 초반 20s.
  · z>2 가 5초 이상 지속되면 '온셋'. 그 신호가 혼자서 2σ 를 넘긴 세션만 모은다.
  · 각 세션의 z 를 자기 온셋(t=0)에 맞춰 겹치고 평균.
  · 대조군 패널만은 R 의 온셋에 맞춰 겹친다 → R 이 내려가는 그 순간에
    전극(대조군)은 평평한가? 를 직접 보여준다.

사용: python3 spc_multi_raw.py [--root ~/emgfes-data]
"""
from __future__ import annotations
import argparse
import sys
from pathlib import Path
import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent))
import raw_full_analysis as RF

FS = RF.FS
PRE, POST = RF.STA_PRE, RF.STA_POST
LAT_LO, LAT_HI = RF.LAT_LO, RF.LAT_HI

WIN_S = 6.0            # 슬라이딩창 폭(초) — 창 안 펄스들로 지표 1점
STEP_S = 1.0           # 창 이동 간격(초) → 1Hz 시계열
MIN_PULSE_WIN = 25     # 창 안 최소 펄스 수(모자라면 결측)
SMOOTH_N = 3           # 시계열 이동평균 창(점)
SIGMA = 2.0
SUSTAIN_S = 5.0        # z>2 가 이만큼 연속돼야 온셋
GRID = np.arange(-40, 10.1, 1.0)
PLATEAU_FRAC = 0.65    # 증강 정점은 세션 앞 65% 안에서 찾는다(끝 아티팩트 배제)
PLATEAU_HALF = 3       # 정점 ±이 점수 = 플래토 기준선
EARLY_S = 20.0         # 잠복/대조군 기준선 = 초반 이 시간

# (key, 표시명, 피로방향, 기준선종류, 색)
SIGS = [
    ("R",    "R = M-wave ÷ 자극(정규화)", "down", "plateau", "crimson"),
    ("mw",   "M-wave 진폭",              "down", "plateau", "C0"),
    ("area", "M-wave 면적",              "down", "plateau", "C1"),
    ("lat",  "M-wave 잠복기",            "up",   "early",   "C3"),
    ("art",  "대조군 (자극 스파이크)",     "down", "control", "gray"),
]


def smooth(y):
    return pd.Series(y).rolling(SMOOTH_N, center=True, min_periods=1).mean().to_numpy()


def series(path: Path):
    """세션 → 슬라이딩창 지표 시계열 (게이트 통과 못 하면 None)."""
    x, absr, dc, dropped, clip, v = RF.load_raw(path)
    bursts = RF.find_bursts(absr)
    if len(bursts) < RF.MIN_BURSTS:
        return None
    period = float(np.median(np.diff([a for a, _ in bursts])))
    if not (RF.PERIOD_LO <= period <= RF.PERIOD_HI):
        return None
    pulses = RF.refine_pulses(x, RF.find_pulses(absr))
    sta, seg, sel, info = RF.build_sta(x, pulses)
    if sta is None:
        return None
    win = RF.measure_window(sta, seg)
    if not win or win["sta_ratio"] < RF.STA_RATIO_GATE:
        return None
    lo, hi = win["mw_lo"], win["mw_hi"]          # 펄스 t=0 기준 ms 오프셋

    # 대조군 포화(레일에 닿은 스파이크 비율) — R 해석 가능 여부
    railed = [(v[p:p + RF.ART_HI] <= RF.ADC_MIN).any() or
              (v[p:p + RF.ART_HI] >= RF.ADC_MAX).any()
              for p in sel if p + RF.ART_HI <= len(v)]
    r_ok = (np.mean(railed) * 100 <= RF.CLIP_GATE) if railed else False

    # 창 밖(양끝 POST) 넘어가지 않는 펄스만
    sel = sel[(sel >= PRE) & (sel < len(x) - POST)]
    ts = sel / FS
    dur = len(absr) / FS
    centers = np.arange(WIN_S / 2, dur - WIN_S / 2 + 1e-9, STEP_S)

    tg, A, M, Ar, L = [], [], [], [], []
    for c in centers:
        m = (ts >= c - WIN_S / 2) & (ts < c + WIN_S / 2)
        ps = sel[m]
        tg.append(c)
        if len(ps) < MIN_PULSE_WIN:
            A.append(np.nan); M.append(np.nan); Ar.append(np.nan); L.append(np.nan)
            continue
        art = float(np.mean([absr[s:s + RF.ART_HI].max() for s in ps]))
        mw = float(np.mean([absr[s + lo:s + hi].mean() for s in ps]))
        area = float(np.mean([absr[s + lo:s + hi].sum() for s in ps]))
        staw = np.stack([x[s - PRE:s + POST] for s in ps]).mean(0)
        seg_a = np.abs(staw[PRE + LAT_LO:PRE + LAT_HI])
        lat = float(np.argmax(seg_a) + LAT_LO) if seg_a.max() > 0 else np.nan
        A.append(art); M.append(mw); Ar.append(area); L.append(lat)

    return dict(
        session=path.name.replace("raw_", "").replace(".csv", ""),
        r_ok=r_ok, t=np.array(tg), dur=dur,
        art=np.array(A), mw=np.array(M), area=np.array(Ar), lat=np.array(L),
        R=np.array(M) / np.array(A),
    )


def make_z(t, y, direction, base_kind, dur):
    """신호 → 피로방향 z, 기준선 종료시각(온셋은 그 이후만)."""
    ys = smooth(y)
    fin = np.isfinite(ys)
    if fin.sum() < 8:
        return None, None
    if base_kind == "plateau":
        valid = fin & (t <= PLATEAU_FRAC * dur)
        if valid.sum() < 5:                       # 증강 없음 → 초반으로 폴백
            base_kind = "early"
        else:
            idx = np.where(valid)[0]
            kp = idx[int(np.argmax(ys[idx]))]     # 증강 정점
            b0, b1 = max(0, kp - PLATEAU_HALF), min(len(t), kp + PLATEAU_HALF + 1)
            bmask = np.zeros(len(t), bool); bmask[b0:b1] = True
            bmask &= fin
            base_end = float(t[min(b1 - 1, len(t) - 1)])
    if base_kind in ("early", "control"):
        bmask = fin & (t <= EARLY_S)
        base_end = EARLY_S
    b = ys[bmask]
    if len(b) < 5:
        return None, None
    mu, sd = float(np.mean(b)), float(np.std(b))
    sd = max(sd if sd > 0 else 0.0, 0.05 * abs(mu))
    if sd <= 0:
        return None, None
    z = (ys - mu) / sd if direction == "up" else (mu - ys) / sd
    return z, base_end


def find_onset(t, z, base_end):
    need = max(2, round(SUSTAIN_S / STEP_S))
    run = 0
    for i in range(len(z)):
        if t[i] <= base_end:
            run = 0; continue
        run = run + 1 if (np.isfinite(z[i]) and z[i] > SIGMA) else 0
        if run >= need:
            return float(t[i - need + 1])
    return None


def aligned(t, z, onset):
    rel = t - onset
    m = np.isfinite(z) & (rel >= GRID[0] - 1) & (rel <= GRID[-1] + 1)
    if m.sum() < 4:
        return None
    return np.interp(GRID, rel[m], z[m], left=np.nan, right=np.nan)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", type=Path, default=Path.home() / "emgfes-data")
    args = ap.parse_args()
    sess = [s for s in (series(f) for f in sorted(args.root.glob("**/raw_*.csv"))) if s]
    print(f"raw 세션 {len(sess)}개 (G1+STA 통과)\n")

    stacks = {k[0]: [] for k in SIGS}
    onsets = {}                            # session -> {key: onset}
    fired = {}                             # session -> set(key)
    for s in sess:
        onsets[s["session"]] = {}
        for key, disp, direction, base_kind, _ in SIGS:
            if key == "art":
                continue               # 대조군은 R 온셋에 맞춰 뒤에서 따로
            if key == "R" and not s["r_ok"]:
                continue               # 대조군 포화 → R 해석 불가
            z, be = make_z(s["t"], s[key], direction, base_kind, s["dur"])
            if z is None:
                continue
            on = find_onset(s["t"], z, be)
            if on is None:
                continue
            onsets[s["session"]][key] = on
            fired.setdefault(s["session"], set()).add(key)
            a = aligned(s["t"], z, on)
            if a is not None:
                stacks[key].append(a)

    # 대조군: R 이 온셋난 세션에서, 그 R 온셋에 맞춰 art z 겹침
    for s in sess:
        onR = onsets[s["session"]].get("R")
        if onR is None:
            continue
        z, _ = make_z(s["t"], s["art"], "down", "control", s["dur"])
        if z is None:
            continue
        a = aligned(s["t"], z, onR)
        if a is not None:
            stacks["art"].append(a)

    # ---- 콘솔 표 ----
    print("[신호별 '혼자 2σ 5초지속' 온셋 세션 수]")
    for key, disp, *_ in SIGS:
        note = "  (R 온셋에 정렬)" if key == "art" else ""
        print(f"  {disp:26s}: {len(stacks[key]):2d}세션{note}")

    only = {k[0]: [] for k in SIGS}
    combos = {}
    for name, fs in fired.items():
        if len(fs) == 1:
            only[list(fs)[0]].append(name)
        key = "+".join(d for c, d, *_ in SIGS if c in fs)
        combos[key] = combos.get(key, 0) + 1
    print("\n['이 신호에서만' 피로 잡힌 세션]")
    for key, disp, *_ in SIGS:
        if key == "art":
            continue
        n = only[key]
        print(f"  {disp:26s} 만: {len(n)}세션" + (f"  ({', '.join(n)})" if n else ""))
    print("\n[잡힌 신호 조합 분포]")
    for k, v in sorted(combos.items(), key=lambda x: -x[1]):
        print(f"  {v}세션: {k or '(없음)'}")

    # ---- 플롯 ----
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    plt.rcParams["font.family"] = "AppleGothic"
    plt.rcParams["axes.unicode_minus"] = False
    fig, axes = plt.subplots(2, 3, figsize=(16, 8.5))
    axl = axes.flatten()
    for ax, (key, disp, direction, base_kind, color) in zip(axl, SIGS):
        arr = [a for a in stacks[key] if a is not None]
        for row in arr:
            ax.plot(GRID, row, color=color, alpha=0.28, lw=0.9)
        if arr:
            with np.errstate(all="ignore"):
                mean = np.nanmean(np.vstack(arr), axis=0)
            ax.plot(GRID, mean, color=color, lw=2.8, label=f"평균 (n={len(arr)})")
        ax.axhline(SIGMA, ls="--", color="red", alpha=.8, label=f"{SIGMA:.0f}σ")
        ax.axhline(0, color="black", lw=.4)
        ax.axvline(0, color="black", lw=.8)
        ax.set_ylim(-4, 8)
        sub = "R 온셋 기준" if key == "art" else "혼자 2σ 5초지속"
        ax.set_title(f"{disp} — {sub}", fontsize=10.5)
        ax.set_xlabel("온셋 기준 시간(초)")
        ax.set_ylabel("피로방향 z")
        ax.legend(loc="upper left", fontsize=8)
        ax.grid(alpha=.2)
    axl[5].axis("off")
    axl[5].text(0.02, 0.95,
                "raw 1kHz 파형 → 자극펄스 검출 → STA 정렬로\n"
                "M-wave 창 실측(세션별 잠복 다름)\n\n"
                "6초 슬라이딩창(1초 step)으로 신호 1점씩\n\n"
                "각 신호를 자기 기준선 평균±2σ 로 z 화\n"
                " · M-wave 계열: 증강 정점(플래토) 기준\n"
                " · 잠복/대조군: 초반 20초 기준\n\n"
                "z>2 가 5초 지속 = 온셋(0). 그 세션들을\n"
                "온셋에 맞춰 겹치고 평균 (n=세션수)\n\n"
                "대조군 패널: R 온셋에 맞춰 겹침 →\n"
                "R 이 내려갈 때 전극(대조군)은 평평한가?",
                fontsize=9.5, va="top", transform=axl[5].transAxes)
    fig.suptitle("신호별 개별 2σ SPC (raw/STA 지표) — 여러 세션", fontsize=13)
    fig.tight_layout()
    out = Path(__file__).parent / "spc_multi_raw.png"
    fig.savefig(out, dpi=120)
    print(f"\n그래프 저장 → {out}")


if __name__ == "__main__":
    main()
