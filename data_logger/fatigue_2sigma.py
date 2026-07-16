#!/usr/bin/env python3
"""
fatigue_2sigma.py — 2σ 관리한계 기반 근피로 판정 (env_*.csv, 2차 포맷)

알고리즘 (사용자 정의):
  1. 3초 window 평균          : 100ms 행 30개를 비중첩으로 묶어 RMS/MDF 평균
  2. baseline 30초            : 앞쪽 10개 window(=30초)로 기준 통계 산출
  3. 2σ 관리한계              : UCL = base_RMS + 2σ,  LCL = base_MDF − 2σ
  4. RMS > UCL  AND  MDF < LCL : 두 조건 동시 만족한 window 를 '피로 후보'
  5. 지속 6초 (window 2개 연속): 후보가 2개 이상 연속돼야 '피로 발생' 확정
  6. Fatigue score            : (RMS z + MDF 하강 z)/2, 2.0 넘으면 관리한계 이탈

대상: Time(ms),Raw_ADC,ENV_Value,RMS,MDF,... ,Marker 헤더의 env_*.csv (2차)
      ※ 1차 env_*.csv (ENV_Value 만 있음) 는 MDF 가 없어 이 알고리즘 적용 불가.

사용:
  python3 fatigue_2sigma.py ../data_from_iphone/2차/env_20260713_232612.csv
  python3 fatigue_2sigma.py ../data_from_iphone/2차/*.csv --plot
"""
from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
import pandas as pd

class SkipFile(Exception):
    """이 파일은 분석 대상 아님(포맷/길이) — 배치에서 건너뛴다."""


WINDOW_S = 3.0        # window 길이(초)
BASELINE_S = 30.0     # baseline 길이(초)
SUSTAIN_WIN = 2       # 지속 판정에 필요한 연속 window 수 (2개 = 6초)
SIGMA = 2.0           # 관리한계 배수


def load(path: Path) -> pd.DataFrame:
    """2차 env CSV 로드. RMS/MDF 가 유효(>0)한 구간만 반환."""
    df = pd.read_csv(path)
    need = {"Time(ms)", "RMS", "MDF"}
    if not need.issubset(df.columns):
        raise SkipFile(f"RMS/MDF 컬럼 없음 (ENV만 있는 포맷)")
    df = df.copy()
    df["t_s"] = (df["Time(ms)"] - df["Time(ms)"].iloc[0]) / 1000.0
    # MW_Valid 컬럼이 있으면(펌웨어 신규 포맷) 무효 검출의 M-wave 값을 NaN 처리.
    # → 유발응답 피로 분석이 노이즈/검출실패값에 오염되지 않음(데이터셋=정답 정합성).
    if "MW_Valid" in df.columns:
        bad = df["MW_Valid"].astype(float) < 0.5
        for col in ("MW_Amp", "MW_Area", "MW_Latency"):
            if col in df.columns:
                df.loc[bad, col] = np.nan
    elif "MW_Area" in df.columns and len(df) > 5:
        # 구 데이터(신뢰도 플래그 없음): 검출이 멈추면 앱이 마지막 값을 계속 반복(ZOH).
        # 동일 MW_Area가 '정상 홀드(≈1.5초 자극주기)'보다 오래 반복되면 얼어붙은 stale 값
        # → NaN. 4초 이상 동일값 구간만 제거(정상 펄스간 홀드는 보존).
        dt = np.median(np.diff(df["Time(ms)"].to_numpy())) / 1000.0
        stale_rows = max(2, round(4.0 / (dt if dt > 0 else 0.1)))
        a = df["MW_Area"].to_numpy(dtype=float)
        change = np.r_[True, a[1:] != a[:-1]]
        grp = np.cumsum(change)
        run_len = pd.Series(grp).groupby(grp).transform("size").to_numpy()
        stale = run_len > stale_rows
        for col in ("MW_Amp", "MW_Area", "MW_Latency"):
            if col in df.columns:
                df.loc[stale, col] = np.nan
    # 워밍업(RMS 또는 MDF 가 0) 구간 제거
    df = df[(df["RMS"] > 0) & (df["MDF"] > 0)].reset_index(drop=True)
    return df


def window_reduce(df: pd.DataFrame, dt_s: float) -> pd.DataFrame:
    """비중첩 3초 window 로 RMS/MDF 평균. 각 window 의 중앙시각/마커 포함."""
    per_win = max(1, round(WINDOW_S / dt_s))     # window 당 행 수 (≈30)
    n_win = len(df) // per_win
    rows = []
    for w in range(n_win):
        seg = df.iloc[w * per_win:(w + 1) * per_win]
        marker = ""
        if "Marker" in seg:
            for v in seg["Marker"]:
                if pd.notna(v):
                    s = str(v).strip()
                    if s and s.lower() not in ("nan", "none"):
                        marker = s
                        break
        rows.append({
            "win": w,
            "t_center": seg["t_s"].mean(),
            "rms": seg["RMS"].mean(),
            "mdf": seg["MDF"].mean(),
            # M-wave (FES 유발응답) 지표 — 있으면 평균, 없으면 NaN
            "mw_amp": seg["MW_Amp"].mean() if "MW_Amp" in seg else np.nan,
            "mw_area": seg["MW_Area"].mean() if "MW_Area" in seg else np.nan,
            "marker": marker,
        })
    return pd.DataFrame(rows)


def analyze(win: pd.DataFrame) -> dict:
    """baseline 통계 → 관리한계 → 피로 후보/지속 판정. win 에 컬럼 추가."""
    n_base = max(1, round(BASELINE_S / WINDOW_S))    # baseline window 수 (=10)
    if len(win) <= n_base:
        raise SkipFile(f"너무 짧음 (window {len(win)}개 ≤ baseline {n_base}개)")

    base = win.iloc[:n_base]
    rms_mu, rms_sd = base["rms"].mean(), base["rms"].std(ddof=0)
    mdf_mu, mdf_sd = base["mdf"].mean(), base["mdf"].std(ddof=0)

    ucl = rms_mu + SIGMA * rms_sd     # RMS 상한 (넘으면 피로 방향)
    lcl = mdf_mu - SIGMA * mdf_sd     # MDF 하한 (내려가면 피로 방향)

    win["ucl"] = ucl
    win["lcl"] = lcl
    # z-score (피로 방향을 +로): RMS 상승, MDF 하강
    win["rms_z"] = (win["rms"] - rms_mu) / rms_sd if rms_sd > 0 else 0.0
    win["mdf_z"] = (mdf_mu - win["mdf"]) / mdf_sd if mdf_sd > 0 else 0.0
    win["fatigue_score"] = (win["rms_z"] + win["mdf_z"]) / 2.0

    win["candidate"] = (win["rms"] > ucl) & (win["mdf"] < lcl)   # 두 조건 AND

    # 지속: SUSTAIN_WIN 개 연속 candidate 인 window 를 confirmed 로
    c = win["candidate"].to_numpy()
    confirmed = np.zeros(len(c), dtype=bool)
    run = 0
    for i, v in enumerate(c):
        run = run + 1 if v else 0
        if run >= SUSTAIN_WIN:
            confirmed[i - SUSTAIN_WIN + 1:i + 1] = True
    win["confirmed"] = confirmed

    onset_idx = int(np.argmax(confirmed)) if confirmed.any() else None
    st = {
        "rms_mu": rms_mu, "rms_sd": rms_sd, "mdf_mu": mdf_mu, "mdf_sd": mdf_sd,
        "ucl": ucl, "lcl": lcl, "n_base": n_base,
        "onset_idx": onset_idx,
        "onset_t": win["t_center"].iloc[onset_idx] if onset_idx is not None else None,
    }
    st.update(analyze_mwave(win))
    return st


def analyze_mwave(win: pd.DataFrame) -> dict:
    """FES 유발응답 피로 판정 — M-wave Area 기준.

    기준(baseline)을 rest 가 아니라 '증강 정점 플래토'로 잡는다:
      1. MW_Area 를 3-window 이동평균으로 평활
      2. 정점(peak) = 평활 최대 지점
      3. 플래토 = 평활값이 peak 의 90% 이상인 window 집합 → 기준 통계
      4. LCL = 플래토평균 − 2σ.  정점 이후 window 가 LCL 아래로 6초(2window) 지속 하락 → 피로
    피로: M-wave 감소(정점 대비). 증강만 있고 감소 없으면 '피로 없음'.
    """
    if not win["mw_area"].notna().any():
        return {"mw_ok": False}

    area = win["mw_area"].to_numpy(dtype=float)
    smooth = pd.Series(area).rolling(3, center=True, min_periods=1).mean().to_numpy()
    peak_idx = int(np.nanargmax(smooth))
    peak_val = smooth[peak_idx]

    plateau = smooth >= 0.9 * peak_val           # 정점 90% 이상 = 증강 플래토
    ref = area[plateau]
    ref_mu = float(np.nanmean(ref))
    ref_sd = float(np.nanstd(ref))
    # 플래토가 상한 saturation 등으로 flat(σ≈0)이면 2σ LCL 이 정점과 같아져
    # '아무 하락이나 피로'로 오검출됨. σ 하한을 평균의 5%로 둬서
    # 사실상 '≥10% 지속 하락'을 피로 기준으로 삼는다.
    sat = ref_sd < 0.01 * ref_mu
    sd_eff = max(ref_sd, 0.05 * ref_mu)
    mw_lcl = ref_mu - SIGMA * sd_eff

    idx = np.arange(len(area))
    last_plateau = int(np.max(idx[plateau]))     # 플래토 끝 이후만 피로 대상
    cand = (idx > last_plateau) & (area < mw_lcl)

    confirmed = np.zeros(len(area), dtype=bool)
    run = 0
    for i, v in enumerate(cand):
        run = run + 1 if v else 0
        if run >= SUSTAIN_WIN:
            confirmed[i - SUSTAIN_WIN + 1:i + 1] = True

    win["mw_smooth"] = smooth
    win["mw_confirmed"] = confirmed
    win["mw_plateau"] = plateau

    onset = int(np.argmax(confirmed)) if confirmed.any() else None
    n_tail = max(1, len(area) // 5)
    tail = area[-n_tail:]
    tail = tail[~np.isnan(tail)]                 # 꼬리가 전부 무효(NaN)일 때 경고 방지
    tail_mu = float(np.mean(tail)) if tail.size else float("nan")
    decline = (tail_mu - peak_val) / peak_val * 100 \
        if (peak_val and not np.isnan(tail_mu)) else 0.0
    return {
        "mw_ok": True, "mw_sat": sat,
        "mw_ref_mu": ref_mu, "mw_ref_sd": ref_sd, "mw_lcl": mw_lcl,
        "mw_peak_val": peak_val, "mw_peak_t": win["t_center"].iloc[peak_idx],
        "mw_plateau_end_t": win["t_center"].iloc[last_plateau],
        "mw_tail_mu": tail_mu, "mw_decline_pct": decline,
        "mw_onset_idx": onset,
        "mw_onset_t": win["t_center"].iloc[onset] if onset is not None else None,
        "mw_n_conf": int(confirmed.sum()),
    }


def report(path: Path, win: pd.DataFrame, st: dict) -> None:
    print(f"\n=== {path.name} ===")
    dur = win["t_center"].iloc[-1]
    print(f"  window {len(win)}개 (3초), 세션 ≈{dur:.0f}초, "
          f"baseline {st['n_base']}개(30초)")
    print(f"  [RMS/MDF 2σ — 수의 EMG용, 유발신호엔 위양성 주의]")
    print(f"  baseline RMS = {st['rms_mu']:.1f} ± {st['rms_sd']:.1f}  "
          f"→ UCL(+2σ) = {st['ucl']:.1f}")
    print(f"  baseline MDF = {st['mdf_mu']:.1f} ± {st['mdf_sd']:.1f} Hz  "
          f"→ LCL(−2σ) = {st['lcl']:.1f} Hz")
    n_cand = int(win["candidate"].sum())
    n_conf = int(win["confirmed"].sum())
    print(f"  RMS>UCL AND MDF<LCL window : {n_cand}개")
    print(f"  6초 지속(연속 2개) 확정     : {n_conf}개 window")
    if st["onset_t"] is not None:
        print(f"  ✅ 근피로 발생 확정 시점    : {st['onset_t']:.0f}초 "
              f"(window #{st['onset_idx']})")
    else:
        if n_cand:
            print("  ⚠️ 후보는 있으나 6초 연속 미충족 → 피로 '확정' 아님")
        else:
            print("  ❌ 관리한계 이탈 window 없음 → 이 세션에선 피로 미검출")
    mk = win[win["marker"] != ""]
    for _, r in mk.iterrows():
        print(f"  📍 marker '{r['marker']}' @ {r['t_center']:.0f}초 "
              f"(score={r['fatigue_score']:+.2f})")

    # ── M-wave 기준 피로 판정 (FES 유발응답의 정식 지표) ──
    if st.get("mw_ok"):
        print(f"\n  [M-wave 기준 판정]")
        print(f"  증강 정점       : {st['mw_peak_val']:.0f} @ {st['mw_peak_t']:.0f}초 "
              f"(플래토 끝 {st['mw_plateau_end_t']:.0f}초)")
        sat_note = "  (플래토 flat/saturation → σ 하한 5% 적용, ≥10% 하락 기준)" \
            if st.get("mw_sat") else ""
        print(f"  기준 플래토     : {st['mw_ref_mu']:.0f} ± {st['mw_ref_sd']:.0f}  "
              f"→ LCL = {st['mw_lcl']:.0f}{sat_note}")
        print(f"  후반 M-wave     : {st['mw_tail_mu']:.0f} "
              f"(정점 대비 {st['mw_decline_pct']:+.0f}%)")
        print(f"  정점 후 LCL 이탈 6초 지속 : {st['mw_n_conf']}개 window")
        if st["mw_onset_t"] is not None:
            print(f"  ✅ 근피로(유발응답 감소) 확정 : {st['mw_onset_t']:.0f}초")
        else:
            print("  ❌ 정점 이후 유의한 지속 감소 없음 → 이 세션은 증강 우세, 피로 미검출")


def plot(path: Path, win: pd.DataFrame, st: dict, out: Path) -> None:
    import matplotlib.pyplot as plt
    plt.rcParams["font.family"] = "AppleGothic"
    plt.rcParams["axes.unicode_minus"] = False
    plt.rcParams["mathtext.default"] = "regular"

    t = win["t_center"]
    has_mw = win["mw_area"].notna().any()
    nrow = 4 if has_mw else 3
    fig, ax = plt.subplots(nrow, 1, figsize=(12, 3 * nrow), sharex=True)

    # 1) RMS + UCL
    ax[0].plot(t, win["rms"], color="C0", marker=".", ms=3, label="RMS (3초 평균)")
    ax[0].axhline(st["ucl"], ls="--", color="red", label=f"UCL (+2σ)={st['ucl']:.0f}")
    ax[0].axhline(st["rms_mu"], ls=":", color="gray", alpha=0.6, label="baseline 평균")
    ax[0].set_ylabel("RMS"); ax[0].legend(loc="upper left", fontsize=8)
    ax[0].set_title("RMS — UCL 상향 이탈 시 피로 방향")

    # 2) MDF + LCL
    ax[1].plot(t, win["mdf"], color="C2", marker=".", ms=3, label="MDF (3초 평균)")
    ax[1].axhline(st["lcl"], ls="--", color="red", label=f"LCL (-2σ)={st['lcl']:.0f}")
    ax[1].axhline(st["mdf_mu"], ls=":", color="gray", alpha=0.6, label="baseline 평균")
    ax[1].set_ylabel("MDF (Hz)"); ax[1].legend(loc="upper left", fontsize=8)
    ax[1].set_title("MDF — LCL 하향 이탈 시 피로 방향")

    # 3) Fatigue score
    ax[2].plot(t, win["fatigue_score"], color="C3", marker=".", ms=3, label="Fatigue score")
    ax[2].axhline(SIGMA, ls="--", color="red", alpha=0.7, label=f"{SIGMA:.0f}σ 한계")
    ax[2].axhline(0, color="black", lw=0.3)
    ax[2].set_ylabel("score"); ax[2].set_xlabel("time (s)")
    ax[2].legend(loc="upper left", fontsize=8)
    ax[2].set_title("Fatigue score = (RMS z + MDF 하강 z)/2")

    # 4) M-wave Area (FES 유발응답) — 정점 대비 지속 감소 = 피로
    if has_mw:
        ax[3].plot(t, win["mw_area"], color="C1", marker=".", ms=3, label="M-wave Area (3초 평균)")
        if st.get("mw_ok"):
            ax[3].axhline(st["mw_ref_mu"], ls=":", color="gray", alpha=0.7, label="증강 플래토 평균")
            ax[3].axhline(st["mw_lcl"], ls="--", color="red", label=f"LCL(-2σ)={st['mw_lcl']:.0f}")
            ax[3].scatter([st["mw_peak_t"]], [st["mw_peak_val"]], color="black",
                          zorder=5, s=30, label=f"정점 @ {st['mw_peak_t']:.0f}s")
            for _, r in win[win["mw_plateau"]].iterrows():
                ax[3].axvspan(r["t_center"] - WINDOW_S / 2, r["t_center"] + WINDOW_S / 2,
                              color="green", alpha=0.10)
        ax[3].set_ylabel("MW_Area"); ax[3].set_xlabel("time (s)")
        ax[3].legend(loc="upper right", fontsize=8)
        ax[3].set_title("M-wave Area — 초록=증강 플래토(기준), 정점 후 LCL 이탈 지속=피로")
    else:
        ax[2].set_xlabel("time (s)")

    # RMS/MDF 2σ 판정 오버레이는 패널 0~2 에만 (패널 3 은 M-wave 자체 판정)
    base_end = win["t_center"].iloc[st["n_base"] - 1]
    for a in ax[:3]:
        a.axvspan(t.iloc[0], base_end, color="gray", alpha=0.08)
        for _, r in win[win["confirmed"]].iterrows():
            a.axvspan(r["t_center"] - WINDOW_S / 2, r["t_center"] + WINDOW_S / 2,
                      color="red", alpha=0.12)
        for _, r in win[win["candidate"] & ~win["confirmed"]].iterrows():
            a.axvline(r["t_center"], color="orange", lw=0.8, alpha=0.5)
    # 패널 3: M-wave 기준 피로 확정 구간(빨강)
    if has_mw and "mw_confirmed" in win:
        for _, r in win[win["mw_confirmed"]].iterrows():
            ax[3].axvspan(r["t_center"] - WINDOW_S / 2, r["t_center"] + WINDOW_S / 2,
                          color="red", alpha=0.15)
    # 마커는 전 패널 공통
    for a in ax:
        for _, r in win[win["marker"] != ""].iterrows():
            a.axvline(r["t_center"], color="purple", lw=1.2)
            a.text(r["t_center"], a.get_ylim()[1], f" {r['marker']}",
                   color="purple", fontsize=8, va="top")

    fig.tight_layout()
    fig.savefig(out, dpi=120)
    print(f"  그래프 저장 → {out}")


def infer_dt(df: pd.DataFrame) -> float:
    """행 간 시간 간격(초) 추정 (기본 0.1s)."""
    if len(df) < 2:
        return 0.1
    d = np.median(np.diff(df["Time(ms)"].to_numpy())) / 1000.0
    return d if d > 0 else 0.1


def process(path: Path):
    """파일 하나 로드→window→분석. (win, st) 반환. 대상 아니면 SkipFile."""
    df = load(path)
    win = window_reduce(df, infer_dt(df))
    st = analyze(win)
    return win, st


def summary_header() -> None:
    print(f"{'파일':32s} {'초':>4s} {'M-wave판정':>10s} {'정점t':>5s} "
          f"{'낙폭%':>6s} {'RMS/MDF판정':>11s}  마커")


def summary_row(path: Path, win: pd.DataFrame, st: dict) -> None:
    if st.get("mw_ok"):
        mw = f"{st['mw_onset_t']:.0f}s피로" if st["mw_onset_t"] is not None else "증강우세"
        pk = f"{st['mw_peak_t']:.0f}"
        dec = f"{st['mw_decline_pct']:+.0f}"
    else:
        mw, pk, dec = "MW없음", "-", "-"
    rm = f"{st['onset_t']:.0f}s(위양성?)" if st["onset_t"] is not None else "없음"
    mk = ",".join(sorted(set(win.loc[win["marker"] != "", "marker"]))) or "-"
    print(f"{path.name:32s} {win['t_center'].iloc[-1]:4.0f} {mw:>10s} {pk:>5s} "
          f"{dec:>6s} {rm:>11s}  {mk}")


def main() -> None:
    ap = argparse.ArgumentParser(description="2σ/M-wave 근피로 판정 (env CSV)")
    ap.add_argument("csv", nargs="+", type=Path)
    ap.add_argument("--plot", action="store_true", help="그래프 저장(파일별)")
    ap.add_argument("--summary", action="store_true",
                    help="파일당 한 줄 요약표 (배치 비교용)")
    args = ap.parse_args()

    skipped = []
    if args.summary:
        summary_header()
    for path in sorted(args.csv):
        if not path.exists():
            print(f"⚠️ 없음: {path}"); continue
        try:
            win, st = process(path)
        except SkipFile as e:
            skipped.append((path.name, str(e))); continue
        except Exception as e:
            skipped.append((path.name, f"오류: {e}")); continue
        if args.summary:
            summary_row(path, win, st)
        else:
            report(path, win, st)
        if args.plot:
            plot(path, win, st, path.with_name(path.stem + "_2sigma.png"))

    if skipped:
        print(f"\n건너뜀 {len(skipped)}개:")
        for name, why in skipped:
            print(f"  - {name}: {why}")


if __name__ == "__main__":
    main()
