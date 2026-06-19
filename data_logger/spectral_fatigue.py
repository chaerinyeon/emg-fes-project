#!/usr/bin/env python3
"""
spectral_fatigue.py — RAW 1kHz CSV에서 주파수 기반 근피로 지표를 계산.

대상 파일: 펌웨어가 새로 저장하는 raw_*.csv  (헤더: Time(ms),Raw_ADC)
  ※ env_*.csv 의 Raw_ADC 는 100ms '평균'이라 스펙트럼이 뭉개져 있어 사용 불가.
    반드시 1kHz 원신호가 들어있는 raw_*.csv 를 입력으로 줄 것.

계산 지표 (윈도우별 시계열):
  - MDF  : 중앙주파수 (누적전력 50% 지점) — 펌웨어 calculateMDF() 와 동일 정의
  - MNF  : 평균주파수 = M1 / M0
  - SMR  : Spectral Moment Ratio = Dimitrov 피로지수 FInsm_k = M(-1) / M(k)
           (기본 k=5). 피로가 진행되면 저주파로 left-shift → SMR '증가'.
           MDF 의 감소보다 변화폭이 커서 피로 검출 민감도가 높다.

스펙트럼 모멘트 정의:  M_k = Σ ( f_i^k · P(f_i) ),  P = |FFT|^2
필터링은 주파수영역에서 처리(scipy 불필요):
  - 대역 제한 20~450Hz
  - 60Hz 전원 노이즈 + 하모닉(120/180Hz) notch (±NOTCH_BW Hz bin 제거)

사용 예:
  python3 spectral_fatigue.py raw_20260615_xxxxxx.csv
  python3 spectral_fatigue.py raw_*.csv --k 5 --plot
"""
from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np

SAMPLE_RATE = 1000          # Hz (펌웨어 1kHz 샘플링)
FFT_SIZE = 512              # 윈도우 길이 (펌웨어 MDF 윈도우와 동일)
HOP = 100                   # 윈도우 이동 간격(샘플) = 100ms → 10Hz 시계열
BAND_LOW = 20.0            # 대역 하한 Hz
BAND_HIGH = 450.0          # 대역 상한 Hz
NOTCH_HZ = (60.0, 120.0, 180.0)   # 전원 노이즈 + 하모닉
NOTCH_BW = 2.0             # notch 반폭 Hz (±2Hz bin 제거)

ARTIFACT_THRESHOLD = 1000.0  # |centered| 가 이 값 초과면 FES 자극 스파이크로 간주 (펌웨어와 동일)
BLANK_MS = 5                 # 자극 검출 후 blanking 할 시간(ms)


def blank_artifacts(samples: np.ndarray, threshold: float, blank_ms: int):
    """FES 자극 스파이크 구간을 선형보간으로 제거(blanking). (blanked 배열, 제거 샘플 수) 반환.

    펌웨어는 실시간이라 'hold' 로 대체하지만, 오프라인에선 양끝 깨끗한 표본으로
    선형보간해 불연속을 줄인다(스펙트럼 누설 최소화 → MDF/SMR 신뢰도↑).
    """
    s = samples.astype(np.float64)
    dc = np.median(s)                       # 견고한 DC 추정
    centered = s - dc
    n = len(s)
    blank_n = max(1, int(blank_ms * SAMPLE_RATE / 1000))

    blanked = np.abs(centered) > threshold
    # 각 검출 지점을 앞으로 blank_n 만큼 확장 (자극 스파이크 꼬리 포함)
    for idx in np.where(blanked)[0]:
        blanked[idx:min(n, idx + blank_n + 1)] = True

    clean_idx = np.where(~blanked)[0]
    if clean_idx.size < 2:
        return s, int(blanked.sum())        # 거의 다 자극이면 보간 포기

    out = s.copy()
    out[blanked] = np.interp(np.where(blanked)[0], clean_idx, s[clean_idx])
    return out, int(blanked.sum())


def _band_mask(freqs: np.ndarray) -> np.ndarray:
    """20~450Hz 대역 + 60/120/180Hz notch 를 적용한 bin 마스크(True=사용)."""
    mask = (freqs >= BAND_LOW) & (freqs <= BAND_HIGH)
    for nf in NOTCH_HZ:
        mask &= ~((freqs >= nf - NOTCH_BW) & (freqs <= nf + NOTCH_BW))
    return mask


def spectral_metrics(window: np.ndarray, k: int) -> tuple[float, float, float]:
    """한 윈도우(FFT_SIZE 샘플)에서 (MDF, MNF, SMR) 반환.

    SMR = M(-1) / M(k)  (Dimitrov FInsm_k). 분모 0 또는 무신호면 0.
    """
    seg = window[:FFT_SIZE].astype(np.float64)
    seg = seg - seg.mean()                 # DC 제거 (전극 드리프트 흡수)
    seg = seg * np.hamming(FFT_SIZE)       # 윈도우잉 (스펙트럼 누설 감소)

    spec = np.abs(np.fft.rfft(seg))
    freqs = np.fft.rfftfreq(FFT_SIZE, d=1.0 / SAMPLE_RATE)
    power = spec * spec                     # P(f) = |FFT|^2

    mask = _band_mask(freqs)
    f = freqs[mask]
    p = power[mask]
    total = p.sum()
    if total <= 1e-12 or f.size == 0:
        return 0.0, 0.0, 0.0

    # MDF: 누적전력 50% 지점 주파수
    cum = np.cumsum(p)
    mdf = float(f[np.searchsorted(cum, total / 2.0)])

    # 스펙트럼 모멘트
    m0 = total
    m1 = float((f * p).sum())
    m_neg1 = float((p / f).sum())          # M(-1)
    m_k = float((f ** k * p).sum())        # M(k)

    mnf = m1 / m0 if m0 > 0 else 0.0
    smr = m_neg1 / m_k if m_k > 1e-12 else 0.0
    return mdf, mnf, smr


def analyze(samples: np.ndarray, k: int):
    """전체 신호를 HOP 간격 슬라이딩 윈도우로 훑어 시계열 반환."""
    times_s, mdfs, mnfs, smrs = [], [], [], []
    for start in range(0, len(samples) - FFT_SIZE + 1, HOP):
        win = samples[start:start + FFT_SIZE]
        mdf, mnf, smr = spectral_metrics(win, k)
        # 윈도우 중앙 시각(초)
        times_s.append((start + FFT_SIZE / 2) / SAMPLE_RATE)
        mdfs.append(mdf)
        mnfs.append(mnf)
        smrs.append(smr)
    return (np.array(times_s), np.array(mdfs), np.array(mnfs), np.array(smrs))


def pct_change(series: np.ndarray, frac: float = 0.15) -> float:
    """초반 frac 구간 평균 대비 후반 frac 구간 평균의 변화율(%)."""
    n = len(series)
    if n < 4:
        return 0.0
    w = max(1, int(n * frac))
    first = series[:w].mean()
    last = series[-w:].mean()
    # SMR 은 M5(f^5) 때문에 절대값이 매우 작다(~1e-13). 작은 양수라도 유효하므로
    # 0 으로 간주하지 않도록 임계는 극소값만 사용한다.
    if not np.isfinite(first) or abs(first) < 1e-300:
        return 0.0
    return (last - first) / first * 100.0


def load_raw_csv(path: Path) -> np.ndarray:
    """raw_*.csv (Time(ms),Raw_ADC) 에서 Raw_ADC 열만 읽어 1D 배열로."""
    data = np.genfromtxt(path, delimiter=",", names=True)
    cols = data.dtype.names
    if cols is None or "Raw_ADC" not in cols:
        raise SystemExit(
            f"❌ {path.name}: 'Raw_ADC' 열이 없음. raw_*.csv 가 맞는지 확인하세요.")
    return np.asarray(data["Raw_ADC"], dtype=np.float64)


def main():
    ap = argparse.ArgumentParser(description="RAW 1kHz CSV 주파수 피로 지표(MDF/MNF/SMR)")
    ap.add_argument("csv", nargs="+", type=Path, help="raw_*.csv 파일(들)")
    ap.add_argument("--k", type=int, default=5, help="SMR 차수 (FInsm_k, 기본 5)")
    ap.add_argument("--plot", action="store_true", help="시계열 그래프 표시")
    ap.add_argument("--out", type=Path, help="지표 시계열 CSV 저장 경로(선택)")
    ap.add_argument("--no-blank", action="store_true",
                    help="FES 자극 blanking 끄기 (오염 비교용)")
    ap.add_argument("--artifact-thresh", type=float, default=ARTIFACT_THRESHOLD,
                    help=f"자극 스파이크 임계 |centered| (기본 {ARTIFACT_THRESHOLD:.0f})")
    ap.add_argument("--blank-ms", type=int, default=BLANK_MS,
                    help=f"자극 검출 후 blanking 시간 ms (기본 {BLANK_MS})")
    args = ap.parse_args()

    for path in args.csv:
        if not path.exists():
            print(f"⚠️ 없음: {path}")
            continue
        samples = load_raw_csv(path)
        dur = len(samples) / SAMPLE_RATE
        if len(samples) < FFT_SIZE:
            print(f"⚠️ {path.name}: 샘플 부족({len(samples)} < {FFT_SIZE})")
            continue

        blanked_n = 0
        if not args.no_blank:
            samples, blanked_n = blank_artifacts(
                samples, args.artifact_thresh, args.blank_ms)

        t, mdf, mnf, smr = analyze(samples, args.k)

        print(f"\n=== {path.name} ===")
        print(f"  길이: {len(samples)} samples ({dur:.1f}s), 윈도우 {len(t)}개")
        if args.no_blank:
            print("  blanking: OFF (자극 오염 포함)")
        else:
            pct = 100.0 * blanked_n / max(1, len(samples))
            print(f"  blanking: {blanked_n} samples 제거 ({pct:.1f}%), "
                  f"thresh={args.artifact_thresh:.0f}, {args.blank_ms}ms")
        print(f"  MDF : {mdf.mean():6.1f} Hz  (변화 {pct_change(mdf):+5.1f}%)  ← 피로 시 감소")
        print(f"  MNF : {mnf.mean():6.1f} Hz  (변화 {pct_change(mnf):+5.1f}%)  ← 피로 시 감소")
        print(f"  SMR : {smr.mean():8.3g}  (변화 {pct_change(smr):+5.1f}%)  ← 피로 시 증가 (FInsm{args.k})")

        if args.out:
            arr = np.column_stack([t, mdf, mnf, smr])
            hdr = "Time(s),MDF_Hz,MNF_Hz,SMR"
            np.savetxt(args.out, arr, delimiter=",", header=hdr,
                       comments="", fmt="%.4f")
            print(f"  → 저장: {args.out}")

        if args.plot:
            import matplotlib.pyplot as plt
            fig, ax = plt.subplots(3, 1, sharex=True, figsize=(10, 7))
            ax[0].plot(t, mdf, color="tab:orange"); ax[0].set_ylabel("MDF (Hz)")
            ax[1].plot(t, mnf, color="tab:green"); ax[1].set_ylabel("MNF (Hz)")
            ax[2].plot(t, smr, color="tab:red"); ax[2].set_ylabel(f"SMR (FInsm{args.k})")
            ax[2].set_xlabel("Time (s)")
            ax[0].set_title(f"{path.name} — 주파수 피로 지표")
            for a in ax:
                a.grid(True, alpha=0.3)
            plt.tight_layout()
            plt.show()


if __name__ == "__main__":
    main()
