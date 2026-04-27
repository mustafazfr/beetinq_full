import 'package:flutter_test/flutter_test.dart';
import 'package:beetinq_sense/core/filters/rolling_median.dart';

void main() {
  group('RollingMedian', () {
    test('Tek değer → kendisi medyan', () {
      final m = RollingMedian(window: 3);
      expect(m.add(-65), -65);
    });

    test('Window dolmadan medyan: [-65, -70] → -65', () {
      // Buf: [-65, -70], sorted: [-70, -65], mid=1 → -65
      final m = RollingMedian(window: 3);
      m.add(-65);
      expect(m.add(-70), -65);
    });

    test('3 değer dolu — outlier gürültü temizlenir', () {
      final m = RollingMedian(window: 3);
      m.add(-65);
      m.add(-66);
      // -20 outlier; sorted: [-66, -65, -20], mid=-65
      expect(m.add(-20), -65);
    });

    test('Window aşımı — eski değer atılır', () {
      final m = RollingMedian(window: 3);
      m.add(-90);
      m.add(-65);
      m.add(-66);
      // 4. ekleme -90 değerini atar
      // Buf: [-65, -66, -67], sorted: [-67, -66, -65], mid=-66
      expect(m.add(-67), -66);
    });

    test('Window büyüklüğü çift olamaz (assert)', () {
      expect(
        () => RollingMedian(window: 4),
        throwsA(isA<AssertionError>()),
      );
    });

    test('Window 1 olamaz (assert ≥3)', () {
      expect(
        () => RollingMedian(window: 1),
        throwsA(isA<AssertionError>()),
      );
    });

    test('clear sonrası tek değer kendisi medyan', () {
      final m = RollingMedian(window: 3);
      m.add(-50);
      m.add(-60);
      m.clear();
      expect(m.add(-70), -70);
    });
  });
}
