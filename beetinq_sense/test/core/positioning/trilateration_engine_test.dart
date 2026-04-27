import 'package:flutter_test/flutter_test.dart';
import 'package:beetinq_sense/core/positioning/trilateration_engine.dart';

void main() {
  final engine = TrilaterationEngine();

  group('calculateDistance — RSSI → metre dönüşümü', () {
    test('RSSI = -59 dBm (tx@1m) → 1 metre', () {
      final d = engine.calculateDistance(-59);
      expect(d, closeTo(1.0, 0.01));
    });

    test('-59 dBm üstü güçlü sinyal → 1m altı', () {
      // -50 dBm > -59 dBm → daha yakın → < 1m
      expect(engine.calculateDistance(-50), lessThan(1.0));
      // -69 dBm < -59 dBm → daha uzak → > 1m
      expect(engine.calculateDistance(-69), greaterThan(1.0));
    });

    test('Path-loss exponent 2.5 ile -69 dBm ≈ 2.51m', () {
      // 10^((-59 - (-69)) / (10*2.5)) = 10^(10/25) = 10^0.4 ≈ 2.5119
      expect(engine.calculateDistance(-69), closeTo(2.512, 0.01));
    });

    test('RSSI ≥ 0 geçersiz → -1', () {
      expect(engine.calculateDistance(0), -1.0);
      expect(engine.calculateDistance(5), -1.0);
    });

    test('RSSI < -100 geçersiz → -1', () {
      expect(engine.calculateDistance(-101), -1.0);
      expect(engine.calculateDistance(-150), -1.0);
    });

    test('Monotonik: zayıf sinyal daima daha uzak', () {
      double prev = engine.calculateDistance(-40);
      for (int rssi = -41; rssi >= -99; rssi--) {
        final d = engine.calculateDistance(rssi.toDouble());
        expect(d, greaterThan(prev),
            reason: 'rssi=$rssi prev=$prev current=$d');
        prev = d;
      }
    });
  });

  group('calculatePosition — IDW centroid', () {
    final beacons = [
      BeaconLocation(id: 'A', x: 0, y: 0),
      BeaconLocation(id: 'B', x: 10, y: 0),
      BeaconLocation(id: 'C', x: 5, y: 8.66),
    ];

    test('Eşit RSSI değerleri → geometrik merkeze yaklaşır', () {
      // Üçgenin merkezi: (0+10+5)/3 = 5, (0+0+8.66)/3 = 2.887
      final pos = engine.calculatePosition(beacons, {
        'A': -65,
        'B': -65,
        'C': -65,
      });
      expect(pos, isNotNull);
      expect(pos!['x']!, closeTo(5.0, 0.1));
      expect(pos['y']!, closeTo(2.887, 0.1));
    });

    test('Tek beacon güçlü → o beacon koordinatına yakın', () {
      // A çok yakın (-50), diğerleri uzak (-85)
      final pos = engine.calculatePosition(beacons, {
        'A': -50,
        'B': -85,
        'C': -85,
      });
      expect(pos, isNotNull);
      // A=(0,0)'a doğru çekilmeli — merkez 5,2.9 değil
      expect(pos!['x']!, lessThan(3.0));
      expect(pos['y']!, lessThan(2.0));
    });

    test('Tek match → null (matchCount < 2)', () {
      final pos = engine.calculatePosition(beacons, {'A': -65});
      expect(pos, isNull);
    });

    test('Sıfır match → null', () {
      final pos = engine.calculatePosition(beacons, {});
      expect(pos, isNull);
    });

    test('İki beacon → IDW yine sonuç verir (klasik trilat min 3 ister)', () {
      final pos = engine.calculatePosition(beacons, {
        'A': -65,
        'B': -65,
      });
      expect(pos, isNotNull);
      // İki beacon arası orta nokta (5, 0)
      expect(pos!['x']!, closeTo(5.0, 0.5));
      expect(pos['y']!, closeTo(0.0, 0.5));
    });

    test('Geçersiz RSSI atlanır (>= 0)', () {
      final pos = engine.calculatePosition(beacons, {
        'A': -65,
        'B': 0, // geçersiz, atlanır
        'C': -65,
      });
      // A + C kalır: matchCount = 2, yine null değil
      expect(pos, isNotNull);
    });

    test('50m clamp pratikte ölü kod (raporda not düşülmeli)', () {
      // BULGU: distance > 50m kontrolü kod var ama tetiklenemez.
      // Path-loss model: 10^((-59 - rssi) / 25) > 50 için rssi < -101.5 lazım.
      // Ama RSSI < -100 zaten validation'da -1 dönüyor (geçersiz sayılıp atlanıyor).
      // Yani 50m clamp kod yolu pratikte AKTİF değil; eylem aynı hassasiyette
      // calculateDistance(-101) = -1 ile yapılıyor.
      expect(engine.calculateDistance(-99), lessThan(50));
      expect(engine.calculateDistance(-101), -1.0);
    });

    test('Duplicate id ikinci kez sayılmaz', () {
      final dupBeacons = [
        BeaconLocation(id: 'A', x: 0, y: 0),
        BeaconLocation(id: 'A', x: 100, y: 100), // duplicate id
        BeaconLocation(id: 'B', x: 10, y: 0),
      ];
      final pos = engine.calculatePosition(dupBeacons, {
        'A': -65,
        'B': -65,
      });
      // Duplicate atlanırsa ilk A=(0,0) sayılır, ortalama (5,0) civarı
      expect(pos, isNotNull);
      expect(pos!['x']!, closeTo(5.0, 1.0));
      expect(pos['y']!, closeTo(0.0, 1.0));
    });

    test('Convex hull dışına çıkamaz (IDW kısıtı)', () {
      // Tüm beacon'lar (0..10) x ve (0..10) y içinde
      final pos = engine.calculatePosition(beacons, {
        'A': -90,
        'B': -90,
        'C': -90,
      });
      expect(pos, isNotNull);
      expect(pos!['x']!, inInclusiveRange(0, 10));
      expect(pos['y']!, inInclusiveRange(0, 10));
    });
  });

  group('BeaconLocation', () {
    test('fromBeaconKey — UUID upper-case + key formatı', () {
      final b = BeaconLocation.fromBeaconKey(
        uuid: 'e2c56db5-dffb-48d2-b060-d0f5a71096e0',
        major: 100,
        minor: 7,
        x: 1,
        y: 2,
      );
      expect(b.id, 'E2C56DB5-DFFB-48D2-B060-D0F5A71096E0-100-7');
    });

    test('isValidId — geçerli/geçersiz', () {
      expect(
        BeaconLocation.isValidId('E2C56DB5-DFFB-48D2-B060-D0F5A71096E0-100-7'),
        isTrue,
      );
      expect(BeaconLocation.isValidId('foo'), isFalse);
      expect(
        BeaconLocation.isValidId('E2C56DB5-DFFB-48D2-B060-D0F5A71096E0'),
        isFalse,
      );
    });

    test('locationLabel — name yoksa major-minor', () {
      final b = BeaconLocation(
        id: 'E2C56DB5-DFFB-48D2-B060-D0F5A71096E0-100-7',
        x: 0,
        y: 0,
      );
      expect(b.locationLabel, '100-7');
    });

    test('locationLabel — name varsa o', () {
      final b = BeaconLocation(
        id: 'E2C56DB5-DFFB-48D2-B060-D0F5A71096E0-100-7',
        x: 0,
        y: 0,
        name: 'Sony Standı',
      );
      expect(b.locationLabel, 'Sony Standı');
    });
  });
}
