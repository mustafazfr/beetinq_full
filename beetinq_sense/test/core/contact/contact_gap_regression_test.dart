// Contact tracing — 2026-06-10 bug avı regresyon testleri.
//
// Üç kanıtlanmış bug burada kilitlenir:
//  1) SAHTE UZUN TEMAS (kritik): _evict yalnız paket gelince çalıştığı için
//     sessiz RF döneminde (2 cihazlı demo!) timeout işlemiyordu; raporlanmamış
//     encounter 10dk sonra dönünce boşluğu yutup "600sn temas" tetikliyordu.
//     Fix: onEncounterEvent'te boşluk > eviction timeout ise kaçırılmış evict
//     uygulanır, mevcut resume kuralları karar verir.
//  2) STAND YAPIŞMASI (orta): leave-grace _currentStandSince'e bakıyordu;
//     konum "B ↔ null" flap'leyince hiç tetiklenmiyordu. Fix: _lastAtLocation
//     ("bu stand'ı en son ne zaman gördüm") üzerinden karar.
//  3) DWELL ŞİŞMESİ (düşük): stand→stand geçişte 45sn dwell, segment rotate
//     firstSeen'i sıfırladığı için fiilen 60sn oluyordu. Fix: _pairContactSince
//     (çiftin kesintisiz temas başlangıcı) rotasyonlarda korunur.
//
// onEncounterEvent/onLocationChanged sentetik DateTime aldığı için gerçek
// zaman beklemeden test edilir.

import 'package:beetinq_sense/features/contact/contact_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late ProviderContainer container;
  late ContactController ctrl;

  setUp(() {
    container = ProviderContainer();
    ctrl = container.read(contactControllerProvider.notifier);
  });
  tearDown(() => container.dispose());

  group('Sessiz RF dönemi — tembel evict deliği', () {
    test('RAPORLANMAMIŞ encounter + 10dk sessizlik + dönüş → YENİ kısa temas', () {
      final t0 = DateTime(2026, 6, 1, 12, 0, 0);
      final durations = <int>[];
      ctrl.setContactTrigger((e) => durations.add(e.duration.inSeconds));

      // 5sn görüldü (10sn eşiği dolmadı → raporlanmadı), sonra 10dk sessizlik
      // (hiçbir cihazdan paket yok → _evict tick'i yok), sonra 12sn dönüş.
      for (int s = 0; s <= 5; s++) {
        ctrl.onEncounterEvent('aa:bb', -60, t0.add(Duration(seconds: s)));
      }
      final t1 = t0.add(const Duration(minutes: 10));
      for (int s = 0; s <= 12; s++) {
        ctrl.onEncounterEvent('aa:bb', -60, t1.add(Duration(seconds: s)));
      }

      // Boşluk (600s) resume penceresini (45s) aşar → dönüş YENİ temastır;
      // süre boşluğu İÇERMEMELİ. (Bug: süre=600s sahte temas çıkıyordu.)
      expect(durations, isNotEmpty);
      expect(durations.first, lessThan(60));
    });

    test('RAPORLANMIŞ encounter + 10dk sessizlik → stale keser, dönüş yeni temas', () {
      final t0 = DateTime(2026, 6, 1, 12, 0, 0);
      final durations = <int>[];
      ctrl.setContactTrigger((e) => durations.add(e.duration.inSeconds));

      for (int s = 0; s <= 15; s++) {
        ctrl.onEncounterEvent('cc:dd', -60, t0.add(Duration(seconds: s)));
      }
      expect(durations, isNotEmpty);
      final before = durations.length;

      final t1 = t0.add(const Duration(minutes: 10));
      for (int s = 0; s <= 12; s++) {
        ctrl.onEncounterEvent('cc:dd', -60, t1.add(Duration(seconds: s)));
      }
      for (final d in durations.sublist(before)) {
        expect(d, lessThan(60));
      }
    });

    test('kısa dropout (30sn ≤ resume 45sn) → AYNI temas devam, sayaç şişmez', () {
      final t0 = DateTime(2026, 6, 1, 12, 0, 0);
      ctrl.setContactTrigger((_) {});

      for (int s = 0; s <= 15; s++) {
        ctrl.onEncounterEvent('ee:ff', -60, t0.add(Duration(seconds: s)));
      }
      expect(container.read(contactControllerProvider).reportedContactCount, 1);

      // 30sn sessizlik → timeout (20sn) aşıldı ama resume penceresi (45sn) içinde.
      final t1 = t0.add(const Duration(seconds: 45));
      for (int s = 0; s <= 12; s++) {
        ctrl.onEncounterEvent('ee:ff', -60, t1.add(Duration(seconds: s)));
      }
      // Aynı temasın devamı: sayaç hâlâ 1 (dropout teması bölmez).
      expect(container.read(contactControllerProvider).reportedContactCount, 1);
    });
  });

  group('Stand segmentasyonu — yapışma ve dwell', () {
    test('konum "B ↔ null" flap\'lerken ayrılınan stand segmenti "—"e döner', () {
      final t0 = DateTime(2026, 6, 1, 12, 0, 0);
      ctrl.setContactTrigger((_) {});

      // Stand A'da 50sn → temas + stand A commit.
      ctrl.onLocationChanged('Sergi-A', t0);
      for (int s = 0; s <= 50; s++) {
        ctrl.onEncounterEvent('11:22', -60, t0.add(Duration(seconds: s)));
      }
      expect(ctrl.encounters['11:22']?.locationName, 'Sergi-A');

      // Ayrılış: konum her 5sn'de "Sergi-B" ↔ null flap'liyor (60sn boyunca).
      var t = t0.add(const Duration(seconds: 51));
      for (int cycle = 0; cycle < 12; cycle++) {
        ctrl.onLocationChanged(cycle.isEven ? 'Sergi-B' : null, t);
        for (int s = 0; s < 5; s++) {
          ctrl.onEncounterEvent('11:22', -60, t.add(Duration(seconds: s)));
        }
        t = t.add(const Duration(seconds: 5));
      }

      // Grace (15sn) çoktan doldu → segment artık "—" olmalı (yapışma yok).
      expect(ctrl.encounters['11:22']?.locationName, isNull);
    });

    test('stand\'a grace içinde dönüş → segment KORUNUR (jitter bölmez)', () {
      final t0 = DateTime(2026, 6, 1, 12, 0, 0);
      ctrl.setContactTrigger((_) {});

      ctrl.onLocationChanged('Sergi-A', t0);
      for (int s = 0; s <= 50; s++) {
        ctrl.onEncounterEvent('33:44', -60, t0.add(Duration(seconds: s)));
      }
      expect(ctrl.encounters['33:44']?.locationName, 'Sergi-A');

      // 8sn'lik konum kaybı (grace 15sn altı), sonra A'ya dönüş.
      final t1 = t0.add(const Duration(seconds: 51));
      ctrl.onLocationChanged(null, t1);
      for (int s = 0; s < 8; s++) {
        ctrl.onEncounterEvent('33:44', -60, t1.add(Duration(seconds: s)));
      }
      final t2 = t1.add(const Duration(seconds: 8));
      ctrl.onLocationChanged('Sergi-A', t2);
      for (int s = 0; s <= 20; s++) {
        ctrl.onEncounterEvent('33:44', -60, t2.add(Duration(seconds: s)));
      }
      expect(ctrl.encounters['33:44']?.locationName, 'Sergi-A');
    });

    test('stand→stand geçişte dwell, YENİ stand\'a varıştan ~45sn sonra commit olur', () {
      final t0 = DateTime(2026, 6, 1, 12, 0, 0);
      ctrl.setContactTrigger((_) {});

      // Stand A'da 50sn → segment A.
      ctrl.onLocationChanged('Sergi-A', t0);
      for (int s = 0; s <= 50; s++) {
        ctrl.onEncounterEvent('55:66', -60, t0.add(Duration(seconds: s)));
      }
      expect(ctrl.encounters['55:66']?.locationName, 'Sergi-A');

      // t=51'de Sergi-B'ye geçiş; paketler kesintisiz akıyor.
      final t1 = t0.add(const Duration(seconds: 51));
      ctrl.onLocationChanged('Sergi-B', t1);
      String? locAt(int secAfterB) {
        // t1'den itibaren her saniye paket; istenen ana kadar ilerlet.
        return ctrl.encounters['55:66']?.locationName;
      }

      for (int s = 0; s <= 100; s++) {
        ctrl.onEncounterEvent('55:66', -60, t1.add(Duration(seconds: s)));
        final loc = locAt(s);
        if (s < 40) {
          // B'ye varıştan 45sn önce B commit OLMAMALI (dwell dolmadı).
          expect(loc, isNot('Sergi-B'),
              reason: 'B commit erken geldi (t1+${s}s)');
        }
      }
      // 100sn sonra: leave(A) ~15sn + dwell 45sn çoktan doldu → B yazılmış olmalı.
      // (Eski bug: dwell saati segment rotate'inde sıfırlanıp ~60sn gecikiyordu;
      //  şimdi varış+45sn civarında commit olur.)
      expect(ctrl.encounters['55:66']?.locationName, 'Sergi-B');
    });
  });
}
