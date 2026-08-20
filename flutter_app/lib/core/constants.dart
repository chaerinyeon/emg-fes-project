import 'package:flutter/material.dart';

// ===== BLE UUID =====
const String kServiceUuid = '6e400001-b5a3-f393-e0a9-e50e24dcca9e';
const String kDataCharUuid = '6e400003-b5a3-f393-e0a9-e50e24dcca9e';
const String kCmdCharUuid = '6e400002-b5a3-f393-e0a9-e50e24dcca9e';
const String kRawCharUuid =
    '6e400004-b5a3-f393-e0a9-e50e24dcca9e'; // RAW 1kHz 파형 (binary notify)
const String kDeviceName = 'EMG-FES-01';

// v0.2 바이너리 펌웨어의 광고 이름. 서비스/캐릭터리스틱 UUID 는 구펌웨어와 **같으므로**
// 스캔 필터만으로는 구분되지 않는다 — 이름으로 갈라야 엉뚱한 쪽에 붙지 않는다.
// (UP notify = kDataCharUuid, DOWN write = kCmdCharUuid 를 그대로 재사용한다.
//  v0.2 엔 kRawCharUuid 채널이 없다 — 연속 RAW 스트리밍은 제거됐다.)
const String kRefitDeviceName = 'REFIT-FES-01';

// ===== 색상 =====
const Color cEnv = Color(0xFF1976D2); // 파랑
const Color cRms = Color(0xFF2E7D32); // 초록
const Color cMdf = Color(0xFFEF6C00); // 주황
const Color cRmsSlope = Color(0xFFD81B60); // 분홍 (slope 강조)
const Color cMdfSlope = Color(0xFF7B1FA2); // 보라
const Color cThr = Color(0xFFD32F2F); // 임계값 빨강

// ===== 세션 프로토콜 =====
// 세션 시작 직후 '힘을 주지 않는' 구간(초). FES 자극기는 수동으로 켜서 매 세션 자극
// 시작 시점이 다르고 하드웨어로는 알 수 없다. 이 구간의 자극은 자발 EMG 오염이 없어
// (1) 데이터에서 자극 시작점을 찾아 세션 간 시간축 정렬, (2) 그 세션의 M-wave 기준선
// 으로 쓴다. 실측 자극 구조: 1.61초마다 0.49초 버스트(32.3Hz 펄스 ~17발)
// → 15초면 버스트 약 9회가 잡혀 검출에 충분하다.
const int kRestWindowSec = 15;
// 무부하 구간이 끝나는 시점에 CSV 에 찍는 마커. 분석 코드가 이 라벨로 경계를 찾는다.
const String kRestEndMarker = 'rest_end';

// ===== 차트 윈도우 =====
const int kWindowSec = 60;
const int kMaxPoints = kWindowSec; // 1Hz 신호용 (rms/mdf/slope)
const int kMaxEnvPoints = kWindowSec * 5; // 5Hz envelope 60초치 (UI 부하 절감)
const double kEnvPushIntervalSec = 0.2; // 5Hz
