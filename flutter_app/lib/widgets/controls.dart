import 'package:flutter/material.dart';

class ControlsBar extends StatelessWidget {
  final bool canSend;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final VoidCallback onCalibrate;
  final ValueChanged<String> onMarker;
  final VoidCallback onEmergency;

  const ControlsBar({
    super.key,
    required this.canSend,
    required this.onStart,
    required this.onStop,
    required this.onCalibrate,
    required this.onMarker,
    required this.onEmergency,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      alignment: WrapAlignment.center,
      children: [
        FilledButton.icon(
          onPressed: canSend ? onStart : null,
          icon: const Icon(Icons.play_arrow),
          label: const Text('Start'),
        ),
        FilledButton.tonalIcon(
          onPressed: canSend ? onStop : null,
          icon: const Icon(Icons.stop),
          label: const Text('Stop'),
        ),
        OutlinedButton.icon(
          onPressed: canSend ? onCalibrate : null,
          icon: const Icon(Icons.refresh),
          label: const Text('Calibrate'),
        ),
        OutlinedButton.icon(
          onPressed: canSend ? () => onMarker('easy') : null,
          icon: const Icon(Icons.flag_outlined),
          label: const Text('Easy'),
        ),
        OutlinedButton.icon(
          onPressed: canSend ? () => onMarker('medium') : null,
          icon: const Icon(Icons.flag_outlined),
          label: const Text('Medium'),
        ),
        OutlinedButton.icon(
          onPressed: canSend ? () => onMarker('hard') : null,
          icon: const Icon(Icons.flag),
          label: const Text('Hard'),
        ),
        FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: Colors.red),
          onPressed: canSend ? onEmergency : null,
          icon: const Icon(Icons.warning),
          label: const Text('Emergency'),
        ),
      ],
    );
  }
}
