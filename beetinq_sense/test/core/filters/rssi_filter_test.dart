import 'package:flutter_test/flutter_test.dart';
import 'package:beetinq_sense/core/filters/rssi_filter.dart';

void main() {
  RssiFilter newFilter() => RssiFilter(
        medianWindow: 3,
        kalmanQ: 0.5,
        kalmanErrorMeasure: 20,
        kalmanErrorEstimate: 30,
      );

  group('RssiFilter', () {
    test('İlk değer — medyan ve kalman set edildi', () {
      final f = newFilter();
      f.apply(-65);
      expect(f.lastMedian, -65);
      expect(f.lastKalman, isNotNull);
    });

    test('Outlier gürültüyü medyan + kalman birlikte temizler', () {
      final f = newFilter();
      // Stabil veri yığınla, sonra outlier ver
      double last = 0;
      for (int i = 0; i < 5; i++) {
        last = f.apply(-65 + (i.isEven ? 1 : -1).toDouble());
      }
      // Outlier
      final outlierFiltered = f.apply(-20);
      // Median 3'lük pencerede outlier ortada kalır
      // Kalman ek olarak yumuşatır → -20'ye fırlamamalı, son stabil değere yakın
      expect((outlierFiltered - last).abs(), lessThan(15),
          reason: 'last=$last outlierFiltered=$outlierFiltered');
    });

    test('Sürekli aynı değer → kalman bu değere yakınsar', () {
      final f = newFilter();
      double v = 0;
      for (int i = 0; i < 30; i++) {
        v = f.apply(-65);
      }
      expect(v, closeTo(-65, 1.0));
    });

    test('reset sonrası kalman fresh — eski state hatırlanmaz', () {
      final f = newFilter();
      // Önce -90'a yakınsa
      for (int i = 0; i < 30; i++) {
        f.apply(-90);
      }
      f.reset();
      // SimpleKalman reset edildiğinde initial estimate = 0 olur.
      // İlk apply(-50) çıktısı: 0 + K*(−50−0) ≈ −30 (K=0.6 ilk adımda).
      // Eski state (-90) korunsaydı çıktı -90'a yakın olurdu.
      // Yani reset gerçekten state'i sıfırladı.
      final v1 = f.apply(-50);
      expect(v1, greaterThan(-50)); // -90'a yakın değil
      // Birkaç iterasyon sonra -50'ye yakınsar
      double v = v1;
      for (int i = 0; i < 30; i++) {
        v = f.apply(-50);
      }
      expect(v, closeTo(-50, 1.0));
    });

    test('Median 3 — tek outlier hiç kalman\'a düşmez', () {
      final f = newFilter();
      f.apply(-65);
      f.apply(-66);
      // 3. değer outlier (-20) ama median ile -65 olur, kalman'a -65 gider
      f.apply(-20);
      expect(f.lastMedian, -65);
    });
  });
}
