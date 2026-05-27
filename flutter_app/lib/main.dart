// EMG-FES Monitor — BLE 클라이언트 + 근피로 추출 파이프라인 시각화
//
// 통신: BLE GATT (Nordic UART Service 호환)
//   Service:  6E400001-B5A3-F393-E0A9-E50E24DCCA9E
//   DATA char (notify, ESP32 → Phone): 6E400003-...
//   CMD char  (write,  Phone → ESP32): 6E400002-...
//
// 펌웨어가 매 1초마다 보내는 JSON (짧은 키):
//   ts, raw, env, rms, mdf, rs, ms, fd, run, stim, hc, cc, rt, mt, ct, b, rr, st, mk

import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'screens/splash_screen.dart';
import 'services/profile_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Hive.initFlutter();
  await gProfileService.init();
  runApp(const EmgFesApp());
}

class EmgFesApp extends StatelessWidget {
  const EmgFesApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'EMG-FES Monitor',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.indigo,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const SplashScreen(),
    );
  }
}
