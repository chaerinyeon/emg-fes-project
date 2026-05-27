import 'package:flutter/material.dart';

class FatigueBanner extends StatelessWidget {
  final double rmsSlope;
  final double mdfSlope;

  const FatigueBanner({
    super.key,
    required this.rmsSlope,
    required this.mdfSlope,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
      decoration: BoxDecoration(
        color: Colors.red.shade800,
        border: Border.all(color: Colors.redAccent, width: 2),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.warning_amber_rounded,
            color: Colors.white,
            size: 28,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '🚨 근피로 감지 — 자극 자동 정지',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  'RMS slope +${rmsSlope.toStringAsFixed(1)}%  |  MDF slope ${mdfSlope.toStringAsFixed(1)}%',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
