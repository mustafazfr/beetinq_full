// ContactEncounter.recentWindow — 2026-06-10 bug avı.
//
// DİKKAT edilen davranış: pencere BOŞSA (avg: 0, median: 0, count: 0) döner.
// median=0, RSSI eşiklerinden BÜYÜK olduğu için ("0 > -75") bu değeri count
// kontrolü olmadan eşik kararında kullanmak SAHTE TETİK üretir. Bugün tüm
// çağrı yolları pencerede ≥1 örnek garanti ediyor (her güncellemede lastSeen
// anına örnek ekleniyor); bu testler o sözleşmeyi ve sınır davranışını
// kilitler — gelecekte biri count'suz kullanırsa bu dosya hatırlatır.

import 'package:beetinq_sense/core/contact/contact_encounter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final t0 = DateTime(2026, 6, 1, 12, 0, 0);

  ContactEncounter enc(List<(int rssi, int sec)> samples) {
    return ContactEncounter(
      seenAnonId: 'aa:bb',
      firstSeen: t0,
      lastSeen: samples.isEmpty ? t0 : t0.add(Duration(seconds: samples.last.$2)),
      samples: [
        for (final (r, s) in samples) RssiSample(r, t0.add(Duration(seconds: s))),
      ],
    );
  }

  group('ContactEncounter.recentWindow', () {
    test('boş örnek listesi → count=0 (median=0 EŞİK KARARINDA KULLANILMAMALI)', () {
      final e = enc([]);
      final w = e.recentWindow(const Duration(seconds: 10));
      expect(w.count, 0);
      // Sözleşme: count==0 iken avg/median anlamsızdır (0 döner).
      expect(w.median, 0);
    });

    test('pencere yalnız son N saniyeyi kapsar (eski örnekler dışarıda)', () {
      // 0..30sn arası örnekler; pencere son 10sn (lastSeen=30 → cutoff=20).
      final e = enc([(-90, 0), (-90, 5), (-90, 15), (-60, 25), (-62, 30)]);
      final w = e.recentWindow(const Duration(seconds: 10));
      expect(w.count, 2); // 25 ve 30 (15, cutoff'tan önce → dahil değil)
      expect(w.median, -61); // (-60 + -62) / 2
    });

    test('medyan tek uç okumayı bastırır (iPhone sıçramalı RSSI)', () {
      final e = enc([(-60, 8), (-61, 9), (-95, 10)]); // tek zayıf sıçrama
      final w = e.recentWindow(const Duration(seconds: 10));
      expect(w.median, -61); // sıçrama medyanı sallamaz
      expect(w.avg, closeTo(-72, 0.1)); // ortalama sallanırdı → medyan kullanılıyor
    });

    test('avgRssi tüm örneklerin ortalaması (backend raporu için)', () {
      final e = enc([(-60, 0), (-70, 5)]);
      expect(e.avgRssi, -65);
    });

    test('duration = lastSeen - firstSeen', () {
      final e = enc([(-60, 0), (-60, 42)]);
      expect(e.duration.inSeconds, 42);
    });
  });
}
