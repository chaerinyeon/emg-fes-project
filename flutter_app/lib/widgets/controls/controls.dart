import 'package:flutter/material.dart';

class ControlsBar extends StatelessWidget {
  /// 기기로 명령을 보낼 수 있는가 (BLE 연결됨). Start/Calibrate/Marker/Emergency 용.
  final bool canSend;

  /// 세션을 끝낼 수 있는가 — 보통 '세션 진행 중'. [canSend] 와 '별개'로 받는다.
  /// Stop 은 기기 명령 전송이자 로컬 CSV 저장 트리거인데, 저장은 연결과 무관하다.
  /// 예전엔 canSend 하나로 묶여 있어 측정 중 블루투스가 끊기면 Stop 이 죽고
  /// 세션 데이터가 메모리에 갇혔다.
  final bool canStop;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final VoidCallback onCalibrate;
  final ValueChanged<String> onMarker;
  final VoidCallback onEmergency;

  const ControlsBar({
    super.key,
    required this.canSend,
    required this.canStop,
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
          onPressed: canStop ? onStop : null,
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
