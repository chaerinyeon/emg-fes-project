import 'package:flutter/material.dart';

// ===== BLE UUID =====
const String kServiceUuid = '6e400001-b5a3-f393-e0a9-e50e24dcca9e';
const String kDataCharUuid = '6e400003-b5a3-f393-e0a9-e50e24dcca9e';
const String kCmdCharUuid = '6e400002-b5a3-f393-e0a9-e50e24dcca9e';
const String kDeviceName = 'EMG-FES-01';

// ===== 색상 =====
const Color cEnv = Color(0xFF82B1FF); // 하늘색
const Color cRms = Color(0xFF69F0AE); // 연두
const Color cMdf = Color(0xFFFFD180); // 주황
const Color cRmsSlope = Color(0xFFFF8A80); // 분홍 (slope 강조)
const Color cMdfSlope = Color(0xFFB388FF); // 보라
const Color cThr = Color(0xFFFF5252); // 임계값 빨강

// ===== 차트 윈도우 =====
const int kWindowSec = 60;
const int kMaxPoints = kWindowSec; // 1Hz 신호용 (rms/mdf/slope)
const int kMaxEnvPoints = kWindowSec * 5; // 5Hz envelope 60초치 (UI 부하 절감)
const double kEnvPushIntervalSec = 0.2; // 5Hz
