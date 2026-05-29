import 'package:flutter/material.dart';

import '../../core/subject_category.dart';
import '../../services/profile_service.dart';

/// 신규 생성과 기존 편집을 동시에 지원하는 다이얼로그.
/// 반환값: 저장된 UserProfile (취소 시 null).
class ProfileEditDialog extends StatefulWidget {
  final UserProfile? initial;

  const ProfileEditDialog({super.key, this.initial});

  static Future<UserProfile?> show(
    BuildContext context, {
    UserProfile? initial,
  }) {
    return showDialog<UserProfile>(
      context: context,
      builder: (_) => ProfileEditDialog(initial: initial),
    );
  }

  @override
  State<ProfileEditDialog> createState() => _ProfileEditDialogState();
}

class _ProfileEditDialogState extends State<ProfileEditDialog> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _noteCtrl;
  SubjectCategory? _category;

  bool get _isEdit => widget.initial != null;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.initial?.name ?? '');
    _noteCtrl = TextEditingController(text: widget.initial?.note ?? '');
    _category = widget.initial?.category;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('이름을 입력하세요'),
          backgroundColor: Colors.orange,
          duration: Duration(milliseconds: 1500),
        ),
      );
      return;
    }
    final note = _noteCtrl.text.trim();
    final UserProfile saved;
    if (_isEdit) {
      saved = widget.initial!.copyWith(
        name: name,
        category: _category,
        note: note.isEmpty ? null : note,
      );
    } else {
      final id = 'subject_${DateTime.now().millisecondsSinceEpoch}';
      saved = UserProfile(
        id: id,
        name: name,
        category: _category,
        note: note.isEmpty ? null : note,
      );
    }
    await gProfileService.save(saved);
    if (!mounted) return;
    Navigator.pop(context, saved);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_isEdit ? '환자 정보 수정' : '새 환자 프로파일'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _nameCtrl,
              autofocus: !_isEdit,
              decoration: const InputDecoration(
                labelText: '환자 이름 또는 ID',
                hintText: '예: 김환자, Subject 03',
              ),
            ),
            const SizedBox(height: 18),
            const Text(
              '분류',
              style: TextStyle(
                color: Colors.white70,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            ...SubjectCategory.values.map(_buildCategoryRow),
            const SizedBox(height: 14),
            TextField(
              controller: _noteCtrl,
              maxLines: 3,
              minLines: 2,
              decoration: const InputDecoration(
                labelText: '비고 (선택)',
                hintText: '병변 부위, 수술 이력, 측정 조건 등',
                alignLabelWithHint: true,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: _save,
          child: Text(_isEdit ? '저장' : '생성'),
        ),
      ],
    );
  }

  Widget _buildCategoryRow(SubjectCategory c) {
    final selected = _category == c;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: selected
            ? c.color.withValues(alpha: 0.15)
            : Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => setState(() => _category = c),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            decoration: BoxDecoration(
              border: Border.all(
                color: selected ? c.color : Colors.white24,
                width: selected ? 1.5 : 1,
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: c.color.withValues(alpha: selected ? 0.9 : 0.3),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    c.code,
                    style: TextStyle(
                      color: selected ? Colors.black : Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        c.label,
                        style: TextStyle(
                          color: selected ? Colors.white : Colors.white70,
                          fontSize: 13,
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.normal,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        c.description,
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 18,
                  color: selected ? c.color : Colors.white38,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
