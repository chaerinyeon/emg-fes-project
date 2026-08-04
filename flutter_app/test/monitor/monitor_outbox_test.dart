import 'package:flutter_app/monitor/monitor_broadcaster.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Outbox', () {
    test('넣은 순서대로 나온다', () {
      final box = Outbox(4);
      box.add('a');
      box.add('b');
      expect(box.next(), 'a');
      expect(box.next(), 'b');
      expect(box.next(), isNull);
    });

    test('용량을 넘으면 오래된 것부터 버린다', () {
      final box = Outbox(2);
      box.add('a');
      box.add('b');
      box.add('c');
      expect(box.length, 2);
      expect(box.next(), 'b');
      expect(box.next(), 'c');
    });

    test('버린 개수를 센다', () {
      final box = Outbox(1);
      box.add('a');
      box.add('b');
      box.add('c');
      expect(box.dropped, 2);
    });
  });
}
