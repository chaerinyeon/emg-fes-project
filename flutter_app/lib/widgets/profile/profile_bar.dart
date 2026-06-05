import 'package:flutter/material.dart';

import '../../core/subject_category.dart';
import '../../services/profile_service.dart';
import 'profile_edit_dialog.dart';

class ProfileBar extends StatelessWidget {
  final ProfileService service;
  final VoidCallback onChanged;

  const ProfileBar({
    super.key,
    required this.service,
    required this.onChanged,
  });

  Future<void> _createProfile(BuildContext context) async {
    final saved = await ProfileEditDialog.show(context);
    if (saved == null) return;
    await service.setActive(saved.id);
    onChanged();
  }

  Future<void> _editProfile(BuildContext context, UserProfile p) async {
    final saved = await ProfileEditDialog.show(context, initial: p);
    if (saved == null) return;
    onChanged();
  }

  Future<void> _deleteProfile(BuildContext context, String id) async {
    final p = service.get(id);
    if (p == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('프로파일 삭제'),
        content: Text('${p.name}을(를) 삭제하시겠습니까? (세션 기록 ${p.sessionCount}회)'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await service.delete(id);
      onChanged();
    }
  }

  @override
  Widget build(BuildContext context) {
    final profile = service.active;
    final list = service.all();
    final cat = profile?.category;
    final accent = cat?.color ?? Colors.green.shade800;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.04),
        border: Border.all(color: Colors.black12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          Icon(Icons.person_outline, size: 18, color: accent),
          const SizedBox(width: 8),
          Expanded(
            child: profile == null
                ? const Text(
                    '환자 프로파일 없음',
                    style: TextStyle(color: Colors.black54, fontSize: 12),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          if (cat != null) ...[
                            _categoryBadge(cat),
                            const SizedBox(width: 6),
                          ],
                          Flexible(
                            child: Text(
                              profile.name,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '${profile.sessionCount} 세션',
                            style: const TextStyle(
                              fontSize: 10,
                              color: Colors.black45,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        [
                          if (cat != null) cat.label,
                          if (profile.mvcRms != null)
                            'MVC ${profile.mvcRms!.toStringAsFixed(0)}',
                          if (profile.restingRms != null)
                            'rest ${profile.restingRms!.toStringAsFixed(0)}',
                          if (profile.mdfBaseline != null)
                            'MDF ${profile.mdfBaseline!.toStringAsFixed(0)}Hz',
                        ].join('  |  '),
                        style: const TextStyle(
                          color: Colors.black54,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
          ),
          PopupMenuButton<String>(
            icon: const Icon(
              Icons.expand_more,
              size: 20,
              color: Colors.black54,
            ),
            tooltip: '프로파일 전환/관리',
            onSelected: (v) async {
              if (v == '__new') {
                await _createProfile(context);
              } else if (v == '__edit' && profile != null) {
                await _editProfile(context, profile);
              } else if (v == '__delete' && profile != null) {
                await _deleteProfile(context, profile.id);
              } else {
                await service.setActive(v);
                onChanged();
              }
            },
            itemBuilder: (_) => [
              for (final p in list)
                PopupMenuItem(
                  value: p.id,
                  child: Row(
                    children: [
                      Icon(
                        p.id == profile?.id
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                        size: 16,
                        color: p.id == profile?.id
                            ? Colors.green.shade800
                            : Colors.black45,
                      ),
                      const SizedBox(width: 8),
                      if (p.category != null) ...[
                        Container(
                          width: 18,
                          height: 18,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: p.category!.color.withValues(alpha: 0.7),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            p.category!.code,
                            style: const TextStyle(
                              color: Colors.black,
                              fontWeight: FontWeight.bold,
                              fontSize: 10,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                      ],
                      Text(p.name),
                    ],
                  ),
                ),
              const PopupMenuDivider(),
              if (profile != null)
                const PopupMenuItem(
                  value: '__edit',
                  child: Row(
                    children: [
                      Icon(Icons.edit, size: 16, color: Colors.black54),
                      SizedBox(width: 8),
                      Text('현재 프로파일 수정'),
                    ],
                  ),
                ),
              PopupMenuItem(
                value: '__new',
                child: Row(
                  children: [
                    Icon(Icons.add, size: 16, color: Colors.green.shade600),
                    const SizedBox(width: 8),
                    const Text('+ 새 프로파일'),
                  ],
                ),
              ),
              if (profile != null && list.length > 1)
                const PopupMenuItem(
                  value: '__delete',
                  child: Row(
                    children: [
                      Icon(
                        Icons.delete_outline,
                        size: 16,
                        color: Colors.redAccent,
                      ),
                      SizedBox(width: 8),
                      Text('현재 프로파일 삭제'),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _categoryBadge(SubjectCategory c) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        border: Border.all(color: c.color, width: 1),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        c.code,
        style: TextStyle(
          color: c.color,
          fontWeight: FontWeight.w600,
          fontSize: 10,
        ),
      ),
    );
  }
}
