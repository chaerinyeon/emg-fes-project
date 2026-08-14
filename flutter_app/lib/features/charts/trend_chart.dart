import 'package:flutter/material.dart';

import '../refit_theme.dart';

/// 버스트 단위 시계열 한 줄.
///
/// fl_chart 대신 [CustomPaint] 인 이유: 필요한 것이 축·범례 없는 추이선과
/// **피로 구간 음영** 하나뿐이라, 차트 라이브러리를 끌어오면 테마를 다시
/// 맞추는 비용이 더 크다. 값의 절대 크기는 화면에 쓰지 않고(환자 화면에
/// 숫자를 늘리지 않는다) 모양만 본다.
class TrendChart extends StatelessWidget {
  const TrendChart({
    super.key,
    required this.values,
    required this.color,
    this.shadeFrom,
    this.fill = true,
  });

  /// 버스트 순서대로. 빈 값이면 안내 문구만 그린다.
  final List<double> values;
  final Color color;

  /// 음영을 시작할 지점(0~1 비율). 피로가 시작된 구간을 표시한다.
  final double? shadeFrom;

  final bool fill;

  @override
  Widget build(BuildContext context) {
    if (values.length < 2) {
      return Center(
        child: Text(
          '표시할 데이터가 없어요',
          style: RefitTheme.caption,
        ),
      );
    }
    return CustomPaint(
      size: Size.infinite,
      painter: _TrendPainter(
        values: values,
        color: color,
        shadeFrom: shadeFrom,
        fill: fill,
      ),
    );
  }
}

class _TrendPainter extends CustomPainter {
  _TrendPainter({
    required this.values,
    required this.color,
    required this.shadeFrom,
    required this.fill,
  });

  final List<double> values;
  final Color color;
  final double? shadeFrom;
  final bool fill;

  @override
  void paint(Canvas canvas, Size size) {
    var lo = values.first, hi = values.first;
    for (final v in values) {
      if (v < lo) lo = v;
      if (v > hi) hi = v;
    }
    // 평평한 계열도 한 줄로 보이게 — 0으로 나누지 않는다.
    final span = (hi - lo).abs() < 1e-9 ? 1.0 : hi - lo;

    // 피로 구간 음영. 색은 호박 — 빨강은 기기 문제 전용이다.
    final from = shadeFrom;
    if (from != null && from >= 0 && from < 1) {
      canvas.drawRect(
        Rect.fromLTRB(size.width * from, 0, size.width, size.height),
        Paint()..color = RefitTheme.tired.withValues(alpha: 0.14),
      );
    }

    // 기준선 셋. 눈금 숫자는 쓰지 않는다 — 절대 크기는 여전히 의미가 없고,
    // 선만으로도 "지금 어디쯤인지"가 읽힌다.
    final grid = Paint()
      ..color = RefitTheme.hairline.withValues(alpha: 0.5)
      ..strokeWidth = 1;
    for (var i = 1; i <= 3; i++) {
      final y = size.height * i / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }

    Offset at(int i) => Offset(
          size.width * i / (values.length - 1),
          size.height - 4 - (values[i] - lo) / span * (size.height - 10),
        );

    final path = Path()..moveTo(at(0).dx, at(0).dy);
    for (var i = 1; i < values.length; i++) {
      final p = at(i);
      path.lineTo(p.dx, p.dy);
    }

    if (fill) {
      final area = Path.from(path)
        ..lineTo(size.width, size.height)
        ..lineTo(0, size.height)
        ..close();
      canvas.drawPath(
        area,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              color.withValues(alpha: 0.22),
              color.withValues(alpha: 0.0),
            ],
          ).createShader(Offset.zero & size),
      );
    }

    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = color,
    );

    // 끝점 하나만 찍는다. 점을 전부 찍으면 버스트가 수백 개인 세션에서
    // 선이 점으로 뭉개진다. **지금 값**이 어디인지만 눈에 걸리면 된다.
    final last = at(values.length - 1);
    canvas.drawCircle(last, 7, Paint()..color = color.withValues(alpha: 0.18));
    canvas.drawCircle(last, 3.2, Paint()..color = color);
    canvas.drawCircle(
      last,
      3.2,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..color = RefitTheme.abyss,
    );
  }

  @override
  bool shouldRepaint(_TrendPainter old) =>
      old.values != values ||
      old.color != color ||
      old.shadeFrom != shadeFrom;
}
