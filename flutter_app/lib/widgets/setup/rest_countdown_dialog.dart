// 세션 시작 직후 '무부하(힘 빼기)' 구간을 안내하는 카운트다운 팝업.
//
// 왜 필요한가:
//   FES 자극기는 손으로 켜므로 매 세션 자극 시작 시점이 제각각이고, 하드웨어로는
//   그 시점을 알 수 없다. 그래서 세션 초반에 '힘을 주지 않는 구간'을 일부러 만들어
//   그 구간의 순수 자극(자발 EMG 오염 없음)을 데이터에서 검출해 시간축을 정렬한다.
//   덤으로 그 구간은 그 세션의 M-wave 기준선(baseline)으로도 쓸 수 있다.
//
// 끝나면 onFinished 가 호출되고, 호출측이 마커를 찍어 CSV 에 경계를 남긴다.
import 'dart:async';

import 'package:flutter/material.dart';

/// 무부하 카운트다운 팝업을 띄운다. [seconds] 초 후 자동으로 닫히며 [onFinished] 호출.
/// 사용자가 임의로 닫지 못하게 barrierDismissible=false + WillPopScope 로 막는다.
Future<void> showRestCountdownDialog(
  BuildContext context, {
  int seconds = 15,
  VoidCallback? onFinished,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => RestCountdownDialog(
      seconds: seconds,
      onFinished: onFinished,
    ),
  );
}

class RestCountdownDialog extends StatefulWidget {
  final int seconds;
  final VoidCallback? onFinished;

  const RestCountdownDialog({
    super.key,
    this.seconds = 15,
    this.onFinished,
  });

  @override
  State<RestCountdownDialog> createState() => _RestCountdownDialogState();
}

class _RestCountdownDialogState extends State<RestCountdownDialog> {
  late int _left = widget.seconds;
  Timer? _timer;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      setState(() => _left--);
      if (_left <= 0) {
        t.cancel();
        setState(() => _done = true);
        widget.onFinished?.call(); // 마커 기록 — 무부하 구간의 끝을 CSV 에 남김
        // '힘 주세요' 를 잠깐 보여준 뒤 자동으로 닫는다.
        Timer(const Duration(milliseconds: 1200), () {
          if (mounted) Navigator.of(context).maybePop();
        });
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final progress =
        widget.seconds == 0 ? 1.0 : (widget.seconds - _left) / widget.seconds;
    return PopScope(
      canPop: false, // 뒤로가기로 닫으면 무부하 구간이 깨지므로 막는다
      child: AlertDialog(
        title: Row(
          children: [
            Icon(_done ? Icons.fitness_center : Icons.pan_tool_outlined,
                color: _done ? Colors.green : Colors.orange),
            const SizedBox(width: 8),
            Text(_done ? '이제 힘을 주세요' : '힘을 빼고 계세요'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!_done) ...[
              SizedBox(
                width: 120,
                height: 120,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    SizedBox(
                      width: 120,
                      height: 120,
                      child: CircularProgressIndicator(
                        value: progress,
                        strokeWidth: 8,
                        backgroundColor: Colors.orange.withValues(alpha: 0.15),
                        valueColor:
                            const AlwaysStoppedAnimation<Color>(Colors.orange),
                      ),
                    ),
                    Text(
                      '$_left',
                      style: const TextStyle(
                        fontSize: 44,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                '측정 시작됐습니다.\n손에 힘을 주지 말고 그대로 계세요.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              const Text(
                '이 구간의 순수 전기자극 반응으로\n세션 시간축을 정렬합니다.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ] else ...[
              const Icon(Icons.check_circle, color: Colors.green, size: 72),
              const SizedBox(height: 12),
              const Text(
                '무부하 구간 완료.\n지금부터 일정한 힘을 주세요.',
                textAlign: TextAlign.center,
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
