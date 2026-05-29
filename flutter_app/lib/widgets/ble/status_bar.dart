import 'package:flutter/material.dart';

import '../../core/models.dart';

class StatusBar extends StatelessWidget {
  final String connState;
  final AppStatus status;

  const StatusBar({super.key, required this.connState, required this.status});

  @override
  Widget build(BuildContext context) {
    Color stateColor;
    switch (connState) {
      case 'connected':
        stateColor = Colors.greenAccent;
        break;
      case 'connecting':
      case 'scanning':
        stateColor = Colors.orangeAccent;
        break;
      case 'error':
        stateColor = Colors.redAccent;
        break;
      default:
        stateColor = Colors.white54;
    }
    final chips = <Widget>[
      _chip(connState.toUpperCase(), stateColor),
      if (status.isRunning) _chip('RUN', Colors.white70),
      if (status.isStimulating) _chip('STIM', Colors.orangeAccent),
      if (status.fatigueDetected) _chip('FATIGUE', Colors.redAccent),
      _chip(status.muscleState, Colors.white54),
      _chip('hist ${status.historyCount}', Colors.white54),
    ];
    return Wrap(spacing: 6, runSpacing: 6, children: chips);
  }

  Widget _chip(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        border: Border.all(color: color.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(label, style: TextStyle(color: color, fontSize: 11)),
    );
  }
}
