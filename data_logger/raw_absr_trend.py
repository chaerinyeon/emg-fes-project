#!/usr/bin/env python3
"""
raw_absr_trend.py — raw_*.csv 전체의 |R|(정류 진폭) 절대값 비교 + 세션 내 변화율.

|R| 정의:
  |R| = |Raw_ADC − DC|,  DC 는 파일별 중앙값(고정 1862 이 아니라 파일마다 다시 구함).
  → 오프셋이 세션마다 1857~1867 로 다르다. 고정 DC 를 쓰면 |R| 절대값 비교에
    오프셋 차이가 그대로 섞여 들어간다.

버스트 검출 (자극 세기에 의존하지 않는 방법):
  |R| 을 51ms 이동평균해 포락선을 만들고 Otsu 문턱으로 자극구간/쉼구간을 가른다.
  개별 펄스에 고정문턱(400)을 걸면 자극이 약한 세션에서 통째로 놓친다
  (실제로 023422 은 버스트의 40%를 놓쳐 주기가 2.4초로 잘못 나왔다).
  포락선 방식은 11개 세션 모두에서 주기 1611~1622ms 를 복원한다 — 실측 1621.9ms 와 일치.

검증 게이트:
  주기 1500~1750ms 이고 점유율 20~50% 여야 '자극 세션'으로 인정.
  통과 못 하면 자극이 없었던 세션 → 버스트 추세를 내지 않고 쉼 |R| 만 본다.

구간 분리 (실측: 1.62초 주기, 0.49초 버스트, 버스트 내 펄스 32Hz):
  burst : |R| 은 자극 아티팩트 + 유발응답이 지배
  rest  : |R| 은 바닥잡음 (실측상 이 구간에 자발 EMG 는 없음)
  섞은 전체 평균 |R| 은 버스트 점유율에 좌우되므로 반드시 따로 낸다.

변화율:
  자극 사이클(버스트) 단위로 |R| 집계 → 시간에 대한 추세.
    ρ      : Spearman 시간상관 (단조성)
    %/min  : OLS 기울기를 baseline(첫 25% 중앙값) 대비 %로 환산
    Q1→Q4  : 첫 25% 대비 마지막 25% 변화율

|R| 분해 (버스트 |R| 감소의 원인 판별):
  버스트 |R| 만 보면 감소가 근피로인지 자극세기 변화인지 구분할 수 없다.
  각 펄스에 정렬해 두 창으로 쪼갠다.
    art = 0~1ms  |R| 최대  → 자극 세기의 대조군 (근육 상태와 무관)
                             ※ 0~4ms 는 M-wave 가 섞여 대조군이 못 된다
    mw  = 5~15ms |R| 평균  → 근육 유발응답
  art 일정 + mw 감소 → 근피로 / art 도 감소 → 자극·전극 변화(피로 단정 불가)

사용: python3 raw_absr_trend.py [<raw.csv> ...] [--plot]
"""
from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
import pandas as pd

FS = 1000.0             # Hz
ENV_WIN = 51            # ms, 포락선 이동평균 창
MIN_BURST_MS = 100      # 이보다 짧은 on-구간은 버스트로 안 봄
PERIOD_LO, PERIOD_HI = 1500, 1750    # ms, 자극 세션 검증 게이트 (실측 1621.9)
DUTY_LO, DUTY_HI = 20.0, 50.0        # %, 자극 세션 검증 게이트
ADC_MIN, ADC_MAX = 0, 4095           # 12bit 레일 (클리핑 판정)
PULSE_REFRAC = 25       # ms, 펄스주기 31ms 보다 짧게 (40ms 면 자극의 절반을 놓침)
ART_HI = 2              # 아티팩트 창 0~1ms (대조군)
MW_LO, MW_HI = 5, 16    # M-wave 창 5~15ms (근육 반응)
DECOMP_BLOCKS = 12      # 분해 추세의 목표 블록 수 (길이는 세션에 맞춰 적응)
BLOCK_MIN_S, BLOCK_MAX_S = 10.0, 20.0   # 블록 길이 하한/상한(초)
RHO_GATE = 0.5          # 추세 인정 문턱 (Spearman)
PCT_GATE = 15.0         # 추세 인정 문턱 (Q1→Q4 %) — ρ 만 크고 폭이 미미한 건 제외
ART_PCT_GATE = 10.0     # 아티팩트가 이만큼 변하면 '자극 일정' 이라 할 수 없음
MW_ART_RATIO = 2.0      # 대조군이 흔들려도 mw 감소가 art 감소의 이 배 이상이면 '경계'


def load_raw(path: Path):
    """raw CSV → (absr, dc, dropped). 이전 세션 잔여 패킷(시간이 뒤로 감) 제거."""
    d = pd.read_csv(path)
    t = d["Time(ms)"].to_numpy()
    v = d["Raw_ADC"].to_numpy(dtype=float)
    dropped = 0
    back = np.where(np.diff(t) < 0)[0]
    if len(back):
        dropped = int(back[-1] + 1)
        v = v[dropped:]
    dc = float(np.median(v))
    clip = float(((v <= ADC_MIN) | (v >= ADC_MAX)).mean() * 100)
    return np.abs(v - dc), dc, dropped, clip


def otsu(x: np.ndarray, nb: int = 256) -> float:
    """포락선을 자극/쉼 두 무리로 가르는 문턱. 상위 0.5%는 꼬리라 잘라내고 계산."""
    lo, hi = float(x.min()), float(np.percentile(x, 99.5))
    if hi <= lo:
        return float("inf")
    h, e = np.histogram(np.clip(x, lo, hi), bins=nb, range=(lo, hi))
    p = h.astype(float) / h.sum()
    c = np.cumsum(p)
    m = np.cumsum(p * ((e[:-1] + e[1:]) / 2))
    d = c * (1 - c)
    d[d == 0] = 1e-12
    k = int(np.argmax((m[-1] * c - m) ** 2 / d))
    return float((e[k] + e[k + 1]) / 2)


def find_bursts(absr: np.ndarray) -> list[tuple[int, int]]:
    """포락선 + Otsu 로 (시작, 끝) 샘플 목록."""
    env = pd.Series(absr).rolling(ENV_WIN, center=True, min_periods=1).mean().to_numpy()
    on = env > otsu(env)
    ch = np.diff(on.astype(np.int8))
    st = list(np.where(ch == 1)[0] + 1)
    en = list(np.where(ch == -1)[0] + 1)
    if on[0]:
        st.insert(0, 0)
    if on[-1]:
        en.append(len(on))
    return [(a, b) for a, b in zip(st, en) if b - a >= MIN_BURST_MS]


def find_pulses(absr: np.ndarray) -> np.ndarray:
    """개별 자극 펄스 시점. 문턱은 파일별 적응(자극이 약한 세션도 잡히게)."""
    thr = max(50.0, 0.35 * np.percentile(absr, 99.9))
    idx = np.where(absr > thr)[0]
    out, last = [], -10_000
    for i in idx:
        if i - last >= PULSE_REFRAC:
            out.append(i)
            last = i
    return np.array(out, dtype=int)


def decompose(absr: np.ndarray) -> pd.DataFrame:
    """블록별 art(0~1ms 최대) / mw(5~15ms 평균). 펄스 정렬.

    블록 길이는 세션 길이에 맞춰 적응 — 고정 20초면 짧은 세션(131초)이 6블록밖에
    안 나와 추세를 못 낸다. 10초 블록이어도 블록당 펄스가 ~90개라 평균은 안정적.
    """
    ps = find_pulses(absr)
    if len(ps) < 50:
        return pd.DataFrame()
    blk_s = min(BLOCK_MAX_S, max(BLOCK_MIN_S, len(absr) / FS / DECOMP_BLOCKS))
    blk = int(blk_s * FS)
    rows = []
    for lo in range(0, len(absr) - blk + 1, blk):
        sel = ps[(ps >= lo) & (ps < lo + blk - MW_HI)]
        if len(sel) < 20:
            continue
        rows.append({
            "t_s": (lo + blk / 2) / FS,
            "art": float(np.mean([absr[s:s + ART_HI].max() for s in sel])),
            "mw": float(np.mean([absr[s + MW_LO:s + MW_HI].mean() for s in sel])),
        })
    return pd.DataFrame(rows)


def spearman(x, y) -> float:
    xr = pd.Series(x).rank().to_numpy().astype(float)
    yr = pd.Series(y).rank().to_numpy().astype(float)
    xr -= xr.mean()
    yr -= yr.mean()
    d = np.sqrt((xr ** 2).sum() * (yr ** 2).sum())
    return float((xr * yr).sum() / d) if d > 0 else np.nan


NO_TREND = {"rho": np.nan, "pct_min": np.nan, "q1q4": np.nan}


def trend(t_s: np.ndarray, y: np.ndarray) -> dict:
    """|R| 시계열의 변화율. baseline = 첫 25% 중앙값."""
    n = len(y)
    if n < 8:
        return dict(NO_TREND)
    q = max(2, n // 4)
    base = float(np.median(y[:q]))
    last = float(np.median(y[-q:]))
    slope = float(np.polyfit(t_s, y, 1)[0])          # ADC/초
    return {
        "rho": spearman(t_s, y),
        "pct_min": slope * 60.0 / base * 100.0 if base > 0 else np.nan,
        "q1q4": (last / base - 1.0) * 100.0 if base > 0 else np.nan,
    }


def analyze(path: Path) -> dict:
    absr, dc, dropped, clip = load_raw(path)
    dur = len(absr) / FS
    bursts = find_bursts(absr)

    period = float(np.median(np.diff([a for a, _ in bursts]))) if len(bursts) > 1 else np.nan
    duty = sum(b - a for a, b in bursts) / len(absr) * 100 if bursts else 0.0
    stim_ok = (len(bursts) >= 8 and PERIOD_LO <= period <= PERIOD_HI
               and DUTY_LO <= duty <= DUTY_HI)

    rows = []
    for k, (a, b) in enumerate(bursts):
        rest_b = bursts[k + 1][0] if k + 1 < len(bursts) else len(absr)
        rest = absr[b:rest_b]
        rows.append({
            "t_s": (a + b) / 2 / FS,
            "burst": float(absr[a:b].mean()),
            "peak": float(absr[a:b].max()),
            "rest": float(rest.mean()) if len(rest) > 50 else np.nan,
        })
    cyc = pd.DataFrame(rows)

    out = {
        "session": path.name.replace("raw_", "").replace(".csv", ""),
        "subject": path.parent.name.replace("subject_", "")[-4:],
        "dur_s": dur, "dc": dc, "dropped": dropped, "clip_pct": clip,
        "n_burst": len(bursts), "period_ms": period, "duty_pct": duty,
        "stim_ok": stim_ok,
        "absr_all": float(absr.mean()),
        "absr_burst": float(cyc["burst"].mean()) if stim_ok else np.nan,
        "absr_rest": float(cyc["rest"].mean(skipna=True)) if stim_ok else float(absr.mean()),
        "_cyc": cyc if stim_ok else pd.DataFrame(),
    }
    tb = trend(cyc["t_s"].to_numpy(), cyc["burst"].to_numpy()) if stim_ok else dict(NO_TREND)
    ok = cyc["rest"].notna() if stim_ok else pd.Series(dtype=bool)
    tr = (trend(cyc.loc[ok, "t_s"].to_numpy(), cyc.loc[ok, "rest"].to_numpy())
          if stim_ok and ok.sum() >= 8 else dict(NO_TREND))
    out.update({f"burst_{k}": v for k, v in tb.items()})
    out.update({f"rest_{k}": v for k, v in tr.items()})

    # |R| 분해 — 버스트 |R| 변화의 원인 판별
    dec = decompose(absr) if stim_ok else pd.DataFrame()
    ta = trend(dec["t_s"].to_numpy(), dec["art"].to_numpy()) if len(dec) >= 4 else dict(NO_TREND)
    tm = trend(dec["t_s"].to_numpy(), dec["mw"].to_numpy()) if len(dec) >= 4 else dict(NO_TREND)
    out.update({f"art_{k}": v for k, v in ta.items()})
    out.update({f"mw_{k}": v for k, v in tm.items()})
    out["n_block"] = len(dec)
    out["verdict"] = verdict(ta["rho"], ta["q1q4"], tm["rho"], tm["q1q4"])
    return out


def verdict(ra: float, fa: float, rm: float, fm: float) -> str:
    """art/mw 의 (ρ, Q1→Q4%) 로 판정.

    핵심은 '자극 대조군(art)이 일정했는가'다. art 가 단조 감소(ρ≤−0.5)하면
    폭이 작아도 자극이 변한 것이므로 M-wave 감소를 근육 탓으로 단정할 수 없다.
    다만 M-wave 감소가 art 감소보다 뚜렷이 크면(≥2배) 피로 성분이 우세하다고 보고
    '경계'로 남긴다 — 버리지도, 피로로 확정하지도 않는다.
    """
    if np.isnan(ra) or np.isnan(rm):
        return "블록부족 — 판정불가"
    mw_down = rm <= -RHO_GATE and fm <= -PCT_GATE
    if ra <= -RHO_GATE:                      # 자극이 단조 감소 → 대조군 불안정
        if mw_down and abs(fm) >= MW_ART_RATIO * abs(fa):
            return f"경계 — 피로 우세(mw {fm:+.0f}% vs art {fa:+.0f}%)이나 대조군 불안정"
        return "자극·전극 약화 — 피로 단정불가"
    if mw_down:
        # 자극이 오히려 세졌는데 반응이 줄면 피로 근거가 더 강하다.
        if ra >= RHO_GATE and fa >= ART_PCT_GATE:
            return "근피로 (자극 증가에도 M-wave 감소)"
        return "근피로 (자극일정 + M-wave 감소)"
    if rm >= RHO_GATE and fm >= PCT_GATE:
        return "증강(potentiation)"
    if rm <= -RHO_GATE:
        return f"M-wave 감소 미미({fm:+.0f}%) — 피로 아님"
    return "추세없음"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("raw", type=Path, nargs="*")
    ap.add_argument("--plot", action="store_true")
    args = ap.parse_args()

    files = args.raw or sorted((Path(__file__).parent.parent / "data").glob("**/raw_*.csv"))
    df = pd.DataFrame([analyze(f) for f in files])
    ok = df[df["stim_ok"]]
    bad = df[~df["stim_ok"]]
    print(f"raw 세션 {len(df)}개 — 자극 확인 {len(ok)}개, 자극 없음 {len(bad)}개\n")

    print("=== |R| 절대값 (ADC, 파일별 DC 기준) ===")
    print(f"{'세션':<16}{'대상':>5}{'길이':>7}{'DC':>6}{'클립':>6}{'버스트':>6}{'주기':>8}"
          f"{'점유':>6}{'|R|전체':>8}{'|R|버스트':>9}{'|R|쉼':>7}")
    for _, r in df.iterrows():
        per = f"{r['period_ms']:.0f}ms" if not np.isnan(r["period_ms"]) else "  —  "
        bu = f"{r['absr_burst']:.1f}" if not np.isnan(r["absr_burst"]) else "—"
        print(f"{r['session']:<16}{r['subject']:>5}{r['dur_s']:>6.0f}s{r['dc']:>6.0f}"
              f"{r['clip_pct']:>5.2f}%{r['n_burst']:>6.0f}{per:>8}{r['duty_pct']:>5.0f}%"
              f"{r['absr_all']:>8.1f}{bu:>9}{r['absr_rest']:>7.1f}")

    if len(bad):
        print("\n  ※ 자극 없음으로 판정(버스트 추세 제외):")
        for _, r in bad.iterrows():
            print(f"     {r['session']}  버스트 {r['n_burst']:.0f}개, 점유 {r['duty_pct']:.1f}% "
                  f"→ 검증 게이트(주기 {PERIOD_LO}~{PERIOD_HI}ms, 점유 {DUTY_LO:.0f}~{DUTY_HI:.0f}%) 불통과")

    print("\n=== 세션 내 변화율 (자극 사이클 단위, 자극 확인 세션만) ===")
    print(f"{'세션':<16}{'버스트 ρ':>9}{'%/min':>8}{'Q1→Q4':>9}   "
          f"{'쉼 ρ':>7}{'%/min':>8}{'Q1→Q4':>9}   판정")
    for _, r in ok.iterrows():
        rho = r["burst_rho"]
        v = "↓ 감소" if rho <= -0.5 else "↑ 증가" if rho >= 0.5 else "→ 추세없음"
        print(f"{r['session']:<16}{rho:>+9.2f}{r['burst_pct_min']:>+8.1f}{r['burst_q1q4']:>+8.1f}%   "
              f"{r['rest_rho']:>+7.2f}{r['rest_pct_min']:>+8.1f}{r['rest_q1q4']:>+8.1f}%   {v}")

    print("\n=== |R| 분해: 감소의 원인 (art=0~1ms 자극대조군, mw=5~15ms 근육반응) ===")
    print(f"{'세션':<16}{'블록':>5}{'art ρ':>8}{'art Q1→Q4':>11}{'mw ρ':>8}{'mw Q1→Q4':>10}   판정")
    for _, r in ok.iterrows():
        print(f"{r['session']:<16}{r['n_block']:>5.0f}{r['art_rho']:>+8.2f}{r['art_q1q4']:>+10.1f}%"
              f"{r['mw_rho']:>+8.2f}{r['mw_q1q4']:>+9.1f}%   {r['verdict']}")

    print("\n=== 세션 간 |R| 절대값 산포 (자극 확인 세션) ===")
    for col, lab in (("absr_burst", "버스트"), ("absr_rest", "쉼")):
        v = ok[col].dropna()
        print(f"  {lab:<5} 중앙 {v.median():6.1f}  범위 {v.min():6.1f}~{v.max():6.1f}"
              f"  (최대/최소 {v.max()/v.min():.1f}배)")

    out = Path(__file__).parent / "raw_absr_trend.csv"
    df.drop(columns=["_cyc"]).to_csv(out, index=False)
    print(f"\n저장: {out}")

    if args.plot:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        n = len(ok)
        rows_ = (n + 2) // 3
        fig, axes = plt.subplots(rows_, 3, figsize=(15, 3 * rows_), squeeze=False)
        for ax, (_, r) in zip(axes.ravel(), ok.iterrows()):
            c = r["_cyc"]
            ax.plot(c["t_s"], c["burst"], ".-", ms=2, lw=0.6, label="burst |R|")
            ax.plot(c["t_s"], c["rest"], ".-", ms=2, lw=0.6, label="rest |R|")
            ax.set_title(f"{r['session']}  rho={r['burst_rho']:+.2f}  "
                         f"Q1->Q4 {r['burst_q1q4']:+.0f}%", fontsize=8)
            ax.set_xlabel("s")
            ax.set_ylabel("|R| (ADC)")
            ax.legend(fontsize=6)
        for ax in axes.ravel()[n:]:
            ax.axis("off")
        fig.tight_layout()
        p = Path(__file__).parent / "raw_absr_trend.png"
        fig.savefig(p, dpi=110)
        print(f"저장: {p}")


if __name__ == "__main__":
    main()
