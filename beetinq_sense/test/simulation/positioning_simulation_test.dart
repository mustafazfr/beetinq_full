// Sandbox simülasyonu: 5 beacon, sentetik RSSI gürültüsü, ground-truth grid noktaları.
// Mevcut algoritmaların başarı oranını (ortalama hata + std) ölçer.
// Test edilen iyileştirmelerden önce/sonra karşılaştırma yapmak için.
//
// Çalıştırma: flutter test test/simulation/positioning_simulation_test.dart -r expanded
//
// Pass-fail mantığı: hata eşikleri muhafazakar tutulmuş. Çekirdek amaç print
// edilen istatistikleri okuyup tezde grafiğe dökmek; assertion'lar regression
// koruması.

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:beetinq_sense/core/positioning/trilateration_engine.dart';
import 'package:beetinq_sense/core/positioning/fingerprint_engine.dart';

// Log-distance modeli ile mesafe → RSSI üretir.
// rssi = txPowerAt1m - 10 * n * log10(d) + N(0, sigma)
double _rssiFromDistance(double d, Random rng, {double sigma = 3.0}) {
  const tx = -59.0;
  const n = 2.5;
  final ideal = tx - 10 * n * (log(d.clamp(0.1, 1e9)) / ln10);
  final noise = _gaussian(rng, 0, sigma);
  final v = ideal + noise;
  // RSSI clamp: gerçek BLE donanımı -100..-1 aralığında.
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

class _SimResult {
  final List<double> errors;
  final int totalSamples;
  final int returnedSamples;

  _SimResult(this.errors, this.totalSamples, this.returnedSamples);

  double get mean =>
      errors.isEmpty ? 0 : errors.reduce((a, b) => a + b) / errors.length;

  double get median {
    if (errors.isEmpty) return 0;
    final sorted = List<double>.from(errors)..sort();
    return sorted[sorted.length ~/ 2];
  }

  double get p95 {
    if (errors.isEmpty) return 0;
    final sorted = List<double>.from(errors)..sort();
    return sorted[(sorted.length * 0.95).floor().clamp(0, sorted.length - 1)];
  }

  double get std {
    if (errors.length < 2) return 0;
    final m = mean;
    final variance =
        errors.map((e) => pow(e - m, 2) as double).reduce((a, b) => a + b) /
            errors.length;
    return sqrt(variance);
  }

  double get coverage =>
      totalSamples == 0 ? 0 : returnedSamples / totalSamples;

  @override
  String toString() =>
      '   n=$returnedSamples/$totalSamples (coverage=${(coverage * 100).toStringAsFixed(1)}%) | '
      'mean=${mean.toStringAsFixed(2)}m | '
      'median=${median.toStringAsFixed(2)}m | '
      'p95=${p95.toStringAsFixed(2)}m | '
      'std=${std.toStringAsFixed(2)}m';
}

void main() {
  // 5 beacon: 5x5m alanın köşeleri + merkezi yakın
  final beacons = [
    BeaconLocation(id: 'B1', x: 0, y: 0),
    BeaconLocation(id: 'B2', x: 5, y: 0),
    BeaconLocation(id: 'B3', x: 0, y: 5),
    BeaconLocation(id: 'B4', x: 5, y: 5),
    BeaconLocation(id: 'B5', x: 2.5, y: 2.5),
  ];

  // Ground-truth noktaları: 0.5m adımlı grid (11x11 = 121 nokta)
  final gridPoints = <List<double>>[];
  for (double x = 0; x <= 5; x += 0.5) {
    for (double y = 0; y <= 5; y += 0.5) {
      gridPoints.add([x, y]);
    }
  }

  group('SIMULATION — 5 beacon log-distance + Gaussian noise', () {
    test('Trilateration LS — baseline (sigma=3 dBm, 1 sample/point)', () {
      final rng = Random(42);
      final errors = <double>[];
      int returned = 0;
      for (final p in gridPoints) {
        final rssiMap = <String, double>{
          for (final b in beacons)
            b.id: _rssiFromDistance(_dist(p[0], p[1], b.x, b.y), rng),
        };
        // Her noktada engine'i sıfırla — EWMA'nın geçmişi karışmasın
        final eng = TrilaterationEngine();
        final pos = eng.calculatePosition(beacons, rssiMap);
        if (pos == null) continue;
        returned++;
        errors.add(_dist(p[0], p[1], pos['x']!, pos['y']!));
      }
      final r = _SimResult(errors, gridPoints.length, returned);
      // ignore: avoid_print
      print('\n[Trilateration LS — single-sample]\n$r');
      expect(r.coverage, greaterThanOrEqualTo(0.95));
      // Gauss-Newton refinement sonrası kilitlenen değerler (LS-only: 0.77/2.07).
      // Bu eşikler regresyon korumasıdır — GN kaldırılır/bozulursa kırılır.
      expect(r.median, lessThan(0.80));
      expect(r.p95, lessThan(2.05));
    });

    test('Trilateration LS — EWMA aktif (3 sample/point, sigma=3)', () {
      final rng = Random(43);
      final errors = <double>[];
      int returned = 0;
      for (final p in gridPoints) {
        final eng = TrilaterationEngine();
        Map<String, double>? last;
        for (int k = 0; k < 3; k++) {
          final rssiMap = <String, double>{
            for (final b in beacons)
              b.id: _rssiFromDistance(_dist(p[0], p[1], b.x, b.y), rng),
          };
          last = eng.calculatePosition(beacons, rssiMap);
        }
        if (last == null) continue;
        returned++;
        errors.add(_dist(p[0], p[1], last['x']!, last['y']!));
      }
      final r = _SimResult(errors, gridPoints.length, returned);
      // ignore: avoid_print
      print('\n[Trilateration LS — 3 samples + EWMA]\n$r');
      expect(r.coverage, greaterThanOrEqualTo(0.95));
      // GN sonrası kilit (LS-only: 0.64). Saha hedefi "1m altı" burada sağlanır.
      expect(r.median, lessThan(0.65));
    });

    test('Trilateration LS — gürültülü ortam (sigma=6 dBm)', () {
      final rng = Random(44);
      final errors = <double>[];
      int returned = 0;
      for (final p in gridPoints) {
        final rssiMap = <String, double>{
          for (final b in beacons)
            b.id: _rssiFromDistance(_dist(p[0], p[1], b.x, b.y), rng,
                sigma: 6),
        };
        final eng = TrilaterationEngine();
        final pos = eng.calculatePosition(beacons, rssiMap);
        if (pos == null) continue;
        returned++;
        errors.add(_dist(p[0], p[1], pos['x']!, pos['y']!));
      }
      final r = _SimResult(errors, gridPoints.length, returned);
      // ignore: avoid_print
      print('\n[Trilateration LS — sigma=6 (gürültülü)]\n$r');
      // GN'in en çok fark yarattığı senaryo (LS-only: median 1.40 / p95 3.71).
      // Gürültülü gerçek ortam tezde kritik → kazanımı kilitle.
      expect(r.coverage, greaterThanOrEqualTo(0.95));
      expect(r.median, lessThan(1.35));
      expect(r.p95, lessThan(3.30));
    });

    test('Trilateration LS — kenarlar (sadece 2-3 beacon görünür)', () {
      // Kenar simülasyonu: bir köşeden uzak beacon'ları RSSI listesinden düş.
      final rng = Random(45);
      final errors = <double>[];
      int returned = 0;
      int nulls = 0;
      for (final p in gridPoints) {
        // Her beacon -85 dBm'den zayıfsa "görülmedi" say (gerçekçi kenar davranışı)
        final rssiMap = <String, double>{};
        for (final b in beacons) {
          final r = _rssiFromDistance(_dist(p[0], p[1], b.x, b.y), rng);
          if (r > -85) rssiMap[b.id] = r;
        }
        final eng = TrilaterationEngine();
        final pos = eng.calculatePosition(beacons, rssiMap);
        if (pos == null) {
          nulls++;
          continue;
        }
        returned++;
        errors.add(_dist(p[0], p[1], pos['x']!, pos['y']!));
      }
      final r = _SimResult(errors, gridPoints.length, returned);
      // ignore: avoid_print
      print('\n[Trilateration LS — kenar simulation]\n$r (null=$nulls)');
    });
  });

  group('SIMULATION — Fingerprint (KNN k=3)', () {
    test('Fingerprint — 4 referans nokta (köşeler), 1m hata toleransı', () {
      final rng = Random(50);

      // 4 köşeden 5 örnek alıp ortalamasını fingerprint olarak kaydet
      final eng = FingerprintEngine();
      final refPoints = {
        'NW': [0.5, 0.5],
        'NE': [4.5, 0.5],
        'SW': [0.5, 4.5],
        'SE': [4.5, 4.5],
      };
      for (final entry in refPoints.entries) {
        final p = entry.value;
        // 5 sample ortalaması
        final acc = <String, double>{for (final b in beacons) b.id: 0};
        for (int s = 0; s < 5; s++) {
          for (final b in beacons) {
            acc[b.id] = acc[b.id]! +
                _rssiFromDistance(_dist(p[0], p[1], b.x, b.y), rng);
          }
        }
        final rssiMap = <String, int>{
          for (final entry in acc.entries) entry.key: (entry.value / 5).round(),
        };
        eng.addFingerprintWithAutoIndex(
            Fingerprint(id: entry.key, name: entry.key, rssiMap: rssiMap));
      }

      int correct = 0;
      int matched = 0;
      for (final entry in refPoints.entries) {
        final p = entry.value;
        // Aynı noktada 3 ölçüm + sayım
        for (int s = 0; s < 3; s++) {
          final liveMap = <String, int>{
            for (final b in beacons)
              b.id: _rssiFromDistance(_dist(p[0], p[1], b.x, b.y), rng).round(),
          };
          final m = eng.findNearestMatch(liveMap, threshold: 25.0);
          if (m == null) continue;
          matched++;
          if (m.fingerprint.name == entry.key) correct++;
        }
      }

      final accuracy = matched == 0 ? 0 : correct / matched;
      // ignore: avoid_print
      print('\n[Fingerprint k=3 — 4 köşe, kendi konum tahmini]'
          '\n   doğru=$correct/$matched (accuracy=${(accuracy * 100).toStringAsFixed(1)}%)');
      expect(accuracy, greaterThanOrEqualTo(0.75));
    });

    test('Fingerprint — yakın referans noktalar arası karışıklık', () {
      // 1m aralıklı 3 nokta — KNN ne kadar net ayırabiliyor?
      final rng = Random(51);
      final eng = FingerprintEngine();
      final refPoints = {
        'A': [1.0, 2.5],
        'B': [2.0, 2.5],
        'C': [3.0, 2.5],
      };
      for (final entry in refPoints.entries) {
        final p = entry.value;
        final acc = <String, double>{for (final b in beacons) b.id: 0};
        for (int s = 0; s < 5; s++) {
          for (final b in beacons) {
            acc[b.id] = acc[b.id]! +
                _rssiFromDistance(_dist(p[0], p[1], b.x, b.y), rng);
          }
        }
        final rssiMap = <String, int>{
          for (final e in acc.entries) e.key: (e.value / 5).round(),
        };
        eng.addFingerprintWithAutoIndex(
            Fingerprint(id: entry.key, name: entry.key, rssiMap: rssiMap));
      }

      int correct = 0;
      int matched = 0;
      for (final entry in refPoints.entries) {
        final p = entry.value;
        for (int s = 0; s < 10; s++) {
          final liveMap = <String, int>{
            for (final b in beacons)
              b.id: _rssiFromDistance(_dist(p[0], p[1], b.x, b.y), rng).round(),
          };
          final m = eng.findNearestMatch(liveMap, threshold: 25.0);
          if (m == null) continue;
          matched++;
          if (m.fingerprint.name == entry.key) correct++;
        }
      }
      final acc = matched == 0 ? 0 : correct / matched;
      // ignore: avoid_print
      print('\n[Fingerprint — 1m aralıklı 3 nokta]'
          '\n   doğru=$correct/$matched (accuracy=${(acc * 100).toStringAsFixed(1)}%)');
    });
  });
}
