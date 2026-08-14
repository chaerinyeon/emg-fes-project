import 'package:flutter/material.dart';

/// RE-FIT Play 시각 언어 — "어두운 계측기".
///
/// 왜 어두운 화면인가: 환자는 이 화면을 매일, 한 세션에 10분 가까이 본다.
/// 흰 배경은 눈부시고 임상적이다.
///
/// ## 왜 청록 바탕을 버렸는가
///
/// 처음에는 깊은 청록–잉크였다("고요한 물가"). 의도는 **손이 주인공**이 되게
/// 하는 것이었는데, 청록 바탕은 민트 강조([glow])와 색상환에서 이웃이라
/// 서로를 잡아먹었다 — 바탕이 이미 초록기를 띠니 신호색이 신호로 안 읽히고,
/// 따뜻한 모래빛 손도 바탕과 보색으로 부딪쳤다.
///
/// 중성 검정으로 내리면 셋이 각자 자기 일을 한다: 바탕은 물러나고, 민트는
/// 유일한 신호색이 되고, 손은 화면에서 가장 따뜻한 것이 된다. 어두워서 눈이
/// 편하다는 원래 이유는 그대로다.
///
/// 색으로 실패를 말하지 않는다. 빨강은 **기기 문제**에만 쓰고, 수축 실패에는
/// 쓰지 않는다(실패 표현 금지). 수축이 안 되면 손이 그냥 풀릴 뿐이다.
class RefitTheme {
  const RefitTheme._();

  // 배경 — 계측기의 검정. 위에서 아래로 아주 얕게만 밝아진다.
  static const Color abyss = Color(0xFF0A0C0D);
  static const Color deep = Color(0xFF121517);
  static const Color shallow = Color(0xFF181C1F);

  // 강조 — 잔잔한 빛
  static const Color glow = Color(0xFF7FE3C4);

  // 텍스트
  static const Color ink = Color(0xFFF2F6F5);
  static const Color inkSoft = Color(0xB3F2F6F5);
  static const Color inkFaint = Color(0x66F2F6F5);

  /// 기기 문제 전용. 수축 실패에는 쓰지 않는다.
  static const Color alert = Color(0xFFE8845C);

  // 오늘의 상태 3단계 — 좋음 · 주의 · 피로.
  //
  // **빨강은 쓰지 않는다.** 빨강은 [alert](기기 문제) 전용이고, 피로에 빨강을
  // 쓰면 환자의 몸 상태 자체를 경고로 만든다. 피로는 실패가 아니라 오늘 몫을
  // 다 했다는 신호다.
  static const Color good = glow;
  static const Color caution = Color(0xFFE9CE7A);
  static const Color tired = Color(0xFFE0A567);

  /// 카드·타일의 공통 바탕. 배경 위에 얹히는 반투명 판.
  ///
  /// 검정 바탕에서는 카드가 스스로 떠 보여야 한다. 청록 시절보다 한 단계
  /// 올려, 그림자 없이 밝기 차이만으로 층이 서게 했다.
  static const Color panel = Color(0x17F2F6F5);
  static const Color hairline = Color(0x1FF2F6F5);

  /// 거의 평평하다. 그라디언트는 위아래를 구분해 주는 정도로만 남긴다 —
  /// 검정에서 색이 흐르면 그게 먼저 보이고, 데이터가 뒤로 밀린다.
  static const LinearGradient backdrop = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [abyss, deep, shallow],
    stops: [0.0, 0.62, 1.0],
  );

  /// 주요 버튼 최소 높이. 스펙은 44pt 이지만 한 손·누운 자세를 고려해 키웠다.
  static const double touchMin = 64;

  static const display = TextStyle(
      fontSize: 44,
      height: 1.15,
      fontWeight: FontWeight.w300,
      letterSpacing: -0.5,
      color: ink);
  static const title = TextStyle(
      fontSize: 28, height: 1.25, fontWeight: FontWeight.w500, color: ink);
  static const body = TextStyle(
      fontSize: 19, height: 1.5, fontWeight: FontWeight.w400, color: inkSoft);
  static const label = TextStyle(
      fontSize: 15,
      height: 1.3,
      fontWeight: FontWeight.w500,
      letterSpacing: 1.2,
      color: inkFaint);

  /// 목록·표처럼 밀도가 필요한 화면용. 환자 화면에는 쓰지 않는다.
  static const bodySmall = TextStyle(
      fontSize: 16, height: 1.45, fontWeight: FontWeight.w400, color: inkSoft);

  /// 보조 설명 — 버튼 아래 한 줄, 카드 각주.
  ///
  /// 화면 곳곳에서 `caption` 이 열세 번 반복되고
  /// 있었다. 그건 토큰이 하나 빠졌다는 뜻이지 각자 정할 값이 아니다 —
  /// 크기를 조정할 일이 생기면 열세 곳을 찾아다녀야 했다.
  static const caption = TextStyle(
      fontSize: 13, height: 1.45, fontWeight: FontWeight.w400, color: inkSoft);

  /// 카드 안의 중간 크기 수치 (쥔 횟수·운동 시간 등).
  static const figure = TextStyle(
      fontSize: 30,
      height: 1.05,
      fontWeight: FontWeight.w600,
      color: ink,
      fontFeatures: [FontFeature.tabularFigures()]);

  /// 큰 숫자 — 반복 횟수처럼 **셀 수 있는 성취**에만 쓴다.
  /// 피로도 퍼센트에는 절대 쓰지 않는다.
  static const counter = TextStyle(
      fontSize: 72,
      height: 1.0,
      fontWeight: FontWeight.w200,
      letterSpacing: -2,
      color: ink,
      fontFeatures: [FontFeature.tabularFigures()]);

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

  static final _shape =
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(18));
  static const _text = TextStyle(fontSize: 20, fontWeight: FontWeight.w600);

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
                shape: _shape,
                textStyle: _text,
              ),
              child: Text(label),
            )
          : OutlinedButton(
              onPressed: onPressed,
              style: OutlinedButton.styleFrom(
                foregroundColor: c,
                side: BorderSide(color: c.withValues(alpha: 0.55), width: 1.5),
                shape: _shape,
                textStyle: _text,
              ),
              child: Text(label),
            ),
    );
  }
}

/// 배경 위에 얹히는 판. 홈·기록·설정의 모든 묶음이 이 모양이다.
class RefitCard extends StatelessWidget {
  const RefitCard({
    super.key,
    required this.child,
    this.onTap,
    this.tint,
    this.padding = const EdgeInsets.all(18),
  });

  final Widget child;
  final VoidCallback? onTap;

  /// 테두리 색. 상태를 가진 카드(피로도·신호)만 준다.
  final Color? tint;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final border = tint ?? RefitTheme.hairline;
    final body = Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: RefitTheme.panel,
        // 22 → 18. 검정 위에서는 모서리가 둥글수록 카드가 물러 보인다.
        // 계측기 화면에 가깝게, 각을 조금 세운다.
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: tint == null ? border : border.withValues(alpha: 0.42),
        ),
      ),
      child: child,
    );
    if (onTap == null) return body;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        child: body,
      ),
    );
  }
}

/// 상태 알약. **숫자를 넣지 않는다** — 상태 이름만 들어간다.
class RefitChip extends StatelessWidget {
  const RefitChip({super.key, required this.label, required this.tone});

  final String label;
  final Color tone;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: tone.withValues(alpha: 0.45)),
      ),
      child: Text(
        label,
        style: RefitTheme.bodySmall.copyWith(
          color: tone,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// 설정·목록의 한 줄. 탭 영역이 [RefitTheme.touchMin] 밑으로 내려가지 않는다.
class RefitTile extends StatelessWidget {
  const RefitTile({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
    this.leading,
    this.onTap,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final IconData? leading;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final sub = subtitle;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          constraints: const BoxConstraints(minHeight: RefitTheme.touchMin),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              if (leading != null) ...[
                Icon(leading, color: RefitTheme.inkSoft, size: 22),
                const SizedBox(width: 14),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: RefitTheme.bodySmall.copyWith(
                        color: RefitTheme.ink,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (sub != null) ...[
                      const SizedBox(height: 3),
                      Text(
                        sub,
                        style: RefitTheme.bodySmall.copyWith(fontSize: 14),
                      ),
                    ],
                  ],
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 12),
                trailing!,
              ] else if (onTap != null)
                const Icon(Icons.chevron_right_rounded,
                    color: RefitTheme.inkFaint),
            ],
          ),
        ),
      ),
    );
  }
}

/// 화면 안의 묶음 제목.
class RefitSectionTitle extends StatelessWidget {
  const RefitSectionTitle(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 26, 4, 12),
      child: Row(
        children: [
          Expanded(child: Text(text, style: RefitTheme.label)),
          ?trailing,
        ],
      ),
    );
  }
}
