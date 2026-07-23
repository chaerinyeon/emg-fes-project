#!/usr/bin/env python3
"""raw_fatigue_flow.py — RMS·MDF·M-wave(진폭 R) 외에, 세션에 공통인 피로 '흐름'이
있는지 본다. raw_full_analysis.py 의 검출·정렬·게이트를 재사용한다.

배경: raw_full_analysis 는 '단조 감소'만 피로로 인정해 17세션 중 141940 하나만
남겼다. 하지만 진짜 근육 신호는 직선이 아니라 산(hump)일 수 있다 —
post-activation potentiation(초반 증강) 뒤 fatigue(후반 감소). 단조 게이트는
이 산의 앞부분(증강) 때문에 상관이 0 근처로 나와 놓친다.

두 축으로 검증한다.
 1) 형태(모양·타이밍) 특징 — 전극 이득과 무관(gain-independent)해서 R 이 못 쓴
    포화·불안정 세션도 쓸 수 있다. 각각 세션 내 추세가 '공통 방향'인지 센다.
       lat   M-wave 잠복(ms, 포물선보간)   전도속도↓ → 증가 예측
       dur   M-wave 폭(50%, ms, 선형보간)  시간분산  → 증가 예측
       fc    M-wave 주파수중심(Hz, 스파이크 제외)  파형느려짐 → 하강 예측
       npk   M-wave 창 부호변화 수          다상성    → 증가 예측
    → 결과적으로 어느 것도 공통 방향이 없다(세션마다 제각각). 새 스칼라 지표는 없다.
 2) 궤적 '흐름' — mw(진폭)·R(mw/art) 을 상대시간 0~100%로 리샘플해 겹치고 평균.
    삼분할(초/중/말)·자기정점대비 후반하강으로 산(증강→피로)을 판정.
    → 세션 평균이 +~24%p 증강 후 -~23%p 피로. R(이득약분)에서도 남으므로
      자극드리프트 아티팩트가 아니다. '증강 후 피로'가 공통 흐름이다.

사용: python3 raw_fatigue_flow.py [--plot]
"""
from __future__ import annotations
import argparse
import sys
from collections import Counter
from pathlib import Path
import numpy as np, pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent))
import raw_full_analysis as RF

FS = RF.FS
PRE, POST = RF.STA_PRE, RF.STA_POST
LAT_LO, LAT_HI = RF.LAT_LO, RF.LAT_HI
BLK_TARGET = 14
MIN_PULSE_BLK = 30
GRID = np.linspace(0, 1, 21)


# --------------------------------------------------------------- 형태 특징
def feats(sta: np.ndarray) -> dict | None:
    """블록 STA → gain-independent 형태 특징 (lat/dur/fc/npk)."""
    o = PRE
    lo, hi = o + LAT_LO, o + LAT_HI
    a = np.abs(sta[lo:hi])
    if not len(a) or a.max() <= 0:
        return None
    k = int(np.argmax(a)) + lo
    pk = abs(sta[k])
    # 잠복: 정점 포물선 보간으로 sub-ms (1kHz 양자화 완화)
    if 0 < k < len(sta) - 1:
        y0, y1, y2 = abs(sta[k-1]), abs(sta[k]), abs(sta[k+1])
        den = y0 - 2*y1 + y2
        delta = 0.5*(y0 - y2)/den if den != 0 else 0.0
    else:
        delta = 0.0
    lat = (k + delta) - o
    # 폭: 정점 50% 교차 선형보간
    half = 0.5*pk
    li = k
    while li > lo and abs(sta[li]) >= half:
        li -= 1
    ri = k
    while ri < hi-1 and abs(sta[ri]) >= half:
        ri += 1
    def cross(i, j):
        yi, yj = abs(sta[i]), abs(sta[j])
        return i + (half-yi)/(yj-yi) if yj != yi else float(i)
    left = cross(li, li+1) if li >= lo else float(lo)
    right = cross(ri, ri-1) if ri <= hi-1 else float(hi-1)
    dur = right - left
    # M-wave 주파수중심 (스파이크 제외, 3~25ms 창만)
    w = sta[o+LAT_LO:o+LAT_HI].astype(float).copy(); w -= w.mean()
    if np.any(w):
        sp = np.abs(np.fft.rfft(w*np.hanning(len(w))))**2
        fr = np.fft.rfftfreq(len(w), 1.0/FS)
        fc = float((fr*sp).sum()/sp.sum()) if sp.sum() > 0 else np.nan
    else:
        fc = np.nan
    npk = int((np.diff(np.sign(sta[lo:hi])) != 0).sum())
    return dict(lat=lat, dur=dur, fc=fc, npk=npk)


# --------------------------------------------------------------- 궤적 흐름
def resample(t, y):
    t = np.asarray(t, float); y = np.asarray(y, float)
    if len(t) < 3 or t[-1] <= t[0] or y[0] == 0:
        return None
    tn = (t - t[0])/(t[-1] - t[0])
    return np.interp(GRID, tn, y/y[0]*100)


def thirds(y):
    """초/중/말 중앙값(초기=100 기준)으로 산/감소/증가/평탄 분류.
    argmax 는 늘 양끝보다 크므로 자명하다 → 독립인 세 구간 집계로 본다."""
    y = np.asarray(y, float); n = len(y); t = n//3
    e = float(np.median(y[:t])); m = float(np.median(y[t:2*t])); l = float(np.median(y[2*t:]))
    if e <= 0:
        return None
    m_, l_ = m/e*100, l/e*100
    M = 8.0
    if (m_ > 100+M) and (m_ > l_+M):
        cls = "증강→피로(산)"
    elif l_ < 100-M:
        cls = "단조감소"
    elif l_ > 100+M:
        cls = "단조증가"
    else:
        cls = "평탄"
    return dict(e=100.0, m=m_, l=l_, cls=cls)


def peak_fat(y):
    """자기 정점(내부) 대비 후반 하강 = 피로상. 정점 위치는 세션마다 달라도
    정점 이후 내려가는가는 단조게이트가 못 보던 공통 피로신호."""
    s = pd.Series(y).rolling(3, center=True, min_periods=1).mean().to_numpy()
    s = s/s[0]*100
    kp = int(np.argmax(s))
    interior = 1 <= kp <= len(s)-3
    drop = (s[-1]/s[kp] - 1)*100
    return kp/(len(s)-1), float(s[kp]), float(s[-1]), drop, interior


# --------------------------------------------------------------- 세션 분석
def analyze(path: Path):
    x, absr, dc, dropped, clip, v = RF.load_raw(path)
    bursts = RF.find_bursts(absr)
    pulses = RF.refine_pulses(x, RF.find_pulses(absr))
    if len(bursts) < RF.MIN_BURSTS:
        return None
    period = float(np.median(np.diff([a for a, _ in bursts])))
    if not (RF.PERIOD_LO <= period <= RF.PERIOD_HI):
        return None
    sta, seg, sel, info = RF.build_sta(x, pulses)
    if sta is None:
        return None
    win = RF.measure_window(sta, seg)
    if not win or win["sta_ratio"] < RF.STA_RATIO_GATE:
        return None
    railed = [(v[p:p+2] <= RF.ADC_MIN).any() or (v[p:p+2] >= RF.ADC_MAX).any()
              for p in pulses if p+2 <= len(v)]
    clip_pct = float(np.mean(railed)*100) if railed else np.nan

    dec = RF.decompose(absr, sel, win)
    if len(dec) < 8:
        return None
    n = len(absr)
    blk = int(np.clip(n/BLK_TARGET, RF.BLOCK_MIN_S*FS, RF.BLOCK_MAX_S*FS))
    frows = []
    for lo in range(0, n-blk+1, blk):
        ps = sel[(sel >= lo+PRE) & (sel < lo+blk) & (sel < n-POST)]
        if len(ps) < MIN_PULSE_BLK:
            continue
        bs = np.stack([x[s-PRE:s+POST] for s in ps]).mean(0)
        f = feats(bs)
        if f:
            f["t_s"] = (lo+blk/2)/FS
            frows.append(f)
    fdf = pd.DataFrame(frows)

    out = dict(session=path.name.replace("raw_", "").replace(".csv", ""),
               clip=clip_pct, r_ok=clip_pct <= RF.CLIP_GATE, n_block=len(dec),
               t=dec["t_s"].to_numpy(), mw=dec["mw"].to_numpy(), Rv=dec["R"].to_numpy(),
               fdf=fdf)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", type=Path, default=Path.home()/"emgfes-data")
    ap.add_argument("--plot", action="store_true")
    args = ap.parse_args()
    res = [r for r in (analyze(f) for f in sorted(args.root.glob("**/raw_*.csv"))) if r]
    print(f"흐름 분석 세션 {len(res)}개 (G1+STA정렬 통과; 포화 무관)\n")

    # ---- 1) 형태 특징: 공통 방향이 있는가 ----
    print("=== 1) gain-independent 형태특징의 세션 내 추세 (ρ=시간상관) ===")
    print(f"{'세션':<16}{'대조군':>6}{'잠복ρ':>8}{'폭ρ':>8}{'fcρ':>8}{'다상ρ':>8}")
    trend_rho = {c: [] for c in ("lat", "dur", "fc", "npk")}
    for r in res:
        d = r["fdf"]
        if len(d) < 8:
            continue
        rr = {}
        for c in ("lat", "dur", "fc", "npk"):
            rho = RF.spearman(d["t_s"].to_numpy(), d[c].to_numpy())
            rr[c] = rho
            if not np.isnan(rho):
                trend_rho[c].append(rho)
        print(f"{r['session']:<16}{'평' if r['r_ok'] else '포화':>6}"
              f"{rr['lat']:>+8.2f}{rr['dur']:>+8.2f}{rr['fc']:>+8.2f}{rr['npk']:>+8.2f}")
    print("\n  공통 방향성 (|ρ|≥0.5 세션 수):")
    for c, lab, pred in (("lat", "잠복", "증가"), ("dur", "폭", "증가"),
                         ("fc", "주파수중심", "하강"), ("npk", "다상성", "증가")):
        a = np.array(trend_rho[c])
        print(f"    {lab:<6} ↑{int((a>=0.5).sum())} ↓{int((a<=-0.5).sum())} "
              f"→{int((np.abs(a)<0.5).sum())}   중앙ρ={np.median(a):+.2f}  (피로예측 {pred})")
    print("  → 어느 특징도 공통 방향 없음. 진폭 R 을 대체할 단일 스칼라는 없다.")

    # ---- 2) 궤적 흐름: 증강 후 피로 ----
    print("\n=== 2) 궤적 흐름 — 삼분할(초/중/말 %, 초기=100) ===")
    print(f"{'세션':<16}{'신호':>5}{'초':>5}{'중':>5}{'말':>5}  분류")
    R_stack, mw_stack, R_cls, mw_cls = [], [], [], []
    for r in res:
        rs = resample(r["t"], r["mw"]); mw_stack.append(rs) if rs is not None else None
        hm = thirds(r["mw"]); mw_cls.append(hm["cls"])
        if r["r_ok"]:
            rr = resample(r["t"], r["Rv"]); R_stack.append(rr) if rr is not None else None
            hR = thirds(r["Rv"]); R_cls.append(hR["cls"])
            print(f"{r['session']:<16}{'R':>5}{hR['e']:>5.0f}{hR['m']:>5.0f}{hR['l']:>5.0f}  {hR['cls']}")
        else:
            print(f"{r['session']:<16}{'mw':>5}{hm['e']:>5.0f}{hm['m']:>5.0f}{hm['l']:>5.0f}  {hm['cls']}(R무효)")
    print(f"\n  R 분류 (근육만, n={len(R_cls)}): " + "  ".join(f"{k} {v}" for k, v in Counter(R_cls).most_common()))
    print(f"  mw 분류 (전 세션, n={len(mw_cls)}): " + "  ".join(f"{k} {v}" for k, v in Counter(mw_cls).most_common()))

    print("\n  자기정점(내부) 대비 후반 하강 = 피로상:")
    fat = 0
    for r in res:
        sig = r["Rv"] if r["r_ok"] else r["mw"]
        pf, pv, ev, drop, interior = peak_fat(sig)
        is_fat = interior and drop <= -15
        fat += is_fat
        print(f"    {r['session']:<16}{'R' if r['r_ok'] else 'mw':>4}  "
              f"정점@{pf*100:>3.0f}% ({pv:>3.0f}%) → 끝 {ev:>3.0f}%  하강 {drop:>+4.0f}%  {'피로상' if is_fat else '—'}")
    print(f"  → 내부 정점 후 15%↑ 하강: {fat}/{len(res)}")

    for stack, lab in ((R_stack, "R=mw/art 근육만"), (mw_stack, "mw 진폭 전세션")):
        stack = [s for s in stack if s is not None]
        if not stack:
            continue
        Mn = np.vstack(stack).mean(0); t = len(GRID)//3
        e, m, l = Mn[:t].mean(), Mn[t:2*t].mean(), Mn[2*t:].mean()
        kp = int(np.argmax(Mn))
        print(f"\n  [{lab}] 평균 흐름 n={len(stack)}: 초{e:.0f}% 중{m:.0f}% 말{l:.0f}%  "
              f"정점@{GRID[kp]*100:.0f}%({Mn[kp]:.0f}%)  증강+{m-e:.0f}%p→피로{l-m:.0f}%p")

    if args.plot:
        import matplotlib; matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        fig, ax = plt.subplots(1, 2, figsize=(13, 5))
        for r in res:
            if r["r_ok"]:
                rs = resample(r["t"], r["Rv"])
                if rs is not None:
                    ax[0].plot(GRID*100, rs, lw=0.8, alpha=0.5,
                               color="crimson" if r["session"] == "20260717_141940" else "gray")
            rs = resample(r["t"], r["mw"])
            if rs is not None:
                ax[1].plot(GRID*100, rs, lw=0.8, alpha=0.4, color="gray")
        for a, stack, ti in ((ax[0], R_stack, "R = mw/art  (muscle-only; 141940=red)"),
                             (ax[1], mw_stack, "mw amplitude (all sessions)")):
            S = np.vstack([s for s in stack if s is not None]); Mn = S.mean(0); se = S.std(0)/np.sqrt(len(S))
            a.plot(GRID*100, Mn, "o-", color="navy", lw=2.5, label=f"mean (n={len(S)})")
            a.fill_between(GRID*100, Mn-se, Mn+se, color="navy", alpha=0.15)
            a.axhline(100, color="k", lw=0.5, ls=":")
            a.set_xlabel("relative time %"); a.set_ylabel("% of first block"); a.set_title(ti); a.legend()
        fig.suptitle("Common fatigue flow: potentiation -> fatigue (hump), aligned on relative time")
        fig.tight_layout()
        p = Path(__file__).parent/"raw_fatigue_flow.png"
        fig.savefig(p, dpi=120); print(f"\n저장: {p}")


if __name__ == "__main__":
    main()
