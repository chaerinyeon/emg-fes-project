#!/usr/bin/env python3
"""
latest_session_check.py — 방금 뽑은(=가장 최근) 세션을 찾아 raw/env 정합성과
M-wave 추세를 한 번에 검사한다.

왜 필요한가
  raw CSV 의 Time 열은 기기가 찍어준 시각이 아니라 "표본 index × 공칭주기" 다.
  실제로 도착한 표본이 공칭보다 적으면 파일의 시간축이 그대로 압축된다(4kHz 로
  적었는데 1kHz 만 왔으면 810초 세션이 202초로 보인다). 그러면 잠복·주파수·
  버스트 주기 등 시간에 얽힌 모든 결과가 배수로 틀린다. 그래서 판정보다 먼저
  '시간축이 진짜인가' 를 env(100ms 고정 격자)·emg(wall clock) 로 교차검증한다.

순서
  1. 세션 묶음 찾기 (raw_/env_/emg_ 같은 타임스탬프)
  2. 시간축 감사 : 공칭 fs vs 실측 fs(표본수 ÷ env·wall 지속시간) vs 자극주기 fs
  3. 자극 구조   : 펄스 검출 → 펄스율·버스트 주기·버스트당 펄스수
  4. M-wave      : STA 로 잠복·창 실측 → 시행별 M-wave 진폭/면적, 대조군(0~1ms) 정규화
                   → 세션 전반 추세(전1/3 vs 후1/3, Spearman rho)
  5. env 위생    : RMS/MDF/MW_Valid/마커가 실제로 채워졌는지
사용:  python3 latest_session_check.py [--root ~/emgfes-data] [--session raw_....csv] [--all] [--plot]
"""
import argparse, csv, os, re, sys, glob
from datetime import datetime
import numpy as np

STAMP = re.compile(r'(raw|env|emg)_(\d{8}_\d{6})')

# ── 세션 묶기 ───────────────────────────────────────────────────────────────
def find_sessions(root):
    """{stamp: {'raw':path,'env':path,'emg':path,'dir':...}} — emg 는 종료시각 이름이라 못 붙을 수 있다."""
    sess = {}
    for p in glob.glob(os.path.join(root, "**", "*.csv"), recursive=True):
        m = STAMP.search(os.path.basename(p))
        if not m:
            continue
        kind, stamp = m.group(1), m.group(2)
        s = sess.setdefault(stamp, {"dir": os.path.dirname(p), "stamp": stamp})
        s[kind] = p
    return {k: v for k, v in sess.items() if "raw" in v}

def load_raw(path):
    a = np.loadtxt(path, delimiter=",", skiprows=1, usecols=(0, 1))
    return a[:, 0], a[:, 1]

def load_env(path):
    rows = list(csv.DictReader(open(path)))
    return rows

# ── 2. 시간축 감사 ──────────────────────────────────────────────────────────
def audit_timebase(t, env_rows, emg_path):
    """공칭 fs(파일 시간축) 와 실측 fs(표본수÷실제 지속시간) 를 비교한다."""
    dt = np.diff(t[: min(len(t), 200000)])
    nominal_dt = float(np.median(dt))                      # ms
    nominal_fs = 1000.0 / nominal_dt if nominal_dt else float("nan")
    dur_file = (t[-1] - t[0]) / 1000.0

    dur_env = None
    if env_rows:
        et = np.array([float(r["Time(ms)"]) for r in env_rows])
        dur_env = (et[-1] - et[0]) / 1000.0                # env 는 100ms 고정 격자 → 신뢰 기준
    dur_wall = None
    if emg_path and os.path.exists(emg_path):
        wt = [r["wall_time"] for r in csv.DictReader(open(emg_path)) if r.get("wall_time")]
        if len(wt) > 1:
            f = datetime.fromisoformat(wt[0]); l = datetime.fromisoformat(wt[-1])
            dur_wall = (l - f).total_seconds()             # 벽시계 → 최종 심판
    # env(100ms 고정 격자)를 1순위로 삼는다. emg 는 파일명이 '종료시각'이라 세션이
    # 비정상 종료돼 emg 가 없으면 다음 세션 것이 잘못 붙는다 — env 와 10% 넘게
    # 어긋나면 짝이 틀린 것으로 보고 버린다.
    if dur_env and dur_wall and abs(dur_wall - dur_env) / dur_env > 0.10:
        dur_wall = None
    ref = dur_env or dur_wall
    actual_fs = len(t) / ref if ref else float("nan")
    return dict(nominal_dt=nominal_dt, nominal_fs=nominal_fs, dur_file=dur_file,
                dur_env=dur_env, dur_wall=dur_wall, actual_fs=actual_fs,
                ratio=(nominal_fs / actual_fs) if ref else float("nan"))

# ── 3. 자극 검출 ────────────────────────────────────────────────────────────
def estimate_period(v, fs, lo_ms=8, hi_ms=120):
    """펄스 주기를 자기상관으로 먼저 잰다. 문턱만으로 정점을 고르면 M-wave 가 문턱을
    넘는 순간 그것까지 '펄스'로 세어 펄스율이 부풀고 STA 가 무너진다."""
    d = np.abs(v - np.median(v))
    seg = d[: min(len(d), 200000)]
    seg = seg - seg.mean()
    ac = np.correlate(seg, seg, mode="full")[len(seg) - 1:]
    ac = ac / ac[0]
    lo, hi = int(lo_ms * fs / 1000), int(hi_ms * fs / 1000)
    lag = int(np.argmax(ac[lo:hi]) + lo)
    return lag / fs * 1000.0, float(ac[lag])          # ms, 주기성 강도

def detect_pulses(v, fs, period_ms):
    """MAD 8σ 국소 최대. 불응기는 주기의 0.7배 — 표본수로 고정하면 fs 가 바뀔 때
    자극을 절반만 잡는 옛 버그(MW_REFRACTORY_MS=40 > 주기 31ms)가 그대로 재현된다."""
    med = np.median(v)
    dev = np.abs(v - med)
    mad = np.median(dev)
    thr = max(8 * mad, 40.0)
    ref = max(int(0.7 * period_ms * fs / 1000.0), 1)
    peaks, last = [], -10**9
    for i in np.flatnonzero(dev > thr):
        if i - last < ref:
            if peaks and dev[i] > dev[peaks[-1]]:
                peaks[-1] = int(i); last = int(i)
            continue
        peaks.append(int(i)); last = int(i)
    return np.array(peaks), thr, mad

def burst_structure(peaks, fs):
    """펄스 간격에서 버스트 내부(짧은 간격)와 버스트 사이(긴 간격)를 갈라 본다."""
    if len(peaks) < 5:
        return {}
    gaps_ms = np.diff(peaks) / fs * 1000.0
    intra = gaps_ms[gaps_ms < 100]
    inter = gaps_ms[gaps_ms >= 100]
    starts = [peaks[0]] + [peaks[i + 1] for i, g in enumerate(gaps_ms) if g >= 100]
    per_burst = []
    cnt = 1
    for g in gaps_ms:
        if g >= 100: per_burst.append(cnt); cnt = 1
        else: cnt += 1
    per_burst.append(cnt)
    return dict(n_pulses=len(peaks),
                pulse_rate=1000.0 / np.median(intra) if len(intra) else float("nan"),
                burst_period=float(np.median(np.diff(starts)) / fs * 1000.0) if len(starts) > 2 else float("nan"),
                n_bursts=len(starts),
                pulses_per_burst=float(np.median(per_burst)) if per_burst else float("nan"),
                intra_n=len(intra), inter_n=len(inter))

# ── 4. M-wave ───────────────────────────────────────────────────────────────
def sta_window(v, peaks, fs, pre_ms=2.0, post_ms=30.0):
    """자극 정렬 평균(STA). 개별 정점 평균 대비 STA 정점이 작으면 위상이 흩어진 것."""
    pre, post = int(pre_ms * fs / 1000), int(post_ms * fs / 1000)
    seg = [v[p - pre:p + post] for p in peaks if p - pre >= 0 and p + post < len(v)]
    if not seg:
        return None, None, None
    E = np.stack(seg)
    base = np.median(E[:, :pre], axis=1, keepdims=True)
    E = E - base
    sta = E.mean(axis=0)
    tax = (np.arange(-pre, post) / fs) * 1000.0
    return E, sta, tax

def spearman(x, y):
    rx = np.argsort(np.argsort(x)).astype(float)
    ry = np.argsort(np.argsort(y)).astype(float)
    rx -= rx.mean(); ry -= ry.mean()
    d = np.sqrt((rx**2).sum() * (ry**2).sum())
    return float((rx * ry).sum() / d) if d else float("nan")

def mwave_trend(E, tax, fs):
    """대조군(0~1ms, 근육이 물리적으로 반응 못 하는 구간)으로 나눠 전극 이득을 약분한다."""
    ctrl = (tax >= 0) & (tax <= 1)
    sta = E.mean(axis=0)
    search = tax > 1.5
    lat = float(tax[search][np.argmax(np.abs(sta[search]))])          # 세션별 잠복 실측
    win = (tax >= lat - 3) & (tax <= lat + 6)
    ctrl_amp = np.ptp(E[:, ctrl], axis=1)
    mw_amp = np.ptp(E[:, win], axis=1)
    mw_area = np.abs(E[:, win]).sum(axis=1) / fs * 1000.0
    R = mw_amp / np.where(ctrl_amp == 0, np.nan, ctrl_amp)
    n = len(R); third = max(n // 3, 1)
    idx = np.arange(n, dtype=float)
    def chg(a):
        f, l = np.nanmedian(a[:third]), np.nanmedian(a[-third:])
        return f, l, (l - f) / f * 100 if f else float("nan")
    return dict(latency_ms=lat, n_trials=n,
                amp=chg(mw_amp), area=chg(mw_area), R=chg(R),
                rho_amp=spearman(idx, np.nan_to_num(mw_amp)),
                rho_R=spearman(idx[~np.isnan(R)], R[~np.isnan(R)]) if np.any(~np.isnan(R)) else float("nan"),
                ctrl_sat=float(np.mean((E[:, ctrl].max(axis=1) >= 4090) | (E[:, ctrl].min(axis=1) <= -4090)) * 100),
                series_amp=mw_amp, series_R=R, sta=sta, tax=tax)

# ── 5. env 위생 ─────────────────────────────────────────────────────────────
def env_hygiene(rows):
    if not rows: return {}
    def col(k): return np.array([float(r[k]) for r in rows]) if k in rows[0] else np.array([])
    rms, mdf, mwv = col("RMS"), col("MDF"), col("MW_Valid")
    mk = [r["Marker"] for r in rows if r.get("Marker")]
    return dict(n=len(rows),
                rms_nonzero=int((rms > 0).sum()) if rms.size else -1,
                mdf_nonzero=int((mdf > 0).sum()) if mdf.size else -1,
                mw_valid_pct=float(mwv.mean() * 100) if mwv.size else float("nan"),
                markers=", ".join(sorted(set(mk))) or "(없음)")

def env_mwave_trend(rows):
    """env 의 MW_* 는 기기가 내부 전체 표본으로 계산해 100ms 마다 올려준 값이다.
    BLE 로 솎인 raw 와 달리 감쇄가 없어, raw 가 1kHz 로 떨어졌을 때의 대안이 된다."""
    if not rows or "MW_Amp" not in rows[0]:
        return {}
    amp = np.array([float(r["MW_Amp"]) for r in rows])
    area = np.array([float(r["MW_Area"]) for r in rows])
    lat = np.array([float(r["MW_Latency"]) for r in rows])
    ok = np.array([float(r["MW_Valid"]) for r in rows]) > 0
    if ok.sum() < 30:
        return {}
    amp, area, lat = amp[ok], area[ok], lat[ok]
    # 100ms 격자에 같은 에폭이 반복 보고된다 → 값이 바뀌는 지점만 남겨 실제 에폭열로 만든다
    keep = np.r_[True, (np.diff(amp) != 0) | (np.diff(area) != 0)]
    amp, area, lat = amp[keep], area[keep], lat[keep]
    n = len(amp); third = max(n // 3, 1)
    idx = np.arange(n, dtype=float)
    def chg(a):
        f, l = float(np.median(a[:third])), float(np.median(a[-third:]))
        return f, l, ((l - f) / f * 100 if f else float("nan"))
    return dict(n=n, amp=chg(amp), area=chg(area), lat=chg(lat),
                rho_amp=spearman(idx, amp), rho_area=spearman(idx, area),
                series_amp=amp, series_area=area)

# ── 리포트 ──────────────────────────────────────────────────────────────────
def report(s, plot=False):
    print("=" * 74)
    print(f"세션 {s['stamp']}   ({os.path.basename(s['dir'])})")
    print("=" * 74)
    t, v = load_raw(s["raw"])
    env_rows = load_env(s["env"]) if "env" in s else []
    a = audit_timebase(t, env_rows, s.get("emg"))

    print(f"[1] 시간축")
    print(f"    raw 표본수        : {len(t):,}")
    print(f"    파일 공칭 dt/fs   : {a['nominal_dt']:.3f} ms  → {a['nominal_fs']:.0f} Hz")
    print(f"    파일이 주장한 길이: {a['dur_file']:.1f} s")
    if a["dur_env"]:  print(f"    env 기준 실제 길이: {a['dur_env']:.1f} s")
    if a["dur_wall"]: print(f"    wall clock 실제   : {a['dur_wall']:.1f} s")
    print(f"    실측 fs           : {a['actual_fs']:.0f} Hz")
    if np.isfinite(a["ratio"]) and abs(a["ratio"] - 1) > 0.05:
        print(f"    ⚠️  시간축 {a['ratio']:.2f}× 압축 — 파일 Time 열을 그대로 쓰면 "
              f"잠복·주파수가 {a['ratio']:.2f}배 틀린다. 아래는 실측 fs 로 재계산한 값.")
    fs = a["actual_fs"] if np.isfinite(a["actual_fs"]) else a["nominal_fs"]

    period_ms, ac = estimate_period(v, fs)
    peaks, thr, mad = detect_pulses(v, fs, period_ms)
    b = burst_structure(peaks, fs)
    print(f"\n[2] 자극 구조   (임계 {thr:.0f} ADC, MAD {mad:.0f}, "
          f"자기상관 주기 {period_ms:.1f} ms → {1000/period_ms:.2f} Hz, 강도 {ac:.2f})")
    if not b or b["n_pulses"] < 10:
        print(f"    펄스 {len(peaks)}개 — 자극 없음(또는 전극 미부착). M-wave 분석 생략.")
        print(f"    신호 범위 {v.min():.0f}~{v.max():.0f} (mean {v.mean():.0f}, sd {v.std():.0f})")
    else:
        print(f"    펄스 {b['n_pulses']}개 / 버스트 {b['n_bursts']}개")
        print(f"    펄스율 {b['pulse_rate']:.2f} Hz   버스트 주기 {b['burst_period']:.1f} ms   "
              f"버스트당 {b['pulses_per_burst']:.0f}발")
        E, sta, tax = sta_window(v, peaks, fs)
        if E is not None and len(E) > 20:
            m = mwave_trend(E, tax, fs)
            ctrl_n = int(1.0 * fs / 1000)   # 0~1ms 대조군에 들어오는 표본 수
            print(f"\n[3] M-wave  (시행 {m['n_trials']}, 잠복 실측 {m['latency_ms']:.1f} ms, "
                  f"대조군 포화 {m['ctrl_sat']:.1f}%)")
            for k in ("amp", "area", "R"):
                f_, l_, p_ = m[k]
                print(f"    {k:4s} 전1/3 {f_:9.1f} → 후1/3 {l_:9.1f}   {p_:+6.1f}%")
            print(f"    rho(진폭) {m['rho_amp']:+.2f}   rho(R=M/대조군) {m['rho_R']:+.2f}")
            if ctrl_n < 3:
                print(f"    ⚠️  대조군 창(0~1ms)에 표본이 {ctrl_n}개뿐 — R 정규화가 성립하지 않는다."
                      f" 이 fs 에서는 raw 기반 M-wave 판정을 하지 않는다.")
            else:
                verdict = ("피로 방향(감소)" if m["R"][2] < -15 and m["rho_R"] < -0.3 else
                           "증강 방향(증가)" if m["R"][2] > 15 and m["rho_R"] > 0.3 else "뚜렷한 추세 없음")
                print(f"    → {verdict}")
            if plot: draw(s, m, v, peaks, fs)

    h = env_hygiene(env_rows)
    if h:
        print(f"\n[4] env 위생   ({h['n']} 행)")
        print(f"    RMS 비영 {h['rms_nonzero']}/{h['n']}   MDF 비영 {h['mdf_nonzero']}/{h['n']}   "
              f"MW_Valid {h['mw_valid_pct']:.1f}%")
        print(f"    마커: {h['markers']}")
        if h["rms_nonzero"] == 0:
            print("    ⚠️  RMS/MDF 가 전부 0 — 펌웨어 지표 경로가 죽어 있다(파일엔 열만 남음).")
    em = env_mwave_trend(env_rows)
    if em:
        print(f"\n[5] env MW_* 추세  (기기 내부 계산, 에폭 {em['n']}개)")
        for k, lab in (("amp", "MW_Amp "), ("area", "MW_Area"), ("lat", "MW_Lat ")):
            f_, l_, p_ = em[k]
            print(f"    {lab} 전1/3 {f_:9.1f} → 후1/3 {l_:9.1f}   {p_:+6.1f}%")
        print(f"    rho(Amp) {em['rho_amp']:+.2f}   rho(Area) {em['rho_area']:+.2f}")
        pa = em["area"][2]
        v_ = ("피로 방향 (M-wave 면적 감소)" if pa < -15 and em["rho_area"] < -0.3 else
              "증강 방향 (면적 증가)" if pa > 15 and em["rho_area"] > 0.3 else "뚜렷한 추세 없음")
        print(f"    → {v_}")
    print()

def draw(s, m, v, peaks, fs):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    plt.rcParams["font.family"] = ["AppleGothic", "DejaVu Sans"]
    plt.rcParams["axes.unicode_minus"] = False
    fig, ax = plt.subplots(3, 1, figsize=(11, 9))
    n0 = peaks[0]; seg = slice(max(n0 - int(fs * 0.2), 0), n0 + int(fs * 2.0))
    ax[0].plot(np.arange(seg.start, seg.stop) / fs, v[seg], lw=.6)
    ax[0].set_title(f"{s['stamp']} raw 발췌 (실측 {fs:.0f} Hz)"); ax[0].set_xlabel("s")
    ax[1].plot(m["tax"], m["sta"], lw=1.2)
    ax[1].axvline(m["latency_ms"], color="r", ls="--", lw=.8)
    ax[1].set_title(f"자극정렬평균 STA — 잠복 {m['latency_ms']:.1f} ms"); ax[1].set_xlabel("ms")
    ax[2].plot(m["series_amp"], ".", ms=2, label="M-wave 진폭")
    ax[2].plot(m["series_R"] * np.nanmedian(m["series_amp"]) / np.nanmedian(m["series_R"]), ".", ms=2,
               label="R (스케일 맞춤)")
    ax[2].set_title("시행별 추세"); ax[2].set_xlabel("시행"); ax[2].legend()
    fig.tight_layout()
    out = os.path.join(s["dir"], f"check_{s['stamp']}.png")
    fig.savefig(out, dpi=110); plt.close(fig)
    print(f"    그림 → {out}")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=os.path.expanduser("~/emgfes-data"))
    ap.add_argument("--session", help="raw CSV 경로 직접 지정")
    ap.add_argument("--all", action="store_true", help="루트의 모든 세션")
    ap.add_argument("--last", type=int, default=1, help="최근 N개 세션")
    ap.add_argument("--plot", action="store_true")
    args = ap.parse_args()

    if args.session:
        st = STAMP.search(os.path.basename(args.session)).group(2)
        d = os.path.dirname(args.session)
        s = {"stamp": st, "dir": d, "raw": args.session}
        for k in ("env", "emg"):
            g = glob.glob(os.path.join(d, f"{k}_{st}*.csv"))
            if g: s[k] = g[0]
        sessions = [s]
    else:
        found = find_sessions(args.root)
        if not found:
            sys.exit(f"세션을 찾지 못했다: {args.root}")
        order = sorted(found, reverse=True)
        # emg 는 종료시각 이름 → 같은 폴더에서 시작시각 직후의 emg 를 붙인다
        for st in order:
            s = found[st]
            if "emg" not in s:
                cands = sorted(x for x in glob.glob(os.path.join(s["dir"], "emg_*.csv"))
                               if STAMP.search(os.path.basename(x)).group(2) > st)
                if cands: s["emg"] = cands[0]
        sessions = [found[k] for k in (order if args.all else order[: args.last])]

    print(f"\n대상 {len(sessions)}개 세션  (root={args.root})\n")
    for s in sessions:
        report(s, plot=args.plot)

if __name__ == "__main__":
    main()
