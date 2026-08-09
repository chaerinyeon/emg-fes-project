import 'package:flutter/material.dart';

import '../../core/subject_category.dart';
import '../../services/profile_service.dart';
import '../app_state.dart';
import '../refit_theme.dart';
import 'patient_edit_sheet.dart';

/// 환자 선택 및 등록.
///
/// 세 곳에서 열린다 — 최초 진입(탭 바깥) · 홈의 환자 카드 · 설정 > 환자 관리.
/// 그래서 [dismissible] 로 "닫을 수 있는가"만 달라지고 내용은 같다.
///
/// **환자 간 비교·순위를 만들지 않는다**(하드 제약 6). 카드에 들어가는
/// 누적 세션 수·마지막 운동일은 그 환자 자신의 이력일 뿐, 서로 줄 세우는
/// 값이 아니다.
class PatientSelectScreen extends StatefulWidget {
  const PatientSelectScreen({super.key, this.dismissible = true});

  /// 최초 진입에서는 닫을 수 없다 — 환자를 정해야 앱이 시작된다.
  final bool dismissible;

  @override
  State<PatientSelectScreen> createState() => _PatientSelectScreenState();
}

class _PatientSelectScreenState extends State<PatientSelectScreen> {
  Future<void> _add() async {
    if (await showPatientEditSheet(context) && mounted) setState(() {});
  }

  Future<void> _edit(UserProfile p) async {
    if (await showPatientEditSheet(context, patient: p) && mounted) {
      setState(() {});
    }
  }

  Future<void> _pick(UserProfile p) async {
    await gApp.selectPatient(p.id);
    if (!mounted) return;

    // 마비 유형이 비어 있으면 고르는 것만으로는 훈련에 못 들어간다. 길게
    // 눌러 수정하라고 하는 대신, 여기서 바로 물어본다 — 첫 실행에서 이
    // 화면에 갇히는 유일한 경로다.
    if (p.category == null) {
      await showPatientEditSheet(context, patient: p);
      if (!mounted) return;
      if (gApp.patientReady && widget.dismissible) {
        Navigator.of(context).pop();
        return;
      }
      setState(() {});
      return;
    }

    if (widget.dismissible) {
      Navigator.of(context).pop();
    } else {
      setState(() {});
    }
  }

  Future<void> _confirmDelete(UserProfile p) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: RefitTheme.deep,
        title: Text('${p.name} 님을 지울까요?', style: RefitTheme.body),
        content: Text(
          '이 환자의 훈련 기록은 남습니다.',
          style: RefitTheme.bodySmall,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('그대로 두기'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: RefitTheme.alert),
            child: const Text('지우기'),
          ),
        ],
      ),
    );
    if (yes != true) return;
    await gApp.deletePatient(p.id);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final list = gApp.patients;
    final activeId = gApp.patient?.id;

    return Scaffold(
      body: RefitBackdrop(
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 12, 0),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('환자', style: RefitTheme.label),
                          const SizedBox(height: 10),
                          Text('누가\n훈련하나요', style: RefitTheme.display),
                        ],
                      ),
                    ),
                    if (widget.dismissible)
                      IconButton(
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close_rounded),
                        color: RefitTheme.inkSoft,
                        iconSize: 28,
                      ),
                  ],
                ),
              ),
              Expanded(
                child: list.isEmpty
                    ? Center(
                        child: Text(
                          '등록된 환자가 없어요.\n아래에서 추가해 주세요.',
                          style: RefitTheme.body,
                          textAlign: TextAlign.center,
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(24, 26, 24, 12),
                        itemCount: list.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 12),
                        itemBuilder: (_, i) => _PatientCard(
                          patient: list[i],
                          selected: list[i].id == activeId,
                          sessionCount: gApp.sessions
                              .where((s) => s.patientId == list[i].id)
                              .length,
                          onTap: () => _pick(list[i]),
                          onEdit: () => _edit(list[i]),
                          onDelete: () => _confirmDelete(list[i]),
                        ),
                      ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
                child: RefitButton(
                  label: '＋ 환자 추가',
                  filled: list.isEmpty,
                  onPressed: _add,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PatientCard extends StatelessWidget {
  const _PatientCard({
    required this.patient,
    required this.selected,
    required this.sessionCount,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
  });

  final UserProfile patient;
  final bool selected;
  final int sessionCount;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final type = patient.category;
    final needsType =
        type != SubjectCategory.complete && type != SubjectCategory.incomplete;

    return GestureDetector(
      // 길게 누르면 수정 / 삭제. 주 동작(선택)을 가리지 않게 뒤에 둔다.
      onLongPress: () => _showActions(context),
      child: RefitCard(
        onTap: onTap,
        tint: selected ? RefitTheme.glow : null,
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          patient.name,
                          style: RefitTheme.body.copyWith(
                            color: RefitTheme.ink,
                            fontWeight: FontWeight.w600,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (patient.age != null) ...[
                        const SizedBox(width: 8),
                        Text('${patient.age}세', style: RefitTheme.bodySmall),
                      ],
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      RefitChip(
                        label: needsType ? '마비 유형 필요' : type!.short,
                        tone: needsType ? RefitTheme.alert : RefitTheme.glow,
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          _history,
                          style: RefitTheme.bodySmall.copyWith(fontSize: 14),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (selected)
              const Icon(Icons.check_rounded,
                  color: RefitTheme.glow, size: 26),
          ],
        ),
      ),
    );
  }

  String get _history {
    if (sessionCount == 0) return '훈련 기록 없음';
    final last = patient.lastSessionAt;
    if (last == null) return '누적 $sessionCount회';
    final d = DateTime.tryParse(last);
    if (d == null) return '누적 $sessionCount회';
    return '누적 $sessionCount회 · ${d.month}월 ${d.day}일';
  }

  void _showActions(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: RefitTheme.deep,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            RefitTile(
              title: '수정',
              leading: Icons.edit_outlined,
              onTap: () {
                Navigator.of(ctx).pop();
                onEdit();
              },
            ),
            RefitTile(
              title: '삭제',
              leading: Icons.delete_outline_rounded,
              onTap: () {
                Navigator.of(ctx).pop();
                onDelete();
              },
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}
