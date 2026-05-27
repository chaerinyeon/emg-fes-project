import 'package:flutter/material.dart';

import '../services/profile_service.dart';
import 'home_page.dart';

class ProfileSelectScreen extends StatefulWidget {
  const ProfileSelectScreen({super.key});

  @override
  State<ProfileSelectScreen> createState() => _ProfileSelectScreenState();
}

class _ProfileSelectScreenState extends State<ProfileSelectScreen> {
  Future<void> _enter(String profileId) async {
    await gProfileService.setActive(profileId);
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const HomePage()),
    );
  }

  Future<void> _createProfile() async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('새 환자 프로파일'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '환자 이름 또는 ID',
            hintText: 'Subject A',
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
    await gProfileService.save(p);
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _deleteProfile(UserProfile p) async {
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
      await gProfileService.delete(p.id);
      if (!mounted) return;
      setState(() {});
    }
  }

  String _formatLastSession(String? iso) {
    if (iso == null) return '기록 없음';
    final t = DateTime.tryParse(iso);
    if (t == null) return '—';
    final d = DateTime.now().difference(t);
    if (d.inDays > 0) return '${d.inDays}일 전';
    if (d.inHours > 0) return '${d.inHours}시간 전';
    if (d.inMinutes > 0) return '${d.inMinutes}분 전';
    return '방금 전';
  }

  @override
  Widget build(BuildContext context) {
    final profiles = gProfileService.all();
    final activeId = gProfileService.active?.id;

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 28, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.indigoAccent.withValues(alpha: 0.2),
                      border: Border.all(color: Colors.indigoAccent),
                    ),
                    child: const Icon(
                      Icons.person,
                      color: Colors.indigoAccent,
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: const [
                      Text(
                        '환자 선택',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      SizedBox(height: 2),
                      Text(
                        '측정할 환자 프로파일을 선택하세요',
                        style: TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 24),
              Expanded(
                child: profiles.isEmpty
                    ? _buildEmpty()
                    : ListView.separated(
                        itemCount: profiles.length,
                        separatorBuilder: (_, i) => const SizedBox(height: 8),
                        itemBuilder: (_, i) {
                          final p = profiles[i];
                          return _ProfileTile(
                            profile: p,
                            isActive: p.id == activeId,
                            onTap: () => _enter(p.id),
                            onDelete: profiles.length > 1
                                ? () => _deleteProfile(p)
                                : null,
                            lastSessionLabel: _formatLastSession(p.lastSessionAt),
                          );
                        },
                      ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _createProfile,
                icon: const Icon(Icons.add),
                label: const Text('새 환자 프로파일 추가'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.greenAccent,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  side: const BorderSide(color: Colors.greenAccent),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.person_outline,
            size: 64,
            color: Colors.white.withValues(alpha: 0.3),
          ),
          const SizedBox(height: 16),
          const Text(
            '등록된 환자가 없습니다',
            style: TextStyle(color: Colors.white60, fontSize: 14),
          ),
          const SizedBox(height: 6),
          const Text(
            '아래 버튼으로 첫 환자를 추가하세요',
            style: TextStyle(color: Colors.white38, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _ProfileTile extends StatelessWidget {
  final UserProfile profile;
  final bool isActive;
  final VoidCallback onTap;
  final VoidCallback? onDelete;
  final String lastSessionLabel;

  const _ProfileTile({
    required this.profile,
    required this.isActive,
    required this.onTap,
    required this.onDelete,
    required this.lastSessionLabel,
  });

  @override
  Widget build(BuildContext context) {
    final accent = isActive ? Colors.indigoAccent : Colors.white24;
    return Material(
      color: isActive
          ? Colors.indigoAccent.withValues(alpha: 0.12)
          : Colors.white.withValues(alpha: 0.04),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
          decoration: BoxDecoration(
            border: Border.all(color: accent, width: isActive ? 1.5 : 1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              CircleAvatar(
                radius: 20,
                backgroundColor: accent.withValues(alpha: 0.3),
                child: Text(
                  profile.name.isNotEmpty
                      ? profile.name.characters.first.toUpperCase()
                      : '?',
                  style: TextStyle(
                    color: isActive ? Colors.white : Colors.white70,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          profile.name,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (isActive) ...[
                          const SizedBox(width: 6),
                          const Icon(
                            Icons.check_circle,
                            size: 14,
                            color: Colors.indigoAccent,
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${profile.sessionCount} 세션 · $lastSessionLabel',
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 11,
                      ),
                    ),
                    if (profile.mvcRms != null ||
                        profile.restingRms != null) ...[
                      const SizedBox(height: 3),
                      Text(
                        [
                          if (profile.mvcRms != null)
                            'MVC ${profile.mvcRms!.toStringAsFixed(0)}',
                          if (profile.restingRms != null)
                            'rest ${profile.restingRms!.toStringAsFixed(0)}',
                          if (profile.mdfBaseline != null)
                            'MDF ${profile.mdfBaseline!.toStringAsFixed(0)}Hz',
                        ].join('  ·  '),
                        style: const TextStyle(
                          color: Colors.white38,
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (onDelete != null)
                IconButton(
                  icon: const Icon(
                    Icons.delete_outline,
                    size: 18,
                    color: Colors.white38,
                  ),
                  onPressed: onDelete,
                  tooltip: '삭제',
                ),
              const Icon(
                Icons.chevron_right,
                color: Colors.white38,
                size: 22,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
