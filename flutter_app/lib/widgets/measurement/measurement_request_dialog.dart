import 'dart:async';

import 'package:flutter/material.dart';

/// 자극 후 안정화가 끝난 측정 창에서 사용자에게 짧은 동작을 요청하는 팝업.
/// 예) "지금 힘을 주세요", "발목을 들어 올려 주세요".
///
/// [durationMs] 동안 카운트다운 진행 바를 보여주고, 만료되면 자동으로 닫힘.
void showMeasurementRequestDialog(
  BuildContext context, {
  required String prompt,
  required int durationMs,
}) {
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    useRootNavigator: true,
    builder: (ctx) => _MeasurementRequestDialog(
      prompt: prompt,
      durationMs: durationMs,
    ),
  );
}

class _MeasurementRequestDialog extends StatefulWidget {
  final String prompt;
  final int durationMs;
  const _MeasurementRequestDialog({
    required this.prompt,
    required this.durationMs,
  });

  @override
  State<_MeasurementRequestDialog> createState() =>
      _MeasurementRequestDialogState();
}

class _MeasurementRequestDialogState extends State<_MeasurementRequestDialog>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Timer _autoClose;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: widget.durationMs),
    )..forward();
    _autoClose = Timer(Duration(milliseconds: widget.durationMs), () {
      if (mounted) Navigator.of(context).pop();
    });
  }

  @override
  void dispose() {
    _autoClose.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      icon: Icon(
        Icons.fitness_center,
        size: 36,
        color: Colors.amber.shade800,
      ),
      title: const Text(
        '측정 — 동작 요청',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 15, color: Colors.black54),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            widget.prompt,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: Colors.black87,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 16),
          AnimatedBuilder(
            animation: _ctrl,
            builder: (_, _) {
              final remainMs =
                  widget.durationMs - (_ctrl.value * widget.durationMs).round();
              final secs = (remainMs / 1000).clamp(0, 99).toStringAsFixed(1);
              return Column(
                children: [
                  LinearProgressIndicator(
                    value: 1.0 - _ctrl.value,
                    minHeight: 6,
                    backgroundColor: Colors.black12,
                    valueColor: AlwaysStoppedAnimation(
                      Colors.amber.shade800,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '$secs 초',
                    style: const TextStyle(
                      color: Colors.black45,
                      fontSize: 12,
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('완료'),
        ),
      ],
    );
  }
}
