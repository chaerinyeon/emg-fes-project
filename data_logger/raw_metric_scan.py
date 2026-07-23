#!/usr/bin/env python3
"""raw_metric_scan.py — 전 raw 세션에 dawn(042118) 방법을 적용:
FES 서명 측정 → 펄스동기 템플릿 감산으로 FES 제거 → (1) 자발 EMG 가 분리되는가,
(2) 어떤 피로지표(M-wave·RMS·MDF·잔차)를 써야 하는가.

방법 (raw_full_analysis 재사용):
  · FES 는 펄스에 위상고정 → STA(동기평균)로 잡혀 감산된다. 남는 잔차 = 비고정 성분.
  · 자발 EMG tell 두 가지:
      restgap : 버스트 사이 쉼구간 RMS. FES만이면 바닥잡음, 자발이 들어오면 차오른다.
      rest_end 마커가 있으면 마커 전(FES만) vs 후(자발)로 restgap 을 직접 비교 → 결정적.
  · 잔차 RMS 가 M-wave 진폭과 강상관이면 그건 자발이 아니라 유발응답 시행변동이다.
  · 피로지표 후보를 블록별로 내고 추세(Spearman)를 낸다.

사용: python3 raw_metric_scan.py [--root ~/emgfes-data]
"""
from __future__ import annotations
import argparse
import sys
from pathlib import Path
import numpy as np, pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent))
import raw_full_analysis as RF

FS = RF.FS
PRE, POST = RF.STA_PRE, RF.STA_POST
BLANK = 3                 # 펄스 0~2ms blank (지터로 감산 불가)
BLK_S = 15.0
VOL_RATIO = 1.5           # rest_end 후 restgap 이 전보다 이 배 이상이면 자발 EMG 의심


def mdf(seg):
    seg = np.asarray(seg, float) - np.mean(seg)
    if len(seg) < 16:
        return np.nan
    sp = np.abs(np.fft.rfft(seg * np.hanning(len(seg)))) ** 2
    fr = np.fft.rfftfreq(len(seg), 1.0 / FS)
    b = (fr >= 20) & (fr <= 450)
    if sp[b].sum() <= 0:
        return np.nan
    c = np.cumsum(sp[b]); c /= c[-1]
    return float(fr[b][np.searchsorted(c, 0.5)])


def restgap_rms(absr, bursts):
    """버스트 사이 쉼구간 RMS 목록 (시각, rms). 양끝 20ms(버스트 꼬리) 제거."""
    out = []
    for k, (a, b) in enumerate(bursts):
        nb = bursts[k + 1][0] if k + 1 < len(bursts) else len(absr)
        g = absr[b:nb]
        if len(g) > 80:
            core = g[20:-20].astype(float)
            out.append(((a + b) / 2 / FS, float(np.sqrt(np.mean(core ** 2)))))
    return np.array(out) if out else np.empty((0, 2))


def marker_time(path, name="rest_end"):
    env = path.parent / path.name.replace("raw_", "env_")
    if not env.exists():
        return None
    try:
        d = pd.read_csv(env, usecols=lambda c: c in ("Time(ms)", "Marker"))
    except Exception:
        return None
    if "Marker" not in d.columns:
        return None
    m = d[d["Marker"].astype(str).str.strip() == name]
    return float(m["Time(ms)"].iloc[0]) / 1000.0 if len(m) else None


def tr(t, y):
    y = np.asarray(y, float); ok = ~np.isnan(y)
    return RF.spearman(t[ok], y[ok]) if ok.sum() >= 6 else np.nan


def pct(y):
    y = np.asarray(y, float); ok = ~np.isnan(y)
    if ok.sum() < 4:
        return np.nan
    y = y[ok]; a = np.median(y[:2]); b = np.median(y[-2:])
    return (b / a - 1) * 100 if a else np.nan


def analyze(path: Path):
    x, absr, dc, dropped, clip, v = RF.load_raw(path)
    n = len(x)
    bursts = RF.find_bursts(absr)
    if len(bursts) < RF.MIN_BURSTS:
        return None
    period = float(np.median(np.diff([a for a, _ in bursts])))
    if not (RF.PERIOD_LO <= period <= RF.PERIOD_HI):
        return None
    pulses = RF.refine_pulses(x, RF.find_pulses(absr))
    sta0, seg0, sel, info = RF.build_sta(x, pulses)
    if sta0 is None:
        return None
    win = RF.measure_window(sta0, seg0)
    if not win or win["sta_ratio"] < RF.STA_RATIO_GATE:
        return None

    rg = restgap_rms(absr, bursts)
    floor = float(np.percentile(rg[:, 1], 20)) if len(rg) else np.nan   # 조용한 쉼 = 바닥

    # rest_end 전/후 restgap (자발 EMG 결정 시험)
    t_re = marker_time(path)
    vol_before = vol_after = np.nan
    if t_re is not None and len(rg):
        bef = rg[rg[:, 0] < t_re, 1]; aft = rg[rg[:, 0] >= t_re, 1]
        if len(bef) >= 2 and len(aft) >= 2:
            vol_before, vol_after = float(np.median(bef)), float(np.median(aft))

    # 블록별 지표
    BLK = int(BLK_S * FS)
    rows = []
    for lo in range(0, n - BLK + 1, BLK):
        ps = sel[(sel >= lo + PRE) & (sel < lo + BLK - POST)]
        if len(ps) < 30:
            continue
        seg = np.stack([x[s - PRE:s + POST] for s in ps])
        sta = seg.mean(0); o = PRE
        mw = float(np.max(np.abs(sta[o + 3:o + 25])))
        blk_raw = x[lo:lo + BLK]
        naive_rms = float(np.sqrt(np.mean((blk_raw - blk_raw.mean()) ** 2)))
        resid = seg - sta
        resid[:, o:o + BLANK] = 0.0
        rr = resid[:, o + BLANK:o + POST].ravel()
        resid_rms = float(np.sqrt(np.mean(rr ** 2)))
        rgm = rg[(rg[:, 0] >= lo / FS) & (rg[:, 0] < (lo + BLK) / FS), 1]
        rows.append(dict(t=(lo + BLK / 2) / FS, mw=mw, naive_rms=naive_rms,
                         naive_mdf=mdf(blk_raw), resid_rms=resid_rms,
                         resid_mdf=mdf(rr), restgap=float(np.median(rgm)) if len(rgm) else np.nan))
    d = pd.DataFrame(rows)
    if len(d) < 6:
        return None
    t = d["t"].to_numpy()
    # 잔차 vs M-wave 상관 (강양상관 = 유발변동, 자발 아님)
    rv = d["resid_rms"].to_numpy(); mv = d["mw"].to_numpy()
    resid_mw_corr = RF.spearman(mv, rv)

    return dict(
        session=path.name.replace("raw_", "").replace(".csv", ""),
        subject=path.parent.name[-4:], dur=n / FS, clip=clip,
        period_ms=period, ppb=info.get("n_kept", np.nan),
        floor=floor, restgap_med=float(np.median(rg[:, 1])) if len(rg) else np.nan,
        t_re=t_re, vol_before=vol_before, vol_after=vol_after,
        mw_pct=pct(d["mw"]), mw_rho=tr(t, d["mw"]),
        nrms_pct=pct(d["naive_rms"]), nrms_rho=tr(t, d["naive_rms"]),
        nmdf_pct=pct(d["naive_mdf"]), nmdf_rho=tr(t, d["naive_mdf"]),
        rrms_pct=pct(d["resid_rms"]), rrms_rho=tr(t, d["resid_rms"]),
        resid_over_floor=float(np.median(d["resid_rms"]) / floor) if floor else np.nan,
        resid_mw_corr=resid_mw_corr,
        n_block=len(d),
    )


def vol_verdict(r):
    """자발 EMG 가 분리 가능한가."""
    if not np.isnan(r["vol_after"]) and not np.isnan(r["vol_before"]):
        if r["vol_after"] >= VOL_RATIO * r["vol_before"]:
            return f"자발있음? restgap {r['vol_before']:.0f}→{r['vol_after']:.0f}"
        return f"자발없음 restgap {r['vol_before']:.0f}→{r['vol_after']:.0f}(평탄)"
    # rest_end 없음 → restgap 절대수준으로만 (약한 근거)
    if not np.isnan(r["restgap_med"]) and not np.isnan(r["floor"]):
        if r["restgap_med"] >= VOL_RATIO * r["floor"]:
            return f"restgap 상승({r['floor']:.0f}→{r['restgap_med']:.0f}) 확인필요"
    return "자발없음(추정)"


def recommend(r):
    if r["mw_rho"] <= -0.5 and abs(r["mw_pct"]) >= 15:
        return f"M-wave ({r['mw_pct']:+.0f}%)"
    if r["mw_rho"] >= 0.5:
        return "증강우세(피로 미검출)"
    return "뚜렷한 피로 없음"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", type=Path, default=Path.home() / "emgfes-data")
    args = ap.parse_args()
    res = [r for r in (analyze(f) for f in sorted(args.root.glob("**/raw_*.csv"))) if r]
    df = pd.DataFrame(res).sort_values("session")
    print(f"스캔 가능 세션 {len(df)}개 (G1+STA 통과)\n")

    print("=== 1) 자발 EMG 분리 시험 (rest_end 마커 전/후 restgap RMS) ===")
    print(f"{'세션':<16}{'rest_end':>9}{'전':>6}{'후':>6}{'바닥':>6}{'잔차/바닥':>9}{'잔차~mw':>8}  판정")
    for _, r in df.iterrows():
        re = f"{r['t_re']:.0f}s" if r['t_re'] is not None else "—"
        vb = f"{r['vol_before']:.0f}" if not np.isnan(r['vol_before']) else "—"
        va = f"{r['vol_after']:.0f}" if not np.isnan(r['vol_after']) else "—"
        print(f"{r['session']:<16}{re:>9}{vb:>6}{va:>6}{r['floor']:>6.0f}"
              f"{r['resid_over_floor']:>9.1f}{r['resid_mw_corr']:>+8.2f}  {vol_verdict(r)}")

    print("\n=== 2) 피로지표별 추세 (%=Q1→Q4, ρ=시간상관) ===")
    print(f"{'세션':<16}{'M-wave':>16}{'naiveRMS':>15}{'naiveMDF':>15}{'잔차RMS':>15}   추천")
    for _, r in df.iterrows():
        def cell(p, rho):
            return f"{p:+.0f}% ρ{rho:+.2f}" if not np.isnan(p) else "  —"
        print(f"{r['session']:<16}{cell(r['mw_pct'], r['mw_rho']):>16}"
              f"{cell(r['nrms_pct'], r['nrms_rho']):>15}"
              f"{cell(r['nmdf_pct'], r['nmdf_rho']):>15}"
              f"{cell(r['rrms_pct'], r['rrms_rho']):>15}   {recommend(r)}")

    print("\n=== 요약 ===")
    vol = df[(df["vol_after"] >= VOL_RATIO * df["vol_before"])]
    print(f"  자발 EMG 분리 의심 세션: {len(vol)}/{len(df)}"
          + (f"  → {', '.join(vol['session'])}" if len(vol) else "  → 없음"))
    mwok = df[(df["mw_rho"] <= -0.5) & (df["mw_pct"].abs() >= 15)]
    print(f"  M-wave 로 피로 잡히는 세션: {len(mwok)}/{len(df)}  → {', '.join(mwok['session'])}")
    print(f"  잔차 RMS ~ M-wave 상관 중앙: {df['resid_mw_corr'].median():+.2f} "
          f"(양수 클수록 잔차=유발변동, 자발 아님)")

    df.to_csv(Path(__file__).parent / "raw_metric_scan.csv", index=False)
    print(f"\n저장: {Path(__file__).parent / 'raw_metric_scan.csv'}")


if __name__ == "__main__":
    main()
