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
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
      decoration: BoxDecoration(
        color: Colors.redAccent.withValues(alpha: 0.1),
        border: Border.all(color: Colors.redAccent.withValues(alpha: 0.6)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.warning_amber_outlined,
            color: Colors.redAccent,
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '근피로 감지 — 계속 진행 중',
                  style: TextStyle(
                    color: Colors.black87,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'RMS slope +${rmsSlope.toStringAsFixed(1)}%   ·   MDF slope ${mdfSlope.toStringAsFixed(1)}%',
                  style: const TextStyle(color: Colors.black54, fontSize: 11),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
