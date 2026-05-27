import 'package:flutter/material.dart';

import '../../services/profile_service.dart';

class ProfileBar extends StatelessWidget {
  final ProfileService service;
  final VoidCallback onChanged;

  const ProfileBar({
    super.key,
    required this.service,
    required this.onChanged,
  });

  Future<void> _showCreateProfileDialog(BuildContext context) async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('새 프로파일'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '환자 이름 또는 ID',
            hintText: 'Subject B',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('생성'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    final id = 'subject_${DateTime.now().millisecondsSinceEpoch}';
    final p = UserProfile(id: id, name: name);
    await service.save(p);
    await service.setActive(id);
    onChanged();
  }

  Future<void> _showDeleteProfileDialog(
    BuildContext context,
    String id,
  ) async {
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

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.indigo.withValues(alpha: 0.15),
        border: Border.all(color: Colors.indigoAccent.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          const Icon(Icons.person, size: 18, color: Colors.indigoAccent),
          const SizedBox(width: 8),
          Expanded(
            child: profile == null
                ? const Text(
                    '환자 프로파일 없음',
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Text(
                            profile.name,
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.indigoAccent.withValues(alpha: 0.3),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              '${profile.sessionCount} 세션',
                              style: const TextStyle(fontSize: 10),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        [
                          if (profile.mvcRms != null)
                            'MVC ${profile.mvcRms!.toStringAsFixed(0)}',
                          if (profile.restingRms != null)
                            'rest ${profile.restingRms!.toStringAsFixed(0)}',
                          if (profile.mdfBaseline != null)
                            'MDF baseline ${profile.mdfBaseline!.toStringAsFixed(0)}Hz',
                        ].join('  |  '),
                        style: const TextStyle(
                          color: Colors.white60,
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
              color: Colors.white70,
            ),
            tooltip: '프로파일 전환/관리',
            onSelected: (v) async {
              if (v == '__new') {
                await _showCreateProfileDialog(context);
              } else if (v == '__delete' && profile != null) {
                await _showDeleteProfileDialog(context, profile.id);
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
                            ? Colors.indigoAccent
                            : Colors.white54,
                      ),
                      const SizedBox(width: 8),
                      Text(p.name),
                    ],
                  ),
                ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: '__new',
                child: Row(
                  children: [
                    Icon(Icons.add, size: 16, color: Colors.greenAccent),
                    SizedBox(width: 8),
                    Text('+ 새 프로파일'),
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
}
