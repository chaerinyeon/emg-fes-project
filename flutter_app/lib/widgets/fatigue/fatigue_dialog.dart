import 'package:flutter/material.dart';

import '../../core/models.dart';

/// 근피로 감지 다이얼로그.
/// 관리도 (RMS UCL / MDF LCL) + M-wave 변화량을 트리거 사유와 함께 표시.
void showFatigueDialog(
  BuildContext context, {
  required AppStatus status,
  required bool fesWasOn,
  required List<String> reasons,
  VoidCallback? onConfirm,
}) {
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    useRootNavigator: true,
    builder: (ctx) => AlertDialog(
      icon: const Icon(
        Icons.warning_amber_outlined,
        size: 36,
        color: Colors.redAccent,
      ),
      title: const Text(
        '근피로 감지',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
      ),
      content: _FatigueContent(
        status: status,
        fesWasOn: fesWasOn,
        reasons: reasons,
      ),
      actions: [
        TextButton(
          onPressed: () {
            Navigator.of(ctx).pop();
            onConfirm?.call();
          },
          child: const Text('확인'),
        ),
      ],
    ),
  );
}

class _FatigueContent extends StatelessWidget {
  final AppStatus status;
  final bool fesWasOn;
  final List<String> reasons;
  const _FatigueContent({
    required this.status,
    required this.fesWasOn,
    required this.reasons,
  });

  @override
  Widget build(BuildContext context) {
    final ucl = status.rmsCcUcl;
    final lcl = status.mdfCcLcl;
    final rmsMet = ucl != null && status.lastRms > ucl;
    final mdfMet = lcl != null && status.lastMdf < lcl;
    // M-wave: 진폭·면적 < LCL, 잠복기 > UCL
    final ampLcl = status.mwAmpCcLcl;
    final areaLcl = status.mwAreaCcLcl;
    final latUcl = status.mwLatCcUcl;
    final ampBelow = ampLcl != null && status.mwAmp > 0 && status.mwAmp < ampLcl;
    final areaBelow =
        areaLcl != null && status.mwArea > 0 && status.mwArea < areaLcl;
    final mwAmpMet = ampBelow && areaBelow;
    final mwLatMet =
        latUcl != null && status.mwLatency > 0 && status.mwLatency > latUcl;

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 320),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ---- RMS vs UCL ----
          _conditionRow(
            label: 'RMS > UCL',
            valueLine: ucl == null
                ? '관리도 학습 전'
                : '현재 ${status.lastRms.toStringAsFixed(1)}'
                    '  ·  UCL ${ucl.toStringAsFixed(1)}',
            met: rmsMet,
          ),
          const SizedBox(height: 6),
          // ---- MDF vs LCL ----
          _conditionRow(
            label: 'MDF < LCL',
            valueLine: lcl == null
                ? '관리도 학습 전'
                : '현재 ${status.lastMdf.toStringAsFixed(1)}'
                    '  ·  LCL ${lcl.toStringAsFixed(1)}',
            met: mdfMet,
          ),
          // ---- M-wave 관리도 (수집된 경우만) ----
          if (ampLcl != null || areaLcl != null || latUcl != null) ...[
            const SizedBox(height: 6),
            _conditionRow(
              label: 'M-wave 진폭·면적 < LCL',
              valueLine: (ampLcl == null || areaLcl == null)
                  ? '관리도 학습 전'
                  : '진폭 ${status.mwAmp.toStringAsFixed(0)} '
                      '(LCL ${ampLcl.toStringAsFixed(0)})  ·  '
                      '면적 ${status.mwArea.toStringAsFixed(0)} '
                      '(LCL ${areaLcl.toStringAsFixed(0)})',
              met: mwAmpMet,
            ),
            const SizedBox(height: 6),
            _conditionRow(
              label: 'M-wave 잠복기 > UCL',
              valueLine: latUcl == null
                  ? '관리도 학습 전'
                  : '현재 ${status.mwLatency.toStringAsFixed(2)}ms  '
                      '·  UCL ${latUcl.toStringAsFixed(2)}ms',
              met: mwLatMet,
            ),
          ],
          if (reasons.isNotEmpty) ...[
            const SizedBox(height: 10),
            const Divider(height: 1, color: Colors.black26),
            const SizedBox(height: 8),
            const Text('판정 근거',
                style: TextStyle(color: Colors.black54, fontSize: 11)),
            const SizedBox(height: 3),
            Text(
              reasons.join('  ·  '),
              style: const TextStyle(
                color: Colors.redAccent,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
          const SizedBox(height: 10),
          Text(
            fesWasOn ? '자극이 자동으로 정지되었습니다.' : 'FES 미가동 상태에서 검출.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.black45, fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _conditionRow({
    required String label,
    required String valueLine,
    required bool met,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          met ? Icons.check_circle : Icons.radio_button_unchecked,
          size: 16,
          color: met ? Colors.redAccent : Colors.black38,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: TextStyle(
                    color: met ? Colors.red.shade700 : Colors.black54,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  )),
              Text(valueLine,
                  style: const TextStyle(color: Colors.black45, fontSize: 11)),
            ],
          ),
        ),
      ],
    );
  }
}
