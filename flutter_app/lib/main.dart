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
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'screens/splash_screen.dart';
import 'services/profile_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // .env (OPENAI_API_KEY 등) 로드 — 없어도 앱은 동작 (AI 분석만 비활성).
  try {
    await dotenv.load(fileName: '.env');
  } catch (_) {}
  await Hive.initFlutter();
  await gProfileService.init();
  runApp(const EmgFesApp());
}

class EmgFesApp extends StatelessWidget {
  const EmgFesApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'RE-FIT',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        // 포인트(버튼 등 primary/secondary)만 초록. 표면(카드·앱바·네비)은 중립.
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2E7D32),
          brightness: Brightness.light,
        ).copyWith(surfaceTint: Colors.transparent),
        scaffoldBackgroundColor: const Color(0xFFF5F6FA),
        useMaterial3: true,
        // 카드(차트 박스 등): 초록기 없는 흰 배경
        cardTheme: const CardThemeData(
          color: Colors.white,
          surfaceTintColor: Colors.transparent,
          shadowColor: Colors.black26,
        ),
        // 앱바: 중립 배경 + 스크롤 틴트 제거
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFF5F6FA),
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          foregroundColor: Colors.black87,
        ),
        // 하단 네비게이션: 흰 배경(초록기 제거), 선택 표시(인디케이터)만 초록 유지
        navigationBarTheme: const NavigationBarThemeData(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
          elevation: 1,
        ),
      ),
      home: const SplashScreen(),
    );
  }
}
