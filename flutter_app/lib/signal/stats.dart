/// 정렬 사본의 중앙값. 빈 리스트는 0.
///
/// 이 파이프라인은 평균 대신 중앙값을 쓴다 — 자극 아티팩트가 이상치로
/// 섞여 들어와도 추정치가 끌려가지 않아야 하기 때문이다.
double median(List<double> xs) {
  final s = List<double>.of(xs)..sort();
  final n = s.length;
  if (n == 0) return 0.0;
  return n.isOdd ? s[n ~/ 2] : (s[n ~/ 2 - 1] + s[n ~/ 2]) / 2.0;
}
