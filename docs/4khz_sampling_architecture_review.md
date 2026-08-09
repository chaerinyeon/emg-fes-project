# 4 kHz Sampling Architecture Review

## 결론

ESP32-WROOM에서 4 kHz ADC 수집 자체는 가능하다. 다만 현재 상수만 4배로 바꾸면
BLE MTU 초과, FFT CPU 부하, 버퍼 메모리 증가가 동시에 발생한다. 권장 구조는
**4 kHz RAW/M-wave 경로와 1 kHz RMS/MDF 경로를 분리**하는 것이다.

## 제안 데이터 흐름

```text
ADC 4 kHz
  ├─ RAW 4 kHz ring → artifact onset → 2~15 ms M-wave feature
  │                  → BLE RAW packet fragmentation → phone CSV
  └─ anti-alias LPF + 4:1 decimation → 기존 1 kHz RMS/MDF/ENV
```

- M-wave 시간 해상도: 1 ms에서 0.25 ms로 개선한다.
- RMS/MDF 정의와 기존 데이터 호환성은 1 kHz 경로에서 유지한다.
- latency는 4 kHz 실측 검증 전까지 피로 판정에 다시 넣지 않는다.

## 자원 영향

| 항목 | 현재 1 kHz | 4 kHz 단순 확장 | 권장안 |
|---|---:|---:|---:|
| RAW payload | 2 KB/s | 8 KB/s | 8 KB/s |
| 100 ms RAW block | 200 B | 800 B | 4~5개 notify로 분할 |
| RMS 1.622 s ring | 1,622 samples | 6,488 samples | 1 kHz decimated ring 유지 |
| 512 ms FFT | 512 points | 2,048 points | 512-point 기존 FFT 유지 |
| M-wave sample step | 1 ms | 0.25 ms | 0.25 ms |

MTU 247의 실효 payload는 약 244 B이므로 400개 `int16` 표본을 한 notify에 넣을
수 없다. 20 ms 단위 80표본 패킷(헤더 포함 약 166 B)으로 보내면 초당 50 notify가
필요하다. iOS 연결 간격과 패킷 손실률은 실기기에서 검증해야 한다.

## 작업 일정

1. **펌웨어 4 kHz 수집·이중 경로:** 1.5~2일
2. **BLE 분할/재조립·누락 검출:** 1~1.5일
3. **Flutter RAW logger 4 kHz 대응:** 0.5~1일
4. **벤치 검증:** 1일
5. **피험자 데이터 비교 및 파라미터 확정:** 최소 2~3회 측정 세션

코드 작업은 약 **4~5 개발일**, 실측 검증까지 포함하면 **1~2주**가 현실적이다.

## 완료 기준

- 10분 세션에서 RAW sample index 누락률을 기록하고 허용치를 정한다.
- 자극 onset과 M-wave peak가 0.25 ms 격자로 분리되는지 확인한다.
- 4 kHz에서 얻은 p2p/area와 기존 1 kHz 지표의 상관 및 편향을 보고한다.
- BLE 부하 중에도 샘플링 task deadline miss와 watchdog reset이 없어야 한다.
- RMS/MDF 회귀 결과가 기존 1 kHz 기준벡터와 허용 오차 내에 있어야 한다.