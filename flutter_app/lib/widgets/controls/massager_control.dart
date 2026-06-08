import 'package:flutter/material.dart';

/// 마사지기 강도 UP/DOWN 조절 버튼 (EMG 와 무관한 릴레이 컨트롤러용).
/// 누르면 'up' / 'down' 명령을 전송 — 시뮬레이터 또는 릴레이 ESP 가 처리.
class MassagerControl extends StatelessWidget {
  final bool canSend;
  final VoidCallback onUp;
  final VoidCallback onDown;
  final int? level; // 시뮬에서 보고하는 현재 강도(0~10), 없으면 표시 안 함

  const MassagerControl({
    super.key,
    required this.canSend,
    required this.onUp,
    required this.onDown,
    this.level,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Icon(Icons.vibration, size: 18, color: Colors.black54),
        const SizedBox(width: 8),
        const Text('마사지기 강도', style: TextStyle(fontWeight: FontWeight.w600)),
        if (level != null) ...[
          const SizedBox(width: 8),
          Text(
            '$level',
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: Colors.deepPurple,
            ),
          ),
        ],
        const Spacer(),
        OutlinedButton.icon(
          onPressed: canSend ? onDown : null,
          icon: const Icon(Icons.remove),
          label: const Text('Down'),
        ),
        const SizedBox(width: 8),
        FilledButton.tonalIcon(
          onPressed: canSend ? onUp : null,
          icon: const Icon(Icons.add),
          label: const Text('Up'),
        ),
      ],
    );
  }
}
