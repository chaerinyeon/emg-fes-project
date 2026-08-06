import 'package:flutter/material.dart';

/// RE-FIT Play 시각 언어 — "고요한 물가".
///
/// 왜 어두운 화면인가: 환자는 이 화면을 매일, 한 세션에 10분 가까이 본다.
/// 흰 배경은 눈부시고 임상적이다. 깊은 청록–잉크 위에 따뜻한 모래빛 손을
/// 띄우면 손이 저절로 주인공이 되고, 오래 봐도 편하다.
///
/// 색으로 실패를 말하지 않는다. 빨강은 **기기 문제**에만 쓰고, 수축 실패에는
/// 쓰지 않는다(실패 표현 금지). 수축이 안 되면 손이 그냥 풀릴 뿐이다.
class RefitTheme {
  const RefitTheme._();

  // 배경 — 깊은 물
  static const Color abyss = Color(0xFF071A20);
  static const Color deep = Color(0xFF0E2E38);
  static const Color shallow = Color(0xFF15414E);

  // 손 — 따뜻한 모래
  static const Color hand = Color(0xFFE8C9A0);
  static const Color handShade = Color(0xFFC9A278);
  static const Color handGlow = Color(0xFFFFD9A0);

  // 강조 — 잔잔한 빛
  static const Color glow = Color(0xFF7FE3C4);
  static const Color glowSoft = Color(0x337FE3C4);

  // 텍스트
  static const Color ink = Color(0xFFF2F6F5);
  static const Color inkSoft = Color(0xB3F2F6F5);
  static const Color inkFaint = Color(0x66F2F6F5);

  /// 기기 문제 전용. 수축 실패에는 쓰지 않는다.
  static const Color alert = Color(0xFFE8845C);

  static const LinearGradient backdrop = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [abyss, deep, shallow],
    stops: [0.0, 0.55, 1.0],
  );

  /// 주요 버튼 최소 높이. 스펙은 44pt 이지만 한 손·누운 자세를 고려해 키웠다.
  static const double touchMin = 64;

  /// 화면 하단 ⅓ 안에 조작부를 둔다 (한 손 조작).
  static const double controlZone = 1 / 3;

  static TextStyle get display => const TextStyle(
    fontSize: 44,
    height: 1.15,
    fontWeight: FontWeight.w300,
    letterSpacing: -0.5,
    color: ink,
  );

  static TextStyle get title => const TextStyle(
    fontSize: 28,
    height: 1.25,
    fontWeight: FontWeight.w500,
    color: ink,
  );

  static TextStyle get body => const TextStyle(
    fontSize: 19,
    height: 1.5,
    fontWeight: FontWeight.w400,
    color: inkSoft,
  );

  static TextStyle get label => const TextStyle(
    fontSize: 15,
    height: 1.3,
    fontWeight: FontWeight.w500,
    letterSpacing: 1.2,
    color: inkFaint,
  );

  /// 큰 숫자 — 반복 횟수처럼 **셀 수 있는 성취**에만 쓴다.
  /// 피로도 퍼센트에는 절대 쓰지 않는다.
  static TextStyle get counter => const TextStyle(
    fontSize: 72,
    height: 1.0,
    fontWeight: FontWeight.w200,
    letterSpacing: -2,
    color: ink,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  static ThemeData get material => ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: abyss,
    colorScheme: const ColorScheme.dark(
      primary: glow,
      onPrimary: abyss,
      surface: deep,
      onSurface: ink,
      error: alert,
    ),
  );
}

/// 배경 그라디언트 + 은은한 빛무리.
class RefitBackdrop extends StatelessWidget {
  const RefitBackdrop({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(gradient: RefitTheme.backdrop),
      child: Stack(
        children: [
          // 위쪽에서 떨어지는 빛 한 줄기 — 깊이감만 준다.
          Positioned(
            top: -140,
            left: -60,
            child: IgnorePointer(
              child: Container(
                width: 420,
                height: 420,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [Color(0x1A7FE3C4), Color(0x00000000)],
                  ),
                ),
              ),
            ),
          ),
          child,
        ],
      ),
    );
  }
}

/// 한 손으로 닿는 큰 버튼.
class RefitButton extends StatelessWidget {
  const RefitButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.filled = true,
    this.tone,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool filled;
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final c = tone ?? RefitTheme.glow;
    return SizedBox(
      width: double.infinity,
      height: RefitTheme.touchMin,
      child: filled
          ? FilledButton(
              onPressed: onPressed,
              style: FilledButton.styleFrom(
                backgroundColor: c,
                foregroundColor: RefitTheme.abyss,
                disabledBackgroundColor: const Color(0x1AF2F6F5),
                disabledForegroundColor: RefitTheme.inkFaint,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
                textStyle: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                ),
              ),
              child: Text(label),
            )
          : OutlinedButton(
              onPressed: onPressed,
              style: OutlinedButton.styleFrom(
                foregroundColor: c,
                side: BorderSide(color: c.withValues(alpha: 0.55), width: 1.5),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
                textStyle: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                ),
              ),
              child: Text(label),
            ),
    );
  }
}
