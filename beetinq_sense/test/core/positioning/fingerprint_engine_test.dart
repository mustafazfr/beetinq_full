import 'package:flutter_test/flutter_test.dart';
import 'package:beetinq_sense/core/positioning/fingerprint_engine.dart';

Fingerprint _fp(String name, Map<String, int> rssi, {String? id}) =>
    Fingerprint(id: id ?? name, name: name, rssiMap: rssi);

void main() {
  group('findNearestMatch — KNN k=3 majority vote', () {
    test('Empty fingerprint listesi → null', () {
      final eng = FingerprintEngine();
      final m = eng.findNearestMatch({'b1': -65});
      expect(m, isNull);
    });

    test('Tam aynı RSSI → skor 0, eşleşir', () {
      final eng = FingerprintEngine()
        ..addFingerprint(_fp('Sony', {'b1': -65, 'b2': -70}));
      final m = eng.findNearestMatch({'b1': -65, 'b2': -70});
      expect(m, isNotNull);
      expect(m!.fingerprint.name, 'Sony');
      expect(m.score, closeTo(0.0, 0.001));
    });

    test('Threshold üstü → null', () {
      final eng = FingerprintEngine()
        ..addFingerprint(_fp('Sony', {'b1': -50}));
      // Live: -90 (40 dB fark, sqrt(40^2/1)=40 → threshold 15 üstü)
      final m = eng.findNearestMatch({'b1': -90});
      expect(m, isNull);
    });

    test('Per-location-best — A en yakın snapshot ile kazanır', () {
      // A'nın en iyi snapshot'ı -65 (live -66, fark 1), B -64 (fark 2).
      // Per-location-best: her konum kendi EN İYİ snapshot'ıyla yarışır,
      // snapshot SAYISI artık avantaj değil (eski bias düzeltildi).
      final eng = FingerprintEngine()
        ..addFingerprint(_fp('A', {'b1': -65}, id: 'a1'))
        ..addFingerprint(_fp('A', {'b1': -67}, id: 'a2'))
        ..addFingerprint(_fp('B', {'b1': -64}, id: 'b1'));
      final m = eng.findNearestMatch({'b1': -66});
      expect(m, isNotNull);
      expect(m!.fingerprint.name, 'A');
      expect(m.voteCount, 1); // per-location-best → her konum 1 temsil
      expect(m.k, 2); // değerlendirilen konum sayısı (A, B)
    });

    test('Tie-break (eşit oy) → düşük toplam skor kazanır', () {
      final eng = FingerprintEngine()
        ..addFingerprint(_fp('A', {'b1': -60}, id: 'a1')) // 5 dB fark
        ..addFingerprint(_fp('A', {'b1': -62}, id: 'a2')) // 3 dB
        ..addFingerprint(_fp('B', {'b1': -65}, id: 'b1')) // 0 dB
        ..addFingerprint(_fp('B', {'b1': -66}, id: 'b2')); // 1 dB
      // Top3: B(-65), B(-66), A(-62) → 2B vs 1A → B kazanır oyla
      final m = eng.findNearestMatch({'b1': -65});
      expect(m!.fingerprint.name, 'B');
    });

    test('Suffix "#N" base ada indirgenir (snapshot\'lar tek konum sayılır)', () {
      final eng = FingerprintEngine()
        ..addFingerprint(_fp('Sony Standı #1', {'b1': -65}, id: 's1'))
        ..addFingerprint(_fp('Sony Standı #2', {'b1': -67}, id: 's2'))
        ..addFingerprint(_fp('Vodafone', {'b1': -90}, id: 'v1'));
      final m = eng.findNearestMatch({'b1': -66});
      expect(m, isNotNull);
      // "Sony Standı #1/#2" tek konuma (base ad) indirgenir, en iyi snapshot
      // ile temsil edilir. Vodafone threshold dışı (24 dB fark) → elenir.
      expect(m!.fingerprint.name, startsWith('Sony Standı'));
      expect(m.voteCount, 1);
      expect(m.k, 1); // sadece Sony Standı threshold altı
    });

    test('Asimetrik ceza — kayıtlı beacon kayboldu daha pahalı', () {
      final eng = FingerprintEngine()
        ..addFingerprint(_fp('A', {'b1': -65, 'b2': -70}))
        ..addFingerprint(_fp('B', {'b1': -65}));
      // Live: sadece b1 var (b2 kayboldu) → A için missing penalty
      // B ile birebir aynı (b1 -65)
      // B daha yakın olmalı
      final m = eng.findNearestMatch({'b1': -65});
      expect(m, isNotNull);
      expect(m!.fingerprint.name, 'B');
    });

    test('Live\'da yeni beacon var → 20^2 ceza ama yine match', () {
      final eng = FingerprintEngine()
        ..addFingerprint(_fp('A', {'b1': -65}));
      final m = eng.findNearestMatch({'b1': -65, 'extra': -55});
      // sumSquares = 0 + 20^2 = 400, sqrt(400/2) = 14.14 → threshold 15 altında
      expect(m, isNotNull);
      expect(m!.fingerprint.name, 'A');
    });

    test('matchCount=0 (hiç ortak beacon yok) → infinity → null', () {
      final eng = FingerprintEngine()..addFingerprint(_fp('A', {'b1': -65}));
      final m = eng.findNearestMatch({'b2': -65});
      // sumSquares = 30^2 + 20^2, allKeys = 2; ama matchCount=0 → infinity
      expect(m, isNull);
    });
  });

  group('addFingerprintWithAutoIndex', () {
    test('İlk kayıt — düz ad', () {
      final eng = FingerprintEngine()
        ..addFingerprintWithAutoIndex(_fp('Sony', {'b': -60}, id: 's1'));
      expect(eng.knownFingerprints.first.name, 'Sony');
    });

    test('İkinci kayıt — birinci #1, ikinci #2 olur', () {
      final eng = FingerprintEngine()
        ..addFingerprintWithAutoIndex(_fp('Sony', {'b': -60}, id: 's1'))
        ..addFingerprintWithAutoIndex(_fp('Sony', {'b': -61}, id: 's2'));
      expect(eng.knownFingerprints.length, 2);
      expect(eng.knownFingerprints[0].name, 'Sony #1');
      expect(eng.knownFingerprints[1].name, 'Sony #2');
    });

    test('Üçüncü kayıt — sayım base ad üzerinden, #3 olur', () {
      final eng = FingerprintEngine()
        ..addFingerprintWithAutoIndex(_fp('Sony', {'b': -60}, id: 's1'))
        ..addFingerprintWithAutoIndex(_fp('Sony', {'b': -61}, id: 's2'))
        ..addFingerprintWithAutoIndex(_fp('Sony', {'b': -62}, id: 's3'));
      expect(eng.knownFingerprints.length, 3);
      expect(eng.knownFingerprints[2].name, 'Sony #3');
    });

    test('Farklı isimler bağımsız', () {
      final eng = FingerprintEngine()
        ..addFingerprintWithAutoIndex(_fp('Sony', {'b': -60}, id: 's1'))
        ..addFingerprintWithAutoIndex(_fp('LG', {'b': -60}, id: 'l1'))
        ..addFingerprintWithAutoIndex(_fp('Sony', {'b': -61}, id: 's2'));
      expect(
        eng.knownFingerprints.map((f) => f.name).toList(),
        ['Sony #1', 'LG', 'Sony #2'],
      );
    });
  });

  group('countByName + remove', () {
    test('countByName tam isim eşleşmesi', () {
      final eng = FingerprintEngine()
        ..addFingerprint(_fp('Sony #1', {'b': -60}))
        ..addFingerprint(_fp('Sony #2', {'b': -60}))
        ..addFingerprint(_fp('LG', {'b': -60}));
      expect(eng.countByName('Sony #1'), 1);
      expect(eng.countByName('Sony'), 0); // tam eşleşme arar
      expect(eng.countByName('LG'), 1);
    });

    test('removeFingerprintById', () {
      final eng = FingerprintEngine()
        ..addFingerprint(_fp('A', {'b': -60}, id: 'x1'))
        ..addFingerprint(_fp('B', {'b': -60}, id: 'x2'));
      eng.removeFingerprintById('x1');
      expect(eng.knownFingerprints.length, 1);
      expect(eng.knownFingerprints.first.id, 'x2');
    });
  });

  group('Fingerprint JSON', () {
    test('toJson + fromJson round-trip', () {
      final fp = _fp('Sony', {'b1': -65, 'b2': -70}, id: 's1');
      final j = fp.toJson();
      final restored = Fingerprint.fromJson(j);
      expect(restored.id, fp.id);
      expect(restored.name, fp.name);
      expect(restored.rssiMap, fp.rssiMap);
    });

    test('createdAt yoksa şimdiyle doldurulur (geriye dönük uyum)', () {
      final restored = Fingerprint.fromJson({
        'id': 'x',
        'name': 'X',
        'rssiMap': {'b': -60},
      });
      expect(restored.createdAt, isNotNull);
    });
  });
}
