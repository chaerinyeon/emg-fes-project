import 'package:flutter/material.dart';

/// 환자 분류 — 측정 대상의 신경학적 상태.
/// A: 건강한 비장애인, B: 불완전 마비 환자, C: 완전 마비 환자.
enum SubjectCategory {
  healthy(
    code: 'A',
    label: '건강한 비장애인',
    short: '건강',
    description: '신경학적 손상 없음. 대조군(control) 측정에 사용.',
    color: Color(0xFF69F0AE), // 연두 (cRms와 통일)
  ),
  incomplete(
    code: 'B',
    label: '불완전 마비 환자',
    short: '불완전마비',
    description: '부분적 운동 기능 보존. 잔존 EMG 신호 측정 가능.',
    color: Color(0xFFFFD180), // 주황 (cMdf와 통일)
  ),
  complete(
    code: 'C',
    label: '완전 마비 환자',
    short: '완전마비',
    description: '자발적 운동 기능 소실. FES 자극 반응 평가.',
    color: Color(0xFFFF8A80), // 분홍 (cRmsSlope와 통일)
  );

  final String code;
  final String label;
  final String short;
  final String description;
  final Color color;

  const SubjectCategory({
    required this.code,
    required this.label,
    required this.short,
    required this.description,
    required this.color,
  });

  /// 저장된 코드 문자열로부터 enum 복원. 미지의 값/null이면 null 반환.
  static SubjectCategory? fromCode(String? code) {
    if (code == null) return null;
    for (final c in values) {
      if (c.code == code) return c;
    }
    return null;
  }
}
