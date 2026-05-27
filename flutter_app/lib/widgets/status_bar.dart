import 'package:flutter/material.dart';

import '../models.dart';

class StatusBar extends StatelessWidget {
  final String connState;
  final AppStatus status;

  const StatusBar({super.key, required this.connState, required this.status});

  @override
  Widget build(BuildContext context) {
    Color stateColor;
    switch (connState) {
      case 'connected':
        stateColor = Colors.green;
        break;
      case 'connecting':
      case 'scanning':
        stateColor = Colors.orange;
        break;
      case 'error':
        stateColor = Colors.red;
        break;
      default:
        stateColor = Colors.grey;
    }
    final chips = <Widget>[
      _chip(connState.toUpperCase(), stateColor),
      if (status.isRunning) _chip('RUN', Colors.indigo),
      if (status.isStimulating) _chip('STIM', Colors.orange),
      if (status.fatigueDetected) _chip('FATIGUE', Colors.red),
      _chip('state: ${status.muscleState}', Colors.blueGrey),
      _chip('hist ${status.historyCount}', Colors.blueGrey),
    ];
    return Wrap(spacing: 6, runSpacing: 6, children: chips);
  }

  Widget _chip(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.25),
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(label, style: TextStyle(color: color, fontSize: 12)),
    );
  }
}
