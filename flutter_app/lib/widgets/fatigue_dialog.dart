import 'package:flutter/material.dart';

void showFatigueDialog(
  BuildContext context, {
  required double rmsSlope,
  required double mdfSlope,
  required bool fesWasOn,
}) {
  final rs = rmsSlope.toStringAsFixed(1);
  final ms = mdfSlope.toStringAsFixed(1);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      backgroundColor: Colors.red.shade900,
      icon: const Icon(
        Icons.warning_amber_rounded,
        size: 56,
        color: Colors.white,
      ),
      title: const Text(
        '근피로 감지!',
        textAlign: TextAlign.center,
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.bold,
          fontSize: 22,
        ),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'RMS slope +$rs%   |   MDF slope $ms%',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white, fontSize: 14),
          ),
          const SizedBox(height: 6),
          Text(
            fesWasOn
                ? '자극이 자동으로 정지되었습니다.'
                : '연속 만족 카운트 5/5 도달 (FES 미가동 — 자동 정지 없음).',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
        ],
      ),
      actions: [
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Colors.white),
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('확인', style: TextStyle(color: Colors.red)),
        ),
      ],
    ),
  );
}
