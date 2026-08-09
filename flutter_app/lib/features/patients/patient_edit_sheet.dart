import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/subject_category.dart';
import '../../services/profile_service.dart';
import '../app_state.dart';
import '../refit_theme.dart';

/// 환자 추가 / 수정 시트.
///
/// 항목은 **이름 · 나이 · 마비 유형** 셋뿐이다. 첫 실행부터 게임 시작까지
/// 3분 안에 들어와야 하므로 고를 것을 늘리지 않는다. 나머지(비고·기준선
/// 등)는 레거시 모니터 앱이 채우고, 여기서는 묻지 않는다.
///
/// 셋 다 채워야 저장된다. 특히 마비 유형은 **분석 경로를 바꾸는 스위치**라
/// 비워 둔 채로 훈련에 들어갈 수 없다.
Future<bool> showPatientEditSheet(
  BuildContext context, {
  UserProfile? patient,
}) async {
  final saved = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: RefitTheme.deep,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
    builder: (_) => _PatientEditSheet(patient: patient),
  );
  return saved ?? false;
}

class _PatientEditSheet extends StatefulWidget {
  const _PatientEditSheet({this.patient});

  final UserProfile? patient;

  @override
  State<_PatientEditSheet> createState() => _PatientEditSheetState();
}

class _PatientEditSheetState extends State<_PatientEditSheet> {
  late final TextEditingController _name =
      TextEditingController(text: widget.patient?.name ?? '');
  late final TextEditingController _age =
      TextEditingController(text: widget.patient?.age?.toString() ?? '');

  /// 등록 화면에서 고를 수 있는 것은 완전마비 / 불완전마비 둘뿐이다.
  /// [SubjectCategory.healthy] 는 레거시 대조군 측정용이라 여기 없다.
  late SubjectCategory? _type = switch (widget.patient?.category) {
    SubjectCategory.complete => SubjectCategory.complete,
    SubjectCategory.incomplete => SubjectCategory.incomplete,
    _ => null,
  };

  @override
  void dispose() {
    _name.dispose();
    _age.dispose();
    super.dispose();
  }

  bool get _canSave =>
      _name.text.trim().isNotEmpty &&
      int.tryParse(_age.text.trim()) != null &&
      _type != null;

  Future<void> _save() async {
    final existing = widget.patient;
    final id = existing?.id ??
        'p_${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';

    final p = existing == null
        ? UserProfile(
            id: id,
            name: _name.text.trim(),
            age: int.parse(_age.text.trim()),
            category: _type,
          )
        : (existing
          ..name = _name.text.trim()
          ..age = int.parse(_age.text.trim())
          ..category = _type);

    await gApp.savePatient(p);
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(24, 22, 24, 22 + bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 44,
                height: 4,
                margin: const EdgeInsets.only(bottom: 22),
                decoration: BoxDecoration(
                  color: RefitTheme.inkFaint,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Text(
              widget.patient == null ? '환자 추가' : '환자 수정',
              style: RefitTheme.title,
            ),
            const SizedBox(height: 24),

            Text('이름', style: RefitTheme.label),
            const SizedBox(height: 8),
            _Field(
              controller: _name,
              hint: '예: 김재활',
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 20),

            Text('나이', style: RefitTheme.label),
            const SizedBox(height: 8),
            _Field(
              controller: _age,
              hint: '예: 54',
              keyboardType: TextInputType.number,
              formatters: [FilteringTextInputFormatter.digitsOnly],
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 24),

            Text('마비 유형', style: RefitTheme.label),
            const SizedBox(height: 8),
            Text(
              '피로를 어떤 지표로 볼지가 여기서 갈립니다.',
              style: RefitTheme.bodySmall.copyWith(fontSize: 14),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _TypeToggle(
                    label: '완전마비',
                    selected: _type == SubjectCategory.complete,
                    onTap: () =>
                        setState(() => _type = SubjectCategory.complete),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _TypeToggle(
                    label: '불완전마비',
                    selected: _type == SubjectCategory.incomplete,
                    onTap: () =>
                        setState(() => _type = SubjectCategory.incomplete),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              fatigueBasisFor(_type),
              style: RefitTheme.bodySmall.copyWith(fontSize: 14),
            ),

            const SizedBox(height: 28),
            RefitButton(
              label: '저장',
              onPressed: _canSave ? _save : null,
            ),
          ],
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.controller,
    required this.hint,
    required this.onChanged,
    this.keyboardType,
    this.formatters,
  });

  final TextEditingController controller;
  final String hint;
  final ValueChanged<String> onChanged;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? formatters;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      onChanged: onChanged,
      keyboardType: keyboardType,
      inputFormatters: formatters,
      style: RefitTheme.body.copyWith(color: RefitTheme.ink),
      cursorColor: RefitTheme.glow,
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: RefitTheme.body.copyWith(color: RefitTheme.inkFaint),
        filled: true,
        fillColor: RefitTheme.panel,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(
            color: RefitTheme.glow.withValues(alpha: 0.6),
            width: 1.5,
          ),
        ),
      ),
    );
  }
}

class _TypeToggle extends StatelessWidget {
  const _TypeToggle({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          height: RefitTheme.touchMin,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected
                ? RefitTheme.glow.withValues(alpha: 0.18)
                : RefitTheme.panel,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: selected
                  ? RefitTheme.glow.withValues(alpha: 0.7)
                  : RefitTheme.hairline,
              width: selected ? 1.6 : 1,
            ),
          ),
          child: Text(
            label,
            style: RefitTheme.body.copyWith(
              color: selected ? RefitTheme.glow : RefitTheme.inkSoft,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
      ),
    );
  }
}
