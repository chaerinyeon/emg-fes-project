import 'package:flutter/material.dart';

import '../core/subject_category.dart';
import '../services/profile_service.dart';
import '../widgets/profile/profile_edit_dialog.dart';
import 'home_page.dart';
import 'refit_monitor_screen.dart';

class ProfileSelectScreen extends StatefulWidget {
  const ProfileSelectScreen({super.key});

  @override
  State<ProfileSelectScreen> createState() => _ProfileSelectScreenState();
}

class _ProfileSelectScreenState extends State<ProfileSelectScreen> {
  SubjectCategory? _filter; // null = 전체

  // 펌웨어가 두 세대 공존한다. v0.2(REFIT-FES-01·바이너리)는 M-wave 에폭만 보내고,
  // 구펌웨어(EMG-FES-01·JSON)는 ENV/RMS/MDF 를 보낸다. 두 화면은 데이터 모델이
  // 달라 합칠 수 없으므로 진입 시 고른다. 기본은 v0.2.
  bool _legacyMode = false;

  Future<void> _enter(String profileId) async {
    await gProfileService.setActive(profileId);
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) =>
            _legacyMode ? const HomePage() : const RefitMonitorScreen(),
      ),
    );
  }

  Future<void> _createProfile() async {
    final saved = await ProfileEditDialog.show(context);
    if (saved == null || !mounted) return;
    setState(() {});
  }

  Future<void> _editProfile(UserProfile p) async {
    final saved = await ProfileEditDialog.show(context, initial: p);
    if (saved == null || !mounted) return;
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

  Map<SubjectCategory?, int> _countByCategory(List<UserProfile> all) {
    final map = <SubjectCategory?, int>{};
    for (final p in all) {
      map[p.category] = (map[p.category] ?? 0) + 1;
    }
    return map;
  }

  @override
  Widget build(BuildContext context) {
    final all = gProfileService.all();
    final activeId = gProfileService.active?.id;
    final counts = _countByCategory(all);
    final visible = _filter == null
        ? all
        : all.where((p) => p.category == _filter).toList();

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 28, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '환자 선택',
                style: TextStyle(
                  color: Colors.black87,
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              const Text(
                '측정할 환자 프로파일을 선택하세요',
                style: TextStyle(color: Colors.black38, fontSize: 12),
              ),
              const SizedBox(height: 16),
              _buildFirmwareRow(),
              const SizedBox(height: 10),
              _buildFilterRow(all.length, counts),
              const SizedBox(height: 12),
              Expanded(
                child: visible.isEmpty
                    ? _buildEmpty(all.isEmpty)
                    : ListView.separated(
                        itemCount: visible.length,
                        separatorBuilder: (_, i) => const SizedBox(height: 8),
                        itemBuilder: (_, i) {
                          final p = visible[i];
                          return _ProfileTile(
                            profile: p,
                            isActive: p.id == activeId,
                            onTap: () => _enter(p.id),
                            onEdit: () => _editProfile(p),
                            onDelete: all.length > 1
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
                icon: const Icon(Icons.add, size: 18),
                label: const Text('새 환자 추가'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.black54,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  side: const BorderSide(color: Colors.black26),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFirmwareRow() {
    return Row(
      children: [
        const Text(
          '펌웨어',
          style: TextStyle(color: Colors.black38, fontSize: 11),
        ),
        const SizedBox(width: 8),
        _filterChip(
          label: 'v0.2 M-wave',
          count: 0,
          selected: !_legacyMode,
          color: Colors.green.shade800,
          onTap: () => setState(() => _legacyMode = false),
          showCount: false,
        ),
        const SizedBox(width: 6),
        _filterChip(
          label: '구버전 RMS/MDF',
          count: 0,
          selected: _legacyMode,
          color: Colors.black54,
          onTap: () => setState(() => _legacyMode = true),
          showCount: false,
        ),
      ],
    );
  }

  Widget _buildFilterRow(int total, Map<SubjectCategory?, int> counts) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          _filterChip(label: '전체', count: total, selected: _filter == null,
              color: Colors.green.shade800, onTap: () => setState(() => _filter = null)),
          for (final c in SubjectCategory.values) ...[
            const SizedBox(width: 6),
            _filterChip(
              label: '${c.code} · ${c.short}',
              count: counts[c] ?? 0,
              selected: _filter == c,
              color: c.color,
              onTap: () => setState(() => _filter = c),
            ),
          ],
          if ((counts[null] ?? 0) > 0) ...[
            const SizedBox(width: 6),
            _filterChip(
              label: '미분류',
              count: counts[null] ?? 0,
              selected: false, // 미분류는 임시 — 필터 토글로 사용 안 함
              color: Colors.black38,
              onTap: () {},
              dimmed: true,
            ),
          ],
        ],
      ),
    );
  }

  Widget _filterChip({
    required String label,
    required int count,
    required bool selected,
    required Color color,
    required VoidCallback onTap,
    bool dimmed = false,
    bool showCount = true,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: dimmed ? null : onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            border: Border.all(
              color: selected ? color : Colors.black26,
            ),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            showCount ? '$label  $count' : label,
            style: TextStyle(
              color: selected ? color : Colors.black54,
              fontSize: 11,
              fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEmpty(bool noProfilesAtAll) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.person_outline,
            size: 64,
            color: Colors.black.withValues(alpha: 0.2),
          ),
          const SizedBox(height: 16),
          Text(
            noProfilesAtAll
                ? '등록된 환자가 없습니다'
                : '해당 분류의 환자가 없습니다',
            style: const TextStyle(color: Colors.black54, fontSize: 14),
          ),
          const SizedBox(height: 6),
          Text(
            noProfilesAtAll
                ? '아래 버튼으로 첫 환자를 추가하세요'
                : '필터를 전체로 바꾸거나 새 환자를 추가하세요',
            style: const TextStyle(color: Colors.black38, fontSize: 12),
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
  final VoidCallback onEdit;
  final VoidCallback? onDelete;
  final String lastSessionLabel;

  const _ProfileTile({
    required this.profile,
    required this.isActive,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
    required this.lastSessionLabel,
  });

  @override
  Widget build(BuildContext context) {
    final cat = profile.category;
    final stripeColor = cat?.color ?? Colors.black26;
    return Material(
      color: isActive
          ? Colors.black.withValues(alpha: 0.05)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(color: Colors.black12),
            borderRadius: BorderRadius.circular(6),
          ),
          child: IntrinsicHeight(
            child: Row(
              children: [
                Container(
                  width: 3,
                  color: stripeColor,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            if (cat != null) ...[
                              Text(
                                cat.code,
                                style: TextStyle(
                                  color: cat.color,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(width: 8),
                            ],
                            Flexible(
                              child: Text(
                                profile.name,
                                style: const TextStyle(
                                  color: Colors.black87,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (isActive) ...[
                              const SizedBox(width: 6),
                              const Icon(
                                Icons.check,
                                size: 13,
                                color: Colors.black45,
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '${cat == null ? '미분류' : cat.label}  ·  ${profile.sessionCount}회  ·  $lastSessionLabel',
                          style: const TextStyle(
                            color: Colors.black45,
                            fontSize: 11,
                          ),
                        ),
                        if (profile.note != null &&
                            profile.note!.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            profile.note!,
                            style: const TextStyle(
                              color: Colors.black38,
                              fontSize: 10,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                PopupMenuButton<String>(
                  icon: const Icon(
                    Icons.more_horiz,
                    color: Colors.black38,
                    size: 18,
                  ),
                  onSelected: (v) {
                    if (v == 'edit') onEdit();
                    if (v == 'delete' && onDelete != null) onDelete!();
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                      value: 'edit',
                      child: Text('수정'),
                    ),
                    if (onDelete != null)
                      const PopupMenuItem(
                        value: 'delete',
                        child: Text('삭제'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
