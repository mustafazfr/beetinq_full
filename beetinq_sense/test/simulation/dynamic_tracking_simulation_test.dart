// Sandbox simülasyonu 2: HAREKETLİ kullanıcı takibi + NLOS (gölgeleme) dayanıklılığı.
// positioning_simulation_test.dart yalnız STATİK grid ölçer; bu dosya iki ek
// gerçek-dünya koşulunu ölçer:
//
//   1) DİNAMİK TAKİP: 1.2 m/s yürüyen kullanıcı (fuar yürüyüş hızı), motor
//      sıralı beslenir → adaptive EWMA gecikmesi DAHİL uçtan uca takip hatası.
//   2) NLOS GÖLGELEME: 5 beacon'dan 1-2'sinin önüne insan/duvar girer (-12 dB);
//      tek-pass outlier rejection'ın bozulmaya karşı dayanımı.
//
// TASARIM NOTU (2026-06-10 probe bulgusu): iteratif (2-pass) outlier rejection
// denendi ve REDDEDİLDİ — 5 beacon'dan 2'sini atmak geometriyi çökertiyor
// (3 beacon, sıfır yedeklilik): 2-bozuk senaryoda mean 1.89→2.55m KÖTÜLEŞTİ.
// Mevcut tek-pass tasarım bilinçli olarak korunuyor. Aynı probe'da adaptive
// EWMA parametre taraması da yapıldı: gürültülü ortamda (sigma=6) mevcut
// [0.15-0.60] aralığı denenen tüm varyantlardan iyi çıktı → dokunulmadı.
//
// Çalıştırma: flutter test test/simulation/dynamic_tracking_simulation_test.dart -r expanded
//
// Pass-fail mantığı: eşikler muhafazakar (regression koruması); asıl amaç
// print edilen istatistiklerin tezde/savunmada kullanılması.

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:beetinq_sense/core/positioning/trilateration_engine.dart';

// Log-distance modeli ile mesafe → RSSI üretir (statik sim ile birebir model).
// rssi = txPowerAt1m - 10 * n * log10(d) + N(0, sigma) + bias
double _rssiFromDistance(double d, Random rng,
    {double sigma = 3.0, double bias = 0.0}) {
  const tx = -59.0;
  const n = 2.5;
  final ideal = tx - 10 * n * (log(d.clamp(0.1, 1e9)) / ln10);
  final v = ideal + _gaussian(rng, 0, sigma) + bias;
  return v.clamp(-100.0, -1.0);
}

double _gaussian(Random rng, double mean, double std) {
  // Box-Muller
  final u1 = rng.nextDouble().clamp(1e-9, 1);
  final u2 = rng.nextDouble();
  return mean + std * sqrt(-2 * log(u1)) * cos(2 * pi * u2);
}

double _dist(double x1, double y1, double x2, double y2) =>
    sqrt(pow(x1 - x2, 2) + pow(y1 - y2, 2));

final _beacons = [
  BeaconLocation(id: 'B1', x: 0, y: 0),
  BeaconLocation(id: 'B2', x: 5, y: 0),
  BeaconLocation(id: 'B3', x: 0, y: 5),
  BeaconLocation(id: 'B4', x: 5, y: 5),
  BeaconLocation(id: 'B5', x: 2.5, y: 2.5),
];

class _Stats {
  final List<double> errors;
  _Stats(this.errors);

  double get mean =>
      errors.isEmpty ? 0 : errors.reduce((a, b) => a + b) / errors.length;

  double get median {
    if (errors.isEmpty) return 0;
    final s = List<double>.from(errors)..sort();
    return s[s.length ~/ 2];
  }

  double get p95 {
    if (errors.isEmpty) return 0;
    final s = List<double>.from(errors)..sort();
    return s[(s.length * 0.95).floor().clamp(0, s.length - 1)];
  }

  @override
  String toString() =>
      '   n=${errors.length} | mean=${mean.toStringAsFixed(2)}m | '
      'median=${median.toStringAsFixed(2)}m | p95=${p95.toStringAsFixed(2)}m';
}

/// Dikdörtgen tur: (1,1)→(4,1)→(4,4)→(1,4)→(1,1), çevre 12m.
/// t (sn) ve hız (m/s) için ground-truth konum.
(double, double) _walkPos(double t, double speed) {
  final dTotal = (t * speed) % 12.0;
  if (dTotal < 3) return (1 + dTotal, 1);
  if (dTotal < 6) return (4, 1 + (dTotal - 3));
  if (dTotal < 9) return (4 - (dTotal - 6), 4);
  return (1, 4 - (dTotal - 9));
}

void main() {
  group('SIMULATION — dinamik takip (yürüyen kullanıcı)', () {
    // Motor SIRALI beslenir (resetSmoothing YOK) → EWMA'nın gerçek davranışı
    // ve gecikmesi ölçüme dahil. 10 seed × 60 sn @1 Hz = 600 örnek.
    _Stats run(double sigma) {
      final errors = <double>[];
      for (int seed = 0; seed < 10; seed++) {
        final rng = Random(1000 + seed);
        final engine = TrilaterationEngine(); // seed başına taze EWMA
        for (int t = 0; t < 60; t++) {
          final (gx, gy) = _walkPos(t.toDouble(), 1.2); // fuar yürüyüş hızı
          final rssiMap = <String, double>{
            for (final b in _beacons)
              b.id:
                  _rssiFromDistance(_dist(gx, gy, b.x, b.y), rng, sigma: sigma),
          };
          final p = engine.calculatePosition(_beacons, rssiMap);
          if (p == null) continue;
          errors.add(_dist(p['x']!, p['y']!, gx, gy));
        }
      }
      return _Stats(errors);
    }

    test('yürüyüş 1.2 m/s — sigma=3 (tipik)', () {
      final s = run(3.0);
      // ignore: avoid_print
      print('\n[Dinamik takip — 1.2 m/s, sigma=3]\n$s');
      expect(s.errors.length, greaterThan(500)); // coverage
      expect(s.median, lessThan(1.6)); // ölçülen ~0.8m — bol pay
      expect(s.p95, lessThan(3.0)); // ölçülen ~1.5m
    });

    test('yürüyüş 1.2 m/s — sigma=6 (gürültülü)', () {
      final s = run(6.0);
      // ignore: avoid_print
      print('\n[Dinamik takip — 1.2 m/s, sigma=6]\n$s');
      expect(s.errors.length, greaterThan(500));
      expect(s.median, lessThan(2.2)); // ölçülen ~1.1m
      expect(s.p95, lessThan(4.0)); // ölçülen ~2.5m
    });
  });

  group('SIMULATION — NLOS gölgeleme dayanıklılığı', () {
    // 9×9 grid × 5 tekrar; her örnekte [corruptCount] rastgele beacon'a
    // -12 dB gölgeleme (insan vücudu / geçici engel) uygulanır.
    _Stats run(int corruptCount) {
      final rng = Random(42);
      final errors = <double>[];
      for (double gx = 0.5; gx <= 4.5; gx += 0.5) {
        for (double gy = 0.5; gy <= 4.5; gy += 0.5) {
          for (int rep = 0; rep < 5; rep++) {
            final corrupted = <String>{};
            while (corrupted.length < corruptCount) {
              corrupted.add(_beacons[rng.nextInt(_beacons.length)].id);
            }
            final rssiMap = <String, double>{
              for (final b in _beacons)
                b.id: _rssiFromDistance(
                  _dist(gx, gy, b.x, b.y),
                  rng,
                  sigma: 3.0,
                  bias: corrupted.contains(b.id) ? -12.0 : 0.0,
                ),
            };
            final engine = TrilaterationEngine(); // statik ölçüm — EWMA taze
            final p = engine.calculatePosition(_beacons, rssiMap);
            if (p == null) continue;
            errors.add(_dist(p['x']!, p['y']!, gx, gy));
          }
        }
      }
      return _Stats(errors);
    }

    test('1 beacon gölgelenmiş — zarif bozulma', () {
      final s = run(1);
      // ignore: avoid_print
      print('\n[NLOS — 1/5 beacon gölgeli (-12dB)]\n$s');
      expect(s.median, lessThan(2.0)); // ölçülen ~0.9m
      expect(s.p95, lessThan(4.5)); // ölçülen ~2.9m
    });

    test('2 beacon gölgelenmiş — hedef bandın hâlâ içinde', () {
      final s = run(2);
      // ignore: avoid_print
      print('\n[NLOS — 2/5 beacon gölgeli (-12dB)]\n$s');
      // En kötü gerçekçi senaryo bile tez hedefinin (3-5m) altında kalmalı.
      expect(s.median, lessThan(3.2)); // ölçülen ~1.7m
      expect(s.p95, lessThan(6.0)); // ölçülen ~4.1m
    });
  });
}
