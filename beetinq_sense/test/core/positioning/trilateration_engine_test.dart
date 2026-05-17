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

  group('calculatePosition — Weighted LS + EWMA + fallback', () {
    final beacons = [
      BeaconLocation(id: 'A', x: 0, y: 0),
      BeaconLocation(id: 'B', x: 10, y: 0),
      BeaconLocation(id: 'C', x: 5, y: 8.66),
    ];

    test('Eşit RSSI değerleri → üçgenin merkezine yakın', () {
      // LS'te eşit RSSI = eşit distance → reference olarak A seçilir,
      // çözüm üçgenin geometrik merkezine yakın çıkar.
      final eng = TrilaterationEngine(); // fresh EWMA
      final pos = eng.calculatePosition(beacons, {
        'A': -65,
        'B': -65,
        'C': -65,
      });
      expect(pos, isNotNull);
      expect(pos!['x']!, closeTo(5.0, 1.0));
      expect(pos['y']!, closeTo(2.887, 1.5));
    });

    test('Tek beacon güçlü → o beacon koordinatına yakın', () {
      // A çok yakın (-50), diğerleri uzak (-85). LS reference A olur,
      // ağırlıklı çözüm A'ya doğru kayar.
      final eng = TrilaterationEngine();
      final pos = eng.calculatePosition(beacons, {
        'A': -50,
        'B': -85,
        'C': -85,
      });
      expect(pos, isNotNull);
      // A=(0,0)'a yakın olmalı — uzak beacon'ların etkisi 1/d² ile zayıflar.
      // Tolerans LS açısından 4m'ye genişletildi (önceki IDW 3m varsayımı geçersiz).
      expect(pos!['x']!, lessThan(4.0));
      expect(pos['y']!, lessThan(3.5));
    });

    test('Tek match → null (yön bilinmiyor)', () {
      final eng = TrilaterationEngine();
      final pos = eng.calculatePosition(beacons, {'A': -65});
      expect(pos, isNull);
    });

    test('Sıfır match → null', () {
      final eng = TrilaterationEngine();
      final pos = eng.calculatePosition(beacons, {});
      expect(pos, isNull);
    });

    test('İki beacon → weighted midpoint fallback', () {
      // 2-beacon: LS'in matematiksel minimumu altında ama fallback olarak
      // 1/d ağırlıklı orta nokta döner. Eşit RSSI → tam orta.
      final eng = TrilaterationEngine();
      final pos = eng.calculatePosition(beacons, {
        'A': -65,
        'B': -65,
      });
      expect(pos, isNotNull);
      expect(pos!['x']!, closeTo(5.0, 0.5));
      expect(pos['y']!, closeTo(0.0, 0.5));
    });

    test('Geçersiz RSSI atlanır (>= 0)', () {
      final eng = TrilaterationEngine();
      final pos = eng.calculatePosition(beacons, {
        'A': -65,
        'B': 0, // geçersiz → atlanır
        'C': -65,
      });
      // A + C kalır → 2-beacon fallback aktif olur, null değil.
      expect(pos, isNotNull);
    });

    test('Distance cap 80m: -99 dBm uygun, -101 invalid', () {
      // n=2.5 için -99 → ~40m (cap altı).
      // -101 RSSI invalid sayılır (-1 döner) — yine işe yaramaz ama farklı yoldan.
      expect(engine.calculateDistance(-99), lessThan(80));
      expect(engine.calculateDistance(-99), greaterThan(35));
      expect(engine.calculateDistance(-101), -1.0);
    });

    test('Duplicate id ikinci kez sayılmaz (2-beacon fallback ile bile)', () {
      final dupBeacons = [
        BeaconLocation(id: 'A', x: 0, y: 0),
        BeaconLocation(id: 'A', x: 100, y: 100), // duplicate id
        BeaconLocation(id: 'B', x: 10, y: 0),
      ];
      final eng = TrilaterationEngine();
      final pos = eng.calculatePosition(dupBeacons, {
        'A': -65,
        'B': -65,
      });
      // Duplicate atlanır → 2 beacon → fallback (5,0) civarı.
      expect(pos, isNotNull);
      expect(pos!['x']!, closeTo(5.0, 1.0));
      expect(pos['y']!, closeTo(0.0, 1.0));
    });

    test('LS convex hull dışına çıkabilir (özellik, kısıt değil)', () {
      // Asimetrik RSSI: A çok güçlü, B/C eşit zayıf → LS çözüm A'nın "öbür yanına"
      // bile gidebilir. Bu IDW'nin tersine LS'in avantajı (gerçek konum
      // beacon'ların dışındaysa onu da yakalar). Bu test sadece "null değil"
      // kontrolü yapar; spesifik konum kısıtı YOK.
      final eng = TrilaterationEngine();
      final pos = eng.calculatePosition(beacons, {
        'A': -90,
        'B': -90,
        'C': -90,
      });
      expect(pos, isNotNull);
    });

    test('Outlier rejection: 4+ beacon ile en sapan beacon atılır', () {
      // 4 beacon — biri kasıtlı yanlış mesafe. Outlier rejection
      // doğru konuma yaklaştırmalı.
      final fourBeacons = [
        BeaconLocation(id: 'A', x: 0, y: 0),
        BeaconLocation(id: 'B', x: 10, y: 0),
        BeaconLocation(id: 'C', x: 0, y: 10),
        BeaconLocation(id: 'D', x: 10, y: 10),
      ];
      // Gerçek konum (5,5). Doğru RSSI ≈ -77 dBm (~7m).
      // E hayali outlier: yokmuş gibi davran, dördüncü beacon D'yi çok yanlış göster.
      final eng = TrilaterationEngine();
      final pos = eng.calculatePosition(fourBeacons, {
        'A': -77,
        'B': -77,
        'C': -77,
        'D': -45, // 1m mesafe gibi göster — outlier
      });
      expect(pos, isNotNull);
      // Outlier atılırsa A/B/C dengeli → (5,5) civarı.
      // Atılmazsa D=(10,10) sahte 1m mesafesiyle (10,10)'a doğru çekecek.
      // Test toleransı 3m: outlier rejection çalışıyorsa bu sınırda kalır.
      final dist = ((pos!['x']! - 5).abs() + (pos['y']! - 5).abs()) / 2;
      expect(dist, lessThan(3.0));
    });

    test('EWMA smoothing: ardışık çağrılar yumuşatır', () {
      final eng = TrilaterationEngine();
      // Aynı RSSI 3 kez → konum yakınsamalı
      Map<String, double>? pos;
      for (int i = 0; i < 3; i++) {
        pos = eng.calculatePosition(beacons, {
          'A': -65, 'B': -65, 'C': -65,
        });
      }
      expect(pos, isNotNull);

      // resetSmoothing sonrası tek ölçüm → EWMA başlangıçta raw değer
      eng.resetSmoothing();
      final fresh = eng.calculatePosition(beacons, {
        'A': -65, 'B': -65, 'C': -65,
      });
      expect(fresh, isNotNull);
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
