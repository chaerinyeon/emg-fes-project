/// 환자가 읽는 언어. **한곳에서만 만든다.**
///
/// 같은 세션을 홈·결과·기록이 각자 다르게 부르면 "오늘 몫을 다 했다"는
/// 화면과 "중단됨"이라는 화면이 한 앱 안에 공존하게 된다. 종료 코드를
/// 그대로 보여주지 않는 것도, 어떤 경우에도 환자 탓으로 들리지 않게 하는
/// 것도 이 파일의 책임이다.
library;

import '../session/end_conditions.dart';

/// 종료 사유 → 마무리 문구. 결과 화면·홈의 최근 카드가 함께 쓴다.
String closingLineFor(SessionEndReason r) => switch (r) {
      SessionEndReason.fatigueThreshold => '오늘 몫을 다 했어요',
      SessionEndReason.successRateDrop => '오늘은 여기까지가 좋겠어요',
      SessionEndReason.gameComplete => '오늘 목표를 채웠어요',
      SessionEndReason.timeout => '오늘 목표를 채웠어요',
      SessionEndReason.userStop => '잘 마쳤어요',
      SessionEndReason.remoteStop => '치료사가 오늘 훈련을 마무리했어요',
      SessionEndReason.deviceDisconnect => '기기 연결이 끊겨 멈췄어요',
      SessionEndReason.signalLost => '센서 신호가 약해져 멈췄어요',
      SessionEndReason.error => '여기서 멈췄어요',
    };

/// 치료사·보호자가 읽는 종료 사유. 기록 탭에서만 쓴다.
///
/// **중단 사유를 뭉뚱그리지 않는다** — "진짜 피로로 멈춘 것"과 "장비 문제로
/// 멈춘 것"을 구분하지 못하면 그 위의 모든 해석이 오염된다.
String endReasonLabel(SessionEndReason r) => switch (r) {
      SessionEndReason.fatigueThreshold => '피로 임계',
      SessionEndReason.successRateDrop => '성공률 하락',
      SessionEndReason.gameComplete => '목표 달성',
      SessionEndReason.timeout => '시간 상한',
      SessionEndReason.userStop => '사용자 중단',
      SessionEndReason.remoteStop => '원격 중단',
      SessionEndReason.signalLost => '신호 유실',
      SessionEndReason.deviceDisconnect => '기기 끊김',
      SessionEndReason.error => '오류',
    };

/// 초 → "9분 18초". 0분이면 초만.
String formatDurationKo(int seconds) {
  final m = seconds ~/ 60;
  final s = seconds % 60;
  return m == 0 ? '$s초' : '$m분 $s초';
}

/// 피로 발생 시점 한 문장. 없으면 끝까지 힘이 남았다고 말한다.
String fatigueOnsetLine(double? onsetS) => onsetS == null
    ? '오늘은 끝까지 힘이 남았어요'
    : '${formatDurationKo(onsetS.round())}쯤부터 힘이 줄기 시작했어요';

/// 수행 성공률 — **퍼센트 대신 비율 문장**.
///
/// "80%" 는 20%를 못 했다는 말로 읽힌다. "10번 중 8번" 은 8번 해냈다는
/// 말로 읽힌다. 같은 값이지만 환자가 받는 뜻이 다르다.
String successRatioLine(double rate) {
  final outOfTen = (rate * 10).round().clamp(0, 10);
  return '10번 중 $outOfTen번';
}
