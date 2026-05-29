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
      icon: const Icon(
        Icons.warning_amber_outlined,
        size: 36,
        color: Colors.redAccent,
      ),
      title: const Text(
        '근피로 감지',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'RMS slope +$rs%   ·   MDF slope $ms%',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
          const SizedBox(height: 6),
          Text(
            fesWasOn
                ? '자극이 자동으로 정지되었습니다.'
                : '연속 카운트 도달 (FES 미가동).',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('확인'),
        ),
      ],
    ),
  );
}
