"""
mwave_analyzer.py — 엑셀/CSV 입력 → M-wave 피로 분석 결과 + 그래프 (자체완결형)
=================================================================================
RE:FIT · 완전마비 FES 근피로 분석

파일(엑셀/CSV) 하나 또는 폴더를 넣으면, 파일마다
  · <이름>_결과.xlsx   (요약 · 구간 · 레벨변화구간 · 버스트결과 · 설정 · [그래프] 시트)
  · <이름>_궤적.png    (정점 대비 피로 궤적 + 상한/하한 범위)
를 만들고, 파일이 여러 개면 '전체요약.xlsx'도 만든다.

── 패치 이력 ──────────────────────────────────────────
  [B] cycle_s 1.65 → 1.622 : 펌웨어 실측 버스트 주기에 격자 정렬(버스트 분할/점 중복 방지).
  [A] refractory → 27ms    : 하나의 자극이 2번 잡히던 이중검출 제거 + 펌웨어 값과 일치.
  [C] 스파이크 배제 위→양방향(Hampel) : 아래로 꺼진 고립 버스트도 제거, 추세는 보존.
  [D] 포화(클리핑) 검사 자리 교정 : +5~+12ms → 자극 골(0ms 근처) + 천장 railing 확인.
  [E] 정렬 trough→rising + 창 (5,12)→(2,15) + per-epoch off : M-wave 정점(+3ms)을 포함하게.
  ── 아래는 펌웨어(4kHz) 파라미터 정합 ──
  [FW1] 검출 문턱 고정400 → 적응형 clamp(400, 0.4×EMA, 1000)  (펌웨어 MW_ADAPT_*)
  [FW2] 유효성 SNR≥1.5 → M-wave p2p≥80  (펌웨어 MW_AMP_MIN). 피로기 CV 55%→9% 의 핵심.
  [FW3] 베이스라인 sliding 기본 + fixed(세션DC) 토글  (fixed 가 펌웨어와 동일; 둘 다 r≈0.17)
  [FW4] 면적 단위 Σ|·|×1000/fs 로 펌웨어와 일치(정규화라 궤적엔 무영향)
  [FW5] 포화검사 범위 → M-wave 창(2~15ms)만. 4kHz 검증서 발견: 스파이크가 ADC 천장
        (4095)에 레일링해도 M-wave 만 깨끗하면 유효 — 스파이크까지 보면 48% 오탈락.
  ── 배치 리뷰(12~14세션)에서 나온 재현 버그 수정 ──
  [리뷰BUG1] 적응형 문턱 데드락 : EMA0 cap/frac(초기문턱 1000) → floor/frac(초기문턱 400).
             최대 스파이크<1000 세션이 통째로 0검출되던 것 해결(실측 023422·152153).
  [리뷰BUG2] 정점을 전역 argmax 대신 초반창(peak_search_s=120s)에서만 탐색. 후반 봉우리가
             정점이 돼 세션 대부분이 '전위'로 지워지던 것(피로 검출 불가) 해결.
  [리뷰BUG3] 피로 하한>상한 역전("71~70%") : 구간기준을 전역과 같은 방식(정점±30s 중앙값)으로
             통일 + 하한≤상한 점별 클램프.
  [리뷰D3]   σ 사다리를 추세가 아닌 잡음(residual)으로 산정 → 주의·경고 동시발동 완화.
  [리뷰위생] 실패사유 3분리(자극0/유효0/버스트<5) · traceback 보존 · read_any 단위추정 견고화.
             (c0=k-2 는 [FW5]에서 이미 M-wave창 기준으로 교정됨)
─────────────────────────────────────────────────────────

── 사용법 ─────────────────────────────────────────────
  python mwave_analyzer.py  입력(파일 또는 폴더)  [출력폴더]
  Colab/파이썬:  from mwave_analyzer import run ;  run("파일 또는 폴더", "출력폴더")

── 입력 형식 ──────────────────────────────────────────
  · 확장자: .csv / .xlsx / .xls   · 열: 시간열(ms) + Raw ADC열(자동 인식)

── 설치 ───────────────────────────────────────────────
  pip install numpy scipy pandas openpyxl matplotlib pillow

── 규칙 요약 ──────────────────────────────────────────
  검출: 자극 검출 → 에폭 → M-wave 면적(+2~+15ms) → 배제(포화/SNR)
  집계: 1.622s 버스트 중앙값 + 스파이크 배제(양방향)
  판정: 정점(fresh 100%) 대비 σ 단계(주의/경고/위험) + 연속 확정 + 전위 제외 + 신뢰도 등급
  ★NEW 레벨변화(접촉/자세) 검출 → 구간별 재기준 → 피로도 '상한~하한' 범위 보고

  ※ M-wave 진폭 기반 지표라 드리프트와 미분리 · 단계임계는 관례값 · 힘/참조펄스 검증 필요.
  ※ 구간별(하한)은 경계 인공물로 과소평가 쪽 → 실제값은 상한과 하한 사이로 해석.
"""

from __future__ import annotations

import os
import sys
import glob
import warnings
from dataclasses import dataclass, asdict

import numpy as np
from scipy.signal import find_peaks
from scipy.ndimage import median_filter


# =====================================================================
# 설정
# =====================================================================
@dataclass
class Config:
    # --- M-wave 검출 ---
    stim_neg_thresh: float = 400.0
    refractory_ms: float = 27.0   # [FIX A→E] 25 → 27ms. 펌웨어 MW_REFRACTORY_MS 와 일치.
                                  # 실측 자극주기 31.185ms(32.078Hz)보다 짧고 아티팩트 폭
                                  # ~18ms보다 길어 모든 자극을 잡되 에코는 배제.
    # [FIX E] 정렬점: "rising"(자극 상승엣지, 펌웨어와 동일) | "trough"(옛날: 자극 최저점)
    #   펌웨어 STA 실측상 M-wave 양의 정점은 자극 '시작' +3ms 에 있다. 최저점(trough)은
    #   시작보다 ~2ms 뒤라, trough 정렬 시 창이 통째로 밀려 M-wave 정점을 놓치고 자극
    #   회복 꼬리를 잰다(그 결과 면적이 자극 크기와 r=0.73 로 붙어버림). rising 으로 맞추면
    #   1kHz 에서도 +2~+3ms 에 양의 M-wave 정점이 드러나고 자극과 분리된다(r≈0).
    align_mode: str = "rising"
    # [FW] rising 검출 문턱: 적응형(펌웨어 MW_ADAPT_*) 사용 여부. 문턱=clamp(floor, frac×EMA, cap).
    #   자극 스파이크가 작아져도(전극/세기 변화) 최근 스파이크로 문턱을 낮춰 검출을 놓치지 않는다.
    #   실측 검출수: 적응형 7144 vs 고정400 6994 (≈동등, 펌웨어 재현용).
    adaptive_thresh: bool = True
    adapt_frac: float = 0.4
    adapt_floor: float = 400.0
    adapt_cap: float = 1000.0
    adapt_alpha: float = 0.2
    epoch_pre_ms: float = 20.0
    epoch_post_ms: float = 30.0
    # [FIX E] per-epoch 영점보정 기본 off. 31ms 간격에선 자극 전 창(-17~-8ms)이 앞 펄스
    #   여운 위라 오히려 오염원이었다(실측 편향 +259, CV 71%→64% 는 이걸 끄면 개선).
    #   2초 슬라이딩 베이스라인이 느린 드리프트는 이미 제거한다.
    per_epoch_baseline: bool = False
    epoch_baseline_ms: tuple = (-17.0, -8.0)   # per_epoch_baseline=True 일 때만 사용
    mwave_win_ms: tuple = (2.0, 15.0)   # [FIX E] (5,12)→(2,15). 펌웨어 실측 M-wave: 정점 +3ms,
                                        # 양+음 이상성분이 ~+2~+15ms. 정점을 포함하도록 +2 부터.
    silence_win_ms: tuple = (18.0, 27.0)   # M-wave 종료(~15ms)~다음자극(~30ms) 사이 깨끗한 잡음창
    snr_min: float = 1.5
    # [FW] 유효성 기준: "amp"=M-wave p2p >= amp_min(펌웨어 MW_AMP_MIN=80) | "snr"=옛날 SNR>=snr_min.
    #   옛 SNR 게이트는 '자극 꼬리 기울기'를 재서 피로한(작은 M-wave) 구간을 과도하게 버렸다
    #   → 버스트당 유효펄스가 3~5개로 줄어 버스트 중앙값이 출렁(실측 피로기 CV 55%).
    #   p2p 기준은 진짜 잡음(무자극)만 걸러 유효율 100%, 버스트가 조밀해져 CV 9% 로 안정.
    validity_mode: str = "amp"
    amp_min: float = 80.0
    adc_floor: float = 1.0
    adc_ceil: float = 4094.0      # [FIX D] 천장(railing) 클리핑 검사 임계(12-bit 기준)
    # [FW] M-wave 면적을 펌웨어 단위(Σ|·|×1000/fs = ADC·ms)로 맞춘다. 궤적은 정점 정규화라 무관.
    area_scale_fw: bool = True
    # --- 베이스라인 ---
    # [FW] "sliding"=2초 중앙값(느린 임피던스 드리프트 제거, analyzer 고유) |
    #      "fixed"=세션 고정DC=전체 중앙값(펌웨어와 동일; 실측 median=1862=펌웨어 fallback).
    #   실측상 둘 다 자극×M-wave r≈0.17 로 분리 성능 동등 → sliding 이 드리프트까지 없애 기본값.
    #   펌웨어와 완전히 동일하게 재현하려면 "fixed".
    baseline_mode: str = "sliding"
    baseline_win_s: float = 2.0
    # --- 버스트 집계 ---
    cycle_s: float = 1.622        # 펌웨어 실측 버스트 주기 1621.9ms 에 정렬(σ=0.58ms, 세션드리프트 0.3ms).
                                  # 1.65 였을 때: 격자가 버스트당 28ms 씩 밀려 ~90s+ 세션에서 한 버스트가
                                  # 두 bin 으로 쪼개짐(궤적 점 중복·중앙값 흔들림). 주기와 같게 두면 격자가
                                  # 버스트에 락돼 매 bin 이 정확히 버스트 1개를 담는다.
    min_pulses_per_burst: int = 3
    burst_spike_factor: float = 2.5   # [FIX C] 극단적 상방 튐 안전망(양방향 Hampel과 병행)
    hampel_nsigma: float = 4.0        # [FIX C] 양방향 고립 튐(Hampel) 판정 배수
    smooth_bursts: int = 21
    ref_window_s: float = 30.0
    # [리뷰BUG2] 정점(fresh 기준)을 찾는 창을 초반으로 제한. 전위상승은 초반 수십초에 끝난다.
    #   전역 argmax 를 쓰면 세션 후반의 접촉변화/잡음 봉우리가 정점이 되고, 그 이전(세션 대부분)이
    #   '전위'로 분류돼 강제 stage 0 → 피로 검출이 구조적으로 불가능했다(정점 91% 지점 사례).
    peak_search_s: float = 120.0
    # --- 판정 단계(정점 대비 하락 %) ---
    stage_caution: float = 15.0
    stage_warning: float = 30.0
    stage_danger: float = 50.0
    run_length: int = 3
    # --- 임계 방식: "sigma"(기본) | "percent" ---
    threshold_mode: str = "sigma"
    sigma_caution: float = 1.0
    sigma_warning: float = 2.0
    sigma_danger: float = 3.0
    cv_floor_pct: float = 8.0
    # --- 신뢰도 등급(유효 M-wave %) ---
    reliab_high: float = 95.0      # valid_pct 이 %↑ → 기본등급 높음
    reliab_mid: float = 80.0       # valid_pct 이 %↑(reliab_high 미만) → 기본등급 보통, 미만이면 낮음
    stab_nlevel_warn: int = 1      # 레벨변화 개수 이 개↑ → 1단계 강등
    stab_nlevel_bad: int = 2       # 레벨변화 개수 이 개↑ → 2단계 강등
    stab_recov_warn: float = 30.0  # 상방회복 이 %↑ → 1단계 강등
    stab_recov_bad: float = 60.0   # 이 %↑ → 낮음
    # --- ★NEW 레벨변화(접촉/자세) 검출 & 범위 보고 ---
    level_detect: bool = True            # 레벨변화 검출 on/off
    level_win_bursts: int = 6            # 계단 판정용 좌/우 비교 창(버스트 수)
    level_step_pct: float = 25.0         # 국소 중앙값이 이 %↑ 계단이면 경계 후보
    level_min_seg_bursts: int = 8        # 경계 간 최소 간격(과분할 방지)
    level_flag_jump_pct: float = 30.0    # 세션 '레벨변화 의심' 플래그: 이 %p↑ 급변이 있으면
    level_step_win_s: float = 32.0       # (참고) 이 시간보다 빠른 하락은 생리적 피로가 아님

STAGE_NAMES = {0: "정상", 1: "주의", 2: "경고", 3: "위험"}


# =====================================================================
# 한글 폰트 자동 설정 (Windows / macOS / Linux·Colab 공통)
# =====================================================================
def _set_korean_font():
    import matplotlib.pyplot as plt
    import matplotlib.font_manager as fm
    # 1) 대표 폰트 파일 경로를 OS별로 시도
    paths = [
        r"C:\Windows\Fonts\malgun.ttf",                          # Windows 맑은 고딕
        r"C:\Windows\Fonts\malgunsl.ttf",
        "/System/Library/Fonts/Supplemental/AppleGothic.ttf",    # macOS
        "/Library/Fonts/AppleGothic.ttf",
        "/usr/share/fonts/truetype/nanum/NanumGothic.ttf",       # Linux / Colab
    ]
    for p in paths:
        if os.path.exists(p):
            try:
                fm.fontManager.addfont(p)
                plt.rcParams["font.family"] = fm.FontProperties(fname=p).get_name()
                plt.rcParams["axes.unicode_minus"] = False
                return
            except Exception:
                pass
    # 2) 파일을 못 찾으면 설치된 폰트 이름으로 시도
    for name in ["Malgun Gothic", "AppleGothic", "Apple SD Gothic Neo",
                 "NanumGothic", "Noto Sans CJK KR", "Noto Sans KR"]:
        try:
            if any(f.name == name for f in fm.fontManager.ttflist):
                plt.rcParams["font.family"] = name
                plt.rcParams["axes.unicode_minus"] = False
                return
        except Exception:
            pass
    # 3) 그래도 없으면 최소한 마이너스 기호만 정상화
    plt.rcParams["axes.unicode_minus"] = False


# =====================================================================
# 입력 로드 (CSV / XLSX / XLS)  → (t_s, adc, fs)
# =====================================================================
def read_any(path: str) -> tuple[np.ndarray, np.ndarray, int]:
    ext = os.path.splitext(path)[1].lower()
    if ext in (".xlsx", ".xls"):
        import pandas as pd
        df = pd.read_excel(path, sheet_name=0)
    elif ext in (".csv", ".txt", ".tsv"):
        import pandas as pd
        sep = "\t" if ext == ".tsv" else ","
        df = pd.read_csv(path, sep=sep)
    else:
        raise ValueError(f"지원하지 않는 형식: {ext} (csv/xlsx/xls만)")

    cols = {str(c).strip().lower(): c for c in df.columns}
    def find(keys):
        for k, orig in cols.items():
            if any(kk in k for kk in keys):
                return orig
        return None
    tcol = find(["time", "ms", "시간"])
    acol = find(["adc", "raw", "emg", "값"])
    if tcol is None or acol is None:
        tcol, acol = df.columns[0], df.columns[1]

    t_ms = df[tcol].to_numpy(dtype=float)
    adc = df[acol].to_numpy(dtype=float)
    m = np.isfinite(t_ms) & np.isfinite(adc)
    t_ms, adc = t_ms[m], adc[m]

    dt = np.median(np.diff(t_ms))
    if dt <= 0:
        raise ValueError("시간열이 단조증가가 아닙니다.")
    tname = str(tcol).lower()
    # [리뷰-코드위생] 단위(ms/s) 판정: 컬럼명 우선, 모호하면 dt 크기로 추정.
    #   예전 'dt>=0.5 → 초' 규칙은 2kHz(dt=0.5ms)를 초로 오인할 소지가 있었다. 실측 EMG fs 는
    #   대략 100~20kHz → ms 단위면 dt=0.05~10, 초 단위면 dt≤~0.004 라 0.02 를 경계로 겹치지 않는다.
    name_ms = ("ms" in tname) or ("milli" in tname)
    name_s = (not name_ms) and (tname.endswith("(s)") or tname.endswith("_s") or "sec" in tname)
    if name_ms:
        unit_is_s = False
    elif name_s:
        unit_is_s = True
    else:
        unit_is_s = dt < 0.02          # 이름 모호 → dt 로 추정(작으면 초 단위)
    if unit_is_s:
        t_ms = t_ms * 1000.0
        dt = dt * 1000.0
    fs = int(round(1000.0 / dt))
    return t_ms / 1000.0, adc, fs


# =====================================================================
# 파이프라인
# =====================================================================
def _baseline(adc, fs, win_s):
    n = len(adc); w = max(int(win_s * fs), 1)
    c = np.arange(w // 2, n, max(w // 2, 1))
    med = np.array([np.median(adc[max(0, i - w // 2): i + w // 2]) for i in c])
    return np.interp(np.arange(n), c, med)


def _detect_stimuli(sig, fs, cfg):
    refr = max(int(cfg.refractory_ms * fs / 1000), 1)
    if cfg.align_mode == "trough":
        # 옛날 방식: 자극 최저점(음의 봉우리). M-wave 정점을 ~2ms 놓친다(하위호환용).
        stim, _ = find_peaks(-sig, height=cfg.stim_neg_thresh, distance=refr)
        return stim
    # [FIX E] 펌웨어 방식: |신호|가 문턱을 처음 넘는 '상승엣지'를 자극 시작(t=0)으로 잡는다.
    a = np.abs(sig)
    if not cfg.adaptive_thresh:
        # 고정 문턱 상승엣지 (하위호환)
        over = a > cfg.stim_neg_thresh
        onset = np.where(over[1:] & ~over[:-1])[0] + 1   # False→True 전이 지점
        out = []; last = -10**9
        for k in onset:
            if k - last > refr:
                out.append(int(k)); last = int(k)
        return np.asarray(out, dtype=int)
    # [FW] 적응형 문턱 상승엣지 (펌웨어 재현). 문턱=clamp(floor, frac×EMA, cap),
    #   자극 스파이크 peak 로 EMA 를 갱신한다. floor 넘는 표본만 순회 → 전구간 루프보다 빠름.
    frac, floor, cap, alpha = cfg.adapt_frac, cfg.adapt_floor, cfg.adapt_cap, cfg.adapt_alpha
    # [리뷰BUG1] EMA0 를 floor/frac 로 시작 → 초기 문턱 = floor(400). 예전 cap/frac(=2500)은
    #   초기 문턱을 cap(1000)에서 출발시켰는데, EMA 는 '검출 성공' 후에만 갱신되므로 세션 최대
    #   스파이크가 1000 미만이면 영원히 0개 + 문턱도 안 내려오는 데드락이었다(실측 023422:
    #   max|신호|949 → 적응형 0개 / 고정400 958개). floor 에서 시작하면 데드락이 불가능하다.
    ema = (floor / frac) if frac > 0 else floor   # EMA0: 초기 문턱 = floor(400)
    look = max(int(round(2 * fs / 1000)), 1)      # 스파이크 peak 탐색창 ~2ms
    cand = np.where(a > floor)[0]
    out = []; last = -10**9
    for k in cand:
        thr = min(max(frac * ema, floor), cap)
        if a[k] > thr and (k - last) > refr:
            ema = alpha * float(a[k:k + look].max()) + (1.0 - alpha) * ema
            out.append(int(k)); last = int(k)
    return np.asarray(out, dtype=int)


def _pulse_features(sig, adc, stim, fs, cfg):
    pre = int(round(cfg.epoch_pre_ms * fs / 1000))
    post = int(round(cfg.epoch_post_ms * fs / 1000))
    def ms_i(ms): return pre + int(round(ms * fs / 1000))
    m0, m1 = ms_i(cfg.mwave_win_ms[0]), ms_i(cfg.mwave_win_ms[1])
    s0, s1 = ms_i(cfg.silence_win_ms[0]), ms_i(cfg.silence_win_ms[1])
    b0, b1 = ms_i(cfg.epoch_baseline_ms[0]), ms_i(cfg.epoch_baseline_ms[1])   # 영점 구간

    n = len(stim)
    t = stim / fs
    area = np.full(n, np.nan); vpp = np.full(n, np.nan)
    svpp = np.full(n, np.nan); sat = np.zeros(n, bool)
    m0_off = int(round(cfg.mwave_win_ms[0] * fs / 1000))   # [FW/4kHz] M-wave 창 시작(+2ms)
    m1_off = int(round(cfg.mwave_win_ms[1] * fs / 1000))   # M-wave 창 끝(+15ms)
    for i, k in enumerate(stim):
        if k - pre < 0 or k + post >= len(sig):
            continue
        ep = sig[k - pre: k + post + 1].astype(float)
        if cfg.per_epoch_baseline:   # [FIX E] 기본 off (앞 펄스 여운 오염 회피)
            ep -= np.median(ep[b0:b1 + 1])
        mw = ep[m0:m1 + 1]; cw = ep[s0:s1 + 1]
        area[i] = np.abs(mw).sum() * (1000.0 / fs if cfg.area_scale_fw else 1.0)
        vpp[i] = mw.max() - mw.min()   # = 펌웨어 currentMwAmp (p2p)
        svpp[i] = cw.max() - cw.min()
        # [FW/4kHz] 포화(클리핑)는 M-wave 측정창(2~15ms) 안에서만 검사한다.
        #   4kHz 에선 자극 스파이크(0~1ms)가 날카로워 ADC 천장(4095)에 레일링하는데,
        #   그건 M-wave(2~15ms)와 무관하다. 스파이크 구간까지 보면 멀쩡한 M-wave 를
        #   통째로 버려(실측 4kHz 48% 오탈락). 창 안이 레일에 붙었을 때만 무효로 본다.
        c0 = max(k + m0_off, 0)
        c1 = min(k + m1_off, len(adc) - 1)
        seg = adc[c0:c1 + 1]
        sat[i] = bool((seg <= cfg.adc_floor).any() or (seg >= cfg.adc_ceil).any())
    with np.errstate(divide="ignore", invalid="ignore"):
        snr = vpp / np.where(svpp > 1, svpp, np.nan)
    if cfg.validity_mode == "amp":
        valid = (~np.isnan(area)) & (~sat) & (vpp >= cfg.amp_min)   # [FW] p2p>=80
    else:
        valid = (~np.isnan(area)) & (~sat) & (snr >= cfg.snr_min)   # 옛날 SNR 게이트
    return dict(t=t, area=area, vpp=vpp, snr=snr, sat=sat, valid=valid)


def _aggregate_bursts(feat, cfg):
    v = feat["valid"]; t = feat["t"][v]; a = feat["area"][v]
    if len(t) == 0:
        return np.array([]), np.array([]), 0
    cid = np.floor(t / cfg.cycle_s).astype(int)
    bt, bval = [], []
    for c in np.unique(cid):
        m = cid == c
        if m.sum() < cfg.min_pulses_per_burst:
            continue
        bt.append(t[m].mean()); bval.append(np.median(a[m]))
    bt = np.asarray(bt); bval = np.asarray(bval)
    if len(bval) < 5:
        return bt, bval, 0
    # [FIX C] 스파이크 제거: 위·아래 양방향(Hampel). 고립된 튐만 제거, 점진적 추세(진짜 피로
    #   하락)는 보존. roll=지역 중앙값, MAD=지역 편차 → nσ 벗어난 고립점만 제거.
    #   MAD가 0에 붙는 평탄 구간 보호를 위해 roll 의 10% 를 하한으로 둔다.
    #   극단적 상방 튐(원본 규칙: >2.5×roll)은 안전망으로 병행 유지.
    k = min(cfg.smooth_bursts, len(bval) | 1)
    roll = median_filter(bval, size=k, mode="nearest")
    dev = np.abs(bval - roll)
    mad = median_filter(dev, size=k, mode="nearest")
    thr = cfg.hampel_nsigma * np.maximum(1.4826 * mad, 0.10 * np.maximum(roll, 1e-9))
    spike = (dev > thr) | (bval > roll * cfg.burst_spike_factor)
    return bt[~spike], bval[~spike], int(spike.sum())


def _peak_reference(bt, bval, cfg):
    sm = median_filter(bval, size=min(cfg.smooth_bursts, len(bval) | 1), mode="nearest")
    # [리뷰BUG2] 정점은 초반 전위상승 창(peak_search_s) 안에서만 찾는다(전역 argmax 금지).
    #   창 안에 버스트가 3개 미만이면(아주 짧은 세션) 전체에서 찾는다.
    swin = bt <= bt[0] + cfg.peak_search_s
    if swin.sum() < 3:
        swin = np.ones(len(bt), bool)
    idx = np.where(swin)[0]
    pk = int(idx[np.argmax(sm[idx])]); peak_t = float(bt[pk])
    win = np.abs(bt - peak_t) <= cfg.ref_window_s
    ref = float(np.median(bval[win])) if win.sum() >= 3 else float(sm[pk])
    return ref, peak_t, sm


def _judge(bt, bval, ref, ref_sigma, peak_t, cfg):
    pct = bval / ref * 100.0 if ref else np.full_like(bval, np.nan)
    fatigue = np.clip(100.0 - pct, 0.0, None)
    phase = np.where(bt < peak_t, "전위", "피로")
    stage = np.zeros(len(bval), int)
    if cfg.threshold_mode == "sigma" and ref:
        sd_eff = max(ref_sigma, cfg.cv_floor_pct / 100.0 * ref)
        fat_sig = (ref - bval) / sd_eff
        stage[fat_sig >= cfg.sigma_caution] = 1
        stage[fat_sig >= cfg.sigma_warning] = 2
        stage[fat_sig >= cfg.sigma_danger] = 3
    else:
        stage[fatigue >= cfg.stage_caution] = 1
        stage[fatigue >= cfg.stage_warning] = 2
        stage[fatigue >= cfg.stage_danger] = 3
    stage[phase == "전위"] = 0
    return pct, fatigue, phase, stage


# =====================================================================
# ★NEW 레벨변화(접촉/자세) 검출 + 구간별 재기준(하한)
# =====================================================================
def _detect_level_changes(bt, bval, cfg, peak_t=None):
    """접촉/자세로 인한 '빠르고 큰 계단' 경계를 찾는다.
    [PATCH P1] 정점(peak_t) 이전 전위 구간은 활성후증강 스윙이 커서 레벨변화로
    오검출된다(174817: 전위 스윙이 46%p 허위 플래그를 유발). 피로 국면에서만 탐색한다."""
    n = len(bval)
    w = cfg.level_win_bursts
    strength = np.zeros(max(n, 0))
    if (not cfg.level_detect) or n < 2 * w + 1:
        return [], strength
    for i in range(w, n - w):
        if peak_t is not None and bt[i] < peak_t:   # ★ P1: 전위 구간 스킵
            continue
        left = np.median(bval[i - w:i])
        right = np.median(bval[i:i + w])
        base = left if left > 1e-9 else 1e-9
        strength[i] = abs(right - left) / base
    peaks, _ = find_peaks(strength,
                          height=cfg.level_step_pct / 100.0,
                          distance=max(cfg.level_min_seg_bursts, 1))
    refined = []
    for p in peaks:
        lo, hi = max(int(p) - w, 1), min(int(p) + w, n)
        if hi - lo < 2:
            refined.append(int(p)); continue
        d = np.abs(np.diff(bval[lo - 1:hi]))
        refined.append(int(lo + int(np.argmax(d))))
    out = []
    for j in sorted(set(refined)):
        if not out or (j - out[-1]) >= cfg.level_min_seg_bursts:
            out.append(j)
    if peak_t is not None:                            # ★ P1: 정밀화가 정점 이전으로
        out = [j for j in out if bt[j] >= peak_t]     #      넘어갈 수 있어 최종 필터
    return out, strength

def _segment_fatigue(bt, bval, boundaries, peak_t, cfg):
    """구간(경계 사이)마다 자기 국소 정점으로 다시 재서 '하한' 피로도를 만든다."""
    n = len(bval)
    edges = sorted(set([0] + [b for b in boundaries if 0 < b < n] + [n]))
    seg_ref = np.full(n, np.nan)
    seg_id = np.zeros(n, int)
    seg_info = []
    for s in range(len(edges) - 1):
        a, b = edges[s], edges[s + 1]
        if b <= a:
            continue
        block = bval[a:b]; btb = bt[a:b]
        if len(block) >= 3:
            smb = median_filter(block, size=min(cfg.smooth_bursts, len(block) | 1), mode="nearest")
            lp = int(np.argmax(smb))                       # 구간 국소 정점
            w = np.abs(btb - btb[lp]) <= cfg.ref_window_s
            # [리뷰BUG3] 전역 기준과 같은 방식(정점±30s 중앙값)으로 통일 → 통계 불일치 역전 방지.
            ref = float(np.median(block[w])) if w.sum() >= 3 else float(smb[lp])
        else:
            ref = float(np.max(block))
        seg_ref[a:b] = ref if ref > 1e-9 else 1e-9
        seg_id[a:b] = s + 1
    with np.errstate(divide="ignore", invalid="ignore"):
        seg_pct = bval / seg_ref * 100.0
    seg_fatigue = np.clip(100.0 - seg_pct, 0.0, None)
    seg_fatigue[bt < peak_t] = 0.0        # 전위(준비운동) 구간은 피로 아님 → 0
    # 구간 요약(구간내 최대 피로 포함)
    for s in range(len(edges) - 1):
        a, b = edges[s], edges[s + 1]
        if b <= a:
            continue
        seg_info.append(dict(구간번호=s + 1,
                             시작s=round(float(bt[a]), 1),
                             종료s=round(float(bt[b - 1]), 1),
                             버스트수=int(b - a),
                             구간정점값=round(float(seg_ref[a])),
                             구간내최대피로pct=round(float(np.max(seg_fatigue[a:b])), 1)))
    return seg_pct, seg_fatigue, seg_id, seg_info, edges


def _level_flag(bt, bval, global_ref, boundaries, cfg):
    """세션이 '레벨변화 의심'인지: 경계에서 피로 %p가 크게 급변하면 플래그."""
    if global_ref <= 0 or not boundaries:
        return False, 0.0, 0
    w = cfg.level_win_bursts; n = len(bval)
    max_jump = 0.0; n_fast = 0
    for j in boundaries:
        left = np.median(bval[max(j - w, 0):j])
        right = np.median(bval[j:min(j + w, n)])
        f_left = 100.0 * (1 - left / global_ref)
        f_right = 100.0 * (1 - right / global_ref)
        jump = abs(f_right - f_left)          # 피로 %p 급변 크기
        max_jump = max(max_jump, jump)
        if jump >= cfg.level_flag_jump_pct:   # 경계는 이미 '빠른 계단'이므로 크기만 본다
            n_fast += 1
    return (n_fast > 0), float(max_jump), int(n_fast)
def _reliability_tier(valid_pct, boundaries, bt, sm, ref, peak_t, cfg):
    """[PATCH P2] 신뢰도 = 유효 M-wave%(진폭 검출률) + 궤적 안정성.
    검출률만 보면 매 펄스에 M-wave가 잡히기만 하면 '높음'이라, 진폭이 절반↔정점 폭으로
    출렁이는 불안정 세션(182304·173058)도 '높음'으로 나온다. 두 지표로 강등:
      (a) 피로국면 레벨변화(계단) 수  (b) 피로국면 상방회복량(피로는 회복하지 않음)."""
    base = 0 if valid_pct >= cfg.reliab_high else (1 if valid_pct >= cfg.reliab_mid else 2)
    n_lvl = len(boundaries)
    recov = 0.0
    if ref > 0:
        fm = bt >= peak_t
        if int(np.sum(fm)) >= 3:
            s = sm[fm]
            run_min = np.minimum.accumulate(s)
            recov = float(np.max((s - run_min) / ref * 100.0))
    demote = 0
    if n_lvl >= cfg.stab_nlevel_warn or recov >= cfg.stab_recov_warn:
        demote = 1
    if n_lvl >= cfg.stab_nlevel_bad or recov >= cfg.stab_recov_bad:
        demote = 2
    names = ["높음", "보통", "낮음"]
    reason = []
    if demote > 0:
        if n_lvl >= cfg.stab_nlevel_warn:
            reason.append(f"피로국면 레벨변화 {n_lvl}개")
        if recov >= cfg.stab_recov_warn:
            reason.append(f"상방회복 {recov:.0f}%")
    return names[min(base + demote, 2)], names[base], round(recov, 1), (" · ".join(reason) if reason else "-")

def _confirmed_onset_idx(stage, lvl, run):
    meets = stage >= lvl
    for i in range(len(stage) - run + 1):
        if meets[i:i + run].all():
            return i
    return None


def _segments(bt, pct, phase, stage, peak_t, cfg):
    n = len(bt)
    conf = np.zeros(n, int)
    onset_t = {}
    for lvl in (1, 2, 3):
        i = _confirmed_onset_idx(stage, lvl, cfg.run_length)
        if i is not None:
            conf[i:] = lvl
            onset_t[lvl] = float(bt[i])
        else:
            onset_t[lvl] = None
    labels = np.array(["전위" if phase[i] == "전위" else STAGE_NAMES[conf[i]] for i in range(n)])
    segs = []; s = 0
    for i in range(1, n + 1):
        if i == n or labels[i] != labels[s]:
            start = float(bt[s]); end = float(bt[i]) if i < n else float(bt[-1])
            segs.append(dict(구간=str(labels[s]), 시작s=round(start, 1), 종료s=round(end, 1),
                             지속s=round(end - start, 1), 버스트수=int(i - s),
                             대표_정점대비pct=round(float(np.median(pct[s:i])), 1)))
            s = i
    return segs, labels, onset_t


def analyze(t_s, adc, fs, cfg: Config = None) -> dict:
    cfg = cfg or Config()
    try:
        if cfg.baseline_mode == "fixed":
            base = np.full(len(adc), float(np.median(adc)))   # [FW] 세션 고정DC(=중앙값)
        else:
            base = _baseline(adc, fs, cfg.baseline_win_s)     # 2초 슬라이딩(드리프트 제거)
        sig = adc - base
        stim = _detect_stimuli(sig, fs, cfg)
        # [리뷰-코드위생] 실패 사유를 세 갈래로 분리(자극0 / 유효0 / 버스트<5)해 원인을 드러낸다.
        #   예전엔 셋 다 "유효 버스트 부족"으로 뭉뚱그려 데드락(자극0)을 못 알아챘다.
        if len(stim) == 0:
            return dict(ok=False, reason="자극 미검출 0개 (검출 문턱·정렬 확인 / 적응형 데드락 여부)",
                        n_stim=0, valid_pct=0.0)
        feat = _pulse_features(sig, adc, stim, fs, cfg)
        n_valid = int(np.nansum(feat["valid"]))
        if n_valid == 0:
            return dict(ok=False, reason="유효 M-wave 0개 (포화·유효성 기준 확인)",
                        n_stim=int(len(stim)), valid_pct=0.0)
        bt, bval, n_spike = _aggregate_bursts(feat, cfg)
        if len(bt) < 5:
            return dict(ok=False,
                        reason=f"유효 버스트 부족 {len(bt)}<5 (자극 {len(stim)}개·유효펄스 {n_valid}개)",
                        n_stim=int(len(stim)), valid_pct=float(np.nanmean(feat["valid"]) * 100))
        ref, peak_t, sm = _peak_reference(bt, bval, cfg)
        win = np.abs(bt - peak_t) <= cfg.ref_window_s
        # [리뷰D3] σ 사다리는 '잡음'으로 재야 한다. 예전 std(bval[win]) 는 정점±30s 의 상승→하락
        #   곡률(추세)을 재서 σ 가 부풀었다(주의·경고 onset 이 같은 시각에 발동). 평활(추세)을 빼
        #   residual(버스트간 잡음)로 σ 를 잡는다. cv_floor_pct 가 하한을 지킨다.
        ref_sigma = float(np.std(bval[win] - sm[win], ddof=1)) if win.sum() >= 3 else 0.0
        pct, fatigue, phase, stage = _judge(bt, bval, ref, ref_sigma, peak_t, cfg)
        valid_pct = float(feat["valid"].mean() * 100)
        # [PATCH P1] 정점 이후 피로국면에서만 계단 탐색(전위 오검출 제거)
        boundaries, strength = _detect_level_changes(bt, bval, cfg, peak_t)
        # [PATCH P2] 등급 = 검출률 + 궤적 안정성(레벨변화 수·상방회복)
        tier, tier_base, recov_pct, tier_reason = _reliability_tier(
            valid_pct, boundaries, bt, sm, ref, peak_t, cfg)
        segs, seg_labels, onset = _segments(bt, pct, phase, stage, peak_t, cfg)
        seg_pct, seg_fatigue, seg_id, seg_info, seg_edges = _segment_fatigue(
            bt, bval, boundaries, peak_t, cfg)
        # [리뷰BUG3] 하한(구간별)은 상한(전역)을 넘을 수 없다 — 점별 클램프로 보장.
        #   두 기준의 통계가 달라 "71~70%" 처럼 역전되던 표기를 원천 차단한다.
        seg_fatigue = np.minimum(seg_fatigue, fatigue)
        upper_max = float(np.max(fatigue))          # 세션 전체 기준 = 상한
        lower_max = min(float(np.max(seg_fatigue)), upper_max)   # 구간별 기준 = 하한(≤상한)
        level_flag, max_jump, n_fast = _level_flag(bt, bval, ref, boundaries, cfg)

        return dict(ok=True, fs=fs, cfg=cfg,
                    burst_t=bt, mwave=bval, smooth=sm, pct=pct,
                    fatigue=fatigue, phase=phase, stage=stage,
                    reference=ref, reference_t=peak_t, ref_sigma=ref_sigma,
                    n_stim=int(len(stim)), valid_pct=valid_pct, n_burst=int(len(bt)),
                    n_spike=n_spike, n_sat=int(feat["sat"].sum()),
                    end_pct=float(pct[-1]), tier=tier, onset=onset,
                    segments=segs, burst_seg=seg_labels, fatigue_start_t=onset[1],
                    dur_s=float(t_s[-1]),
                    # ★NEW
                    boundaries=boundaries, seg_pct=seg_pct, seg_fatigue=seg_fatigue,
                    seg_id=seg_id, seg_info=seg_info, seg_edges=seg_edges,
                    upper_max=upper_max, lower_max=lower_max,
                    level_flag=level_flag, n_level=len(boundaries),
                    max_jump=max_jump, n_fast_jump=n_fast)
    except Exception as e:
        import traceback
        # [리뷰-코드위생] traceback 을 삼키지 않는다. 마지막 3줄을 함께 돌려 원인을 남긴다.
        return dict(ok=False, reason=f"오류: {type(e).__name__}: {e}",
                    trace=traceback.format_exc().splitlines()[-3:])


# =====================================================================
# 그림 (정점 대비 % 궤적 + 피로 지표 상한/하한 범위)
# =====================================================================
def plot_result(res: dict, out_png: str):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    _set_korean_font()   # ★ Windows/Mac/Linux 공통 한글 폰트
    cfg = res["cfg"]; bt = res["burst_t"]; pct = res["pct"]; fatg = res["phase"] == "피로"
    bnd = res.get("boundaries", [])
    fig, ax = plt.subplots(2, 1, figsize=(12, 7.5), sharex=True,
                           gridspec_kw={"height_ratios": [2, 1]})
    # ── 상단: 정점 대비 % 궤적 ──
    ax[0].plot(bt, pct, color="#c9dfd9", lw=0.9)
    ax[0].plot(bt[~fatg], pct[~fatg], color="#0F6E56", lw=2.2, label="전위 국면")
    ax[0].plot(bt[fatg], pct[fatg], color="#BA7517", lw=2.2, label="피로 국면")
    ax[0].axhline(100, color="#c62828", ls="--", lw=1)
    ax[0].scatter([res["reference_t"]], [100], color="#c62828", s=55, zorder=5)
    on = res["onset"]
    for lvl, col in ((1, "#555"), (2, "#d08"), (3, "#a00")):
        if on[lvl] is not None:
            ax[0].axvline(on[lvl], color=col, ls="-", lw=1.2, alpha=0.55)
    # ★NEW 레벨변화 경계선
    for bi, b in enumerate(bnd):
        ax[0].axvline(bt[b], color="#7B1FA2", ls="-.", lw=1.1, alpha=0.6,
                      label="레벨변화(접촉/자세)?" if bi == 0 else None)
    if on[1] is not None:
        ax[0].annotate("피로 시작", xy=(on[1], 100), xytext=(on[1], 118),
                       ha="center", color="#333", fontsize=9,
                       arrowprops=dict(arrowstyle="->", color="#555"))
    if cfg.threshold_mode == "sigma":
        ref = res["reference"]; sd = max(res["ref_sigma"], cfg.cv_floor_pct / 100.0 * ref)
        cvp = sd / ref * 100.0 if ref else 0.0
        for mult, lbl, col in ((cfg.sigma_caution, "주의", "#888"),
                               (cfg.sigma_warning, "경고", "#d08"),
                               (cfg.sigma_danger, "위험", "#a00")):
            p = mult * cvp
            ax[0].axhline(100 - p, color=col, ls=":", lw=1)
            ax[0].text(bt[-1], 100 - p + 0.5, f"{lbl}(-{mult:.0f}σ≈-{p:.0f}%)",
                       ha="right", color=col, fontsize=9)
    else:
        for p, lbl, col in ((cfg.stage_caution, "주의", "#888"),
                            (cfg.stage_warning, "경고", "#d08"),
                            (cfg.stage_danger, "위험", "#a00")):
            ax[0].axhline(100 - p, color=col, ls=":", lw=1)
            ax[0].text(bt[-1], 100 - p + 0.5, f"{lbl}(-{p:.0f}%)", ha="right", color=col, fontsize=9)
    ax[0].set_ylabel("정점 대비 %"); ax[0].legend(fontsize=9, loc="lower left")
    ax[0].grid(alpha=0.25); ax[0].set_title("M-wave 피로 판정 결과", fontsize=13, fontweight="bold")

    # ── 하단: ★CHG 피로 지표 상한/하한 범위 ──
    colmap = np.array(["#2e7d32", "#888", "#d08", "#a00"])
    ax[1].plot(bt, res["fatigue"], color="#c62828", lw=1.7, label="상한(세션 전체 기준)")
    if res.get("seg_fatigue") is not None:
        ax[1].plot(bt, res["seg_fatigue"], color="#1AA79A", lw=1.7, label="하한(구간별 기준)")
        ax[1].fill_between(bt, res["seg_fatigue"], res["fatigue"],
                           color="#c9dfd9", alpha=0.55, label="추정 범위")
    ax[1].scatter(bt, res["fatigue"], s=8, c=colmap[res["stage"]], zorder=4)
    for b in bnd:
        ax[1].axvline(bt[b], color="#7B1FA2", ls="-.", lw=1.1, alpha=0.6)
    flag_txt = (f"레벨변화 의심 · 경계 {res.get('n_level', 0)}개 · "
                f"최대급변 {res.get('max_jump', 0):.0f}%p"
                if res.get("level_flag") else
                f"레벨변화 경계 {res.get('n_level', 0)}개")
    ax[1].text(0.01, 0.97, flag_txt, transform=ax[1].transAxes, ha="left", va="top",
               fontsize=9, color="#7B1FA2",
               bbox=dict(boxstyle="round,pad=0.25", fc="white", ec="#7B1FA2", alpha=0.8))
    ax[1].set_ylabel("피로 지표 %"); ax[1].set_xlabel("시간(s)")
    ax[1].grid(alpha=0.25); ax[1].legend(fontsize=8, loc="upper right")
    plt.tight_layout(); plt.savefig(out_png, dpi=140); plt.close(fig)


# =====================================================================
# 결과 엑셀 (요약 + 구간 + ★NEW 레벨변화구간 + 버스트 + 설정 + 그래프)
# =====================================================================
def write_excel(res: dict, out_xlsx: str, src_name: str, png_path: str = None):
    import pandas as pd
    cfg = res["cfg"]; on = res["onset"]
    summary = [
        ("입력 파일", src_name),
        ("샘플링레이트(Hz)", res["fs"]),
        ("길이(s)", round(res["dur_s"])),
        ("신뢰도 등급", res["tier"]),
        ("신뢰도(검출률 기준)", res.get("tier_base", res["tier"])),
        ("궤적 상방회복 %", res.get("recov_pct", "-")),
        ("등급 강등 근거", res.get("tier_reason", "-")),
        ("유효 M-wave %", round(res["valid_pct"], 1)),
        ("검출 자극 수", res["n_stim"]),
        ("버스트 수", res["n_burst"]),
        ("배제된 스파이크 버스트", res["n_spike"]),
        ("M-wave창 포화 에폭", res["n_sat"]),
        ("fresh 기준(정점) 값", round(res["reference"])),
        ("판정 방식", cfg.threshold_mode),
        ("정점 구간 CV %", round(res["ref_sigma"] / res["reference"] * 100, 1) if res["reference"] else "-"),
        ("fresh 기준(정점) 시각(s)", round(res["reference_t"])),
        ("종료 시 정점 대비 %", round(res["end_pct"])),
        ("전위 종료(정점) 시각(s)", round(res["reference_t"])),
        ("★ 피로 시작 시점 [주의 확정](s)", on[1] if on[1] else "-"),
        ("경고 확정 시각(s)", on[2] if on[2] else "-"),
        ("위험 확정 시각(s)", on[3] if on[3] else "-"),
        (f"(확정 규칙) 연속 {cfg.run_length}버스트", "단발 잡음 배제 후 시작점 확정"),
        # ★NEW 범위 보고
        ("── 피로도 범위(권장 해석) ──", ""),
        ("최대 피로도 — 상한(세션 전체 기준) %", round(res["upper_max"], 1)),
        ("최대 피로도 — 하한(구간별 기준) %", round(res["lower_max"], 1)),
        ("피로도 권장표기", f"{res['lower_max']:.0f}~{res['upper_max']:.0f}% (실제값은 그 사이)"),
        ("검출된 레벨변화(계단) 수", res["n_level"]),
        ("레벨변화 플래그", "의심 → 범위로 해석" if res["level_flag"] else "없음"),
        ("경계 최대 급변(%p)", round(res["max_jump"], 1)),
        ("주의(참고)", "M-wave 진폭 기반 지표 · 드리프트와 미분리 · 단계임계는 관례값"),
        ("주의(범위)", "구간별(하한)은 경계 인공물로 과소평가 쪽 · 상한은 접촉변화를 피로로 포함 가능"),
    ]
    df_sum = pd.DataFrame(summary, columns=["항목", "값"])
    df_burst = pd.DataFrame({
        "시각(s)": np.round(res["burst_t"], 2),
        "Mwave_면적": np.round(res["mwave"], 1),
        "정점대비%": np.round(res["pct"], 1),
        "피로지표%(정점대비하락)": np.round(res["fatigue"], 1),
        "국면": res["phase"],
        "단계": [STAGE_NAMES[s] for s in res["stage"]],
        "구간": res["burst_seg"],
        # ★NEW 구간별(하한) 관련 열
        "레벨구간ID": res["seg_id"],
        "구간대비%": np.round(res["seg_pct"], 1),
        "피로_하한%(구간대비)": np.round(res["seg_fatigue"], 1),
    })
    df_seg = pd.DataFrame(res["segments"])
    df_level = pd.DataFrame(res["seg_info"])                       # ★NEW
    df_cfg = pd.DataFrame(list(asdict(cfg).items()), columns=["파라미터", "값"])
    with pd.ExcelWriter(out_xlsx, engine="openpyxl") as w:
        df_sum.to_excel(w, sheet_name="요약", index=False)
        df_seg.to_excel(w, sheet_name="구간(피로진행)", index=False)
        df_level.to_excel(w, sheet_name="레벨변화구간", index=False)   # ★NEW
        df_burst.to_excel(w, sheet_name="버스트결과", index=False)
        df_cfg.to_excel(w, sheet_name="설정", index=False)
        # ★ 그래프를 엑셀 '그래프' 시트에 이미지로 삽입
        if png_path and os.path.exists(png_path):
            try:
                from openpyxl.drawing.image import Image as XLImage
                ws = w.book.create_sheet("그래프")
                ws["A1"] = "M-wave 피로 판정 결과 (상한/하한 범위 포함)"
                ws.add_image(XLImage(png_path), "A3")
            except Exception as e:
                print(f"  (그래프 엑셀 삽입 생략: {e})")


# =====================================================================
# 오케스트레이터
# =====================================================================
def process_one(path: str, out_dir: str, cfg: Config = None) -> dict:
    name = os.path.splitext(os.path.basename(path))[0]
    t_s, adc, fs = read_any(path)
    res = analyze(t_s, adc, fs, cfg)
    row = dict(파일=name)
    if not res.get("ok"):
        row.update(신뢰도="실패", 사유=res.get("reason", ""))
        print(f"  [{name}] 실패: {res.get('reason')}")
        return row
    out_xlsx = os.path.join(out_dir, f"{name}_결과.xlsx")
    out_png = os.path.join(out_dir, f"{name}_궤적.png")
    plot_result(res, out_png)                    # ① 그림 먼저 저장
    write_excel(res, out_xlsx, name, out_png)    # ② 엑셀에 데이터+그래프 함께
    on = res["onset"]
    row.update(신뢰도=res["tier"], 유효Mwave_pct=round(res["valid_pct"], 1),
               길이s=round(res["dur_s"]), 버스트=res["n_burst"],
               정점값=round(res["reference"]), 정점s=round(res["reference_t"]),
               종료_정점대비pct=round(res["end_pct"]),
               주의s=on[1], 경고s=on[2], 위험s=on[3],
               # ★NEW 범위 요약
               피로상한pct=round(res["upper_max"], 1),
               피로하한pct=round(res["lower_max"], 1),
               레벨변화수=res["n_level"],
               레벨플래그=("의심" if res["level_flag"] else "-"),
               최대급변pp=round(res["max_jump"], 1))
    print(f"  [{name}] ok  신뢰도 {res['tier']}  유효 {res['valid_pct']:.0f}%  "
          f"버스트 {res['n_burst']}  피로 {res['lower_max']:.0f}~{res['upper_max']:.0f}%  "
          f"레벨변화 {res['n_level']}개{' ⚠' if res['level_flag'] else ''}  "
          f"→ {os.path.basename(out_xlsx)}")
    return row


def run(input_path: str, out_dir: str = None, cfg: Config = None) -> str:
    cfg = cfg or Config()
    if os.path.isdir(input_path):
        files = []
        for ext in ("*.csv", "*.xlsx", "*.xls"):
            files += glob.glob(os.path.join(input_path, ext))
        files = sorted(files)
        out_dir = out_dir or os.path.join(input_path, "결과")
    else:
        files = [input_path]
        out_dir = out_dir or os.path.dirname(os.path.abspath(input_path)) or "."
    os.makedirs(out_dir, exist_ok=True)
    if not files:
        raise FileNotFoundError(f"처리할 파일이 없습니다: {input_path}")

    print(f"입력 {len(files)}개 처리 → 출력 폴더: {out_dir}")
    rows = []
    for f in files:
        try:
            rows.append(process_one(f, out_dir, cfg))
        except Exception as e:
            print(f"  [{os.path.basename(f)}] 건너뜀: {e}")
            rows.append(dict(파일=os.path.basename(f), 신뢰도="실패", 사유=str(e)))

    if len(files) > 1:
        import pandas as pd
        combined = os.path.join(out_dir, "전체요약.xlsx")
        pd.DataFrame(rows).to_excel(combined, sheet_name="전체요약", index=False)
        print(f"\n전체요약 저장: {combined}")
    return out_dir


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("사용법: python mwave_analyzer.py  입력(파일 또는 폴더)  [출력폴더]")
        sys.exit(1)
    inp = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else None
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        run(inp, out)
