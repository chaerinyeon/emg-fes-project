import 'package:flutter/material.dart';

import '../../core/constants.dart';

class LiveReadout extends StatelessWidget {
  final bool active;
  final double envLast;
  final double rmsLast;
  final double mdfLast;

  const LiveReadout({
    super.key,
    required this.active,
    required this.envLast,
    required this.rmsLast,
    required this.mdfLast,
  });

  Widget _tile(String label, String val, Color color, String unit) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(color: Colors.black54, fontSize: 11),
          ),
          const SizedBox(height: 2),
          RichText(
            text: TextSpan(
              children: [
                TextSpan(
                  text: val,
                  style: TextStyle(
                    color: color,
                    fontSize: 26,
                    fontWeight: FontWeight.bold,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                TextSpan(
                  text: '  $unit',
                  style: const TextStyle(color: Colors.black38, fontSize: 11),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.05),
        border: Border.all(color: Colors.black26),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          _tile('ENV', active ? envLast.toStringAsFixed(0) : '—', cEnv, ''),
          Container(width: 1, height: 38, color: Colors.black26),
          const SizedBox(width: 10),
          _tile('RMS', active ? rmsLast.toStringAsFixed(1) : '—', cRms, ''),
          Container(width: 1, height: 38, color: Colors.black26),
          const SizedBox(width: 10),
          _tile('MDF', active ? mdfLast.toStringAsFixed(1) : '—', cMdf, 'Hz'),
        ],
      ),
    );
  }
}
