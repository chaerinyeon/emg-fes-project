import 'package:flutter/material.dart';

import '../../core/subject_category.dart';

/// 활성 환자 분류에 따른 fatigue 판정 알고리즘 표시.
class AlgorithmBadge extends StatelessWidget {
  final SubjectCategory? category;
  const AlgorithmBadge({super.key, required this.category});

  String _description() {
    switch (category) {
      case SubjectCategory.healthy:
        return 'RMS slope ↑ AND MDF slope ↓';
      case SubjectCategory.incomplete:
        return 'RMS / MDF / M-wave 중 2개 이상';
      case SubjectCategory.complete:
        return 'M-wave 진폭·면적·잠복기 변화';
      case null:
        return '미분류 — 기본 RMS+MDF';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          'algorithm',
          style: TextStyle(
            color: Colors.black38,
            fontSize: 10,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            _description(),
            style: const TextStyle(color: Colors.black54, fontSize: 11),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
