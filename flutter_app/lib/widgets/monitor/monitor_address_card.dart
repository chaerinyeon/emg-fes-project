import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../monitor/monitor_broadcaster.dart';

/// 치료사가 노트북에 입력할 주소를 폰에 띄운다.
///
/// 모니터가 못 떴을 때도 화면은 뜬다 — 모니터 실패가 세션을 막지 않기 때문이다.
class MonitorAddressCard extends StatelessWidget {
  const MonitorAddressCard({super.key, required this.endpoint});

  final MonitorEndpoint? endpoint;

  @override
  Widget build(BuildContext context) {
    final ep = endpoint;
    final theme = Theme.of(context);

    String message;
    String? copyTarget;
    if (ep == null) {
      message = '모니터 비활성 — 관찰 화면 없이 세션은 그대로 진행됩니다';
    } else if (ep.url == null) {
      message = 'Wi-Fi 에 연결되어 있지 않아 주소를 만들 수 없습니다';
    } else {
      // `ip:port` 만 입력하면 토큰이 없어 서버가 본문 설명도 없는 403만
      // 돌려준다(Important 7) — 실제로 동작하는 건 `?k=` 가 붙은 전체
      // URL이다. 그걸 그대로 주 텍스트로 보여준다: 치료사가 노트북
      // 주소창에 그대로 타이핑하거나, 복사 버튼으로 옮길 대상도 같은 문자열.
      message = ep.url!;
      copyTarget = ep.url;
    }

    return Card(
      margin: const EdgeInsets.all(12),
      child: ListTile(
        leading: const Icon(Icons.monitor_outlined),
        title: const Text('관찰 화면 주소'),
        subtitle: Text(message, style: theme.textTheme.bodyMedium),
        trailing: copyTarget == null
            ? null
            : IconButton(
                icon: const Icon(Icons.copy),
                tooltip: '주소 복사',
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: copyTarget!));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('주소를 복사했습니다')),
                  );
                },
              ),
      ),
    );
  }
}
