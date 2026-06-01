// ContactController evict/trigger güvenliği — multi-agent bug-avı regresyon testi.
//
// İki kritik bulgu burada kilitlenir:
//  1) onEncounterEvent, _evict bir encounter'ı sildikten sonra `!` ile null-check
//     CRASH ediyordu (zayıf sinyal + süre dolmuş encounter senaryosu). Artık
//     null-guard var → crash yok.
//  2) Evict eşiği (-85) tetik eşiğinden (-80) düşük (histerezis); -80 sınırında
//     gezen cihaz flip-flop yapıp reportedContactCount şişirmemeli.
//
// onEncounterEvent zamanı parametre olarak aldığı için sentetik DateTime ile
// gerçek-zaman beklemeden test edilebiliyor.

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

  group('ContactController — evict/trigger güvenliği', () {
    test('zayıf sinyal + süre dolmuş encounter evict edilince CRASH ETMEZ', () {
      final t0 = DateTime(2026, 6, 1, 12, 0, 0);
      // -90 dBm (çok zayıf). duration >= 10s olunca _evict bu encounter'ı siler;
      // eski kod sonraki `_encounters[anonId]!` satırında patlardı.
      expect(() {
        for (int s = 0; s <= 12; s++) {
          ctrl.onEncounterEvent('aa:bb', -90, t0.add(Duration(seconds: s)));
        }
      }, returnsNormally);
      // Zayıf sinyal → contact tetiklenmemeli.
      expect(container.read(contactControllerProvider).reportedContactCount, 0);
    });

    test('histerezis: -82 dBm (ölü bant) encounter KORUNUR ve tetiklenmez', () {
      final t0 = DateTime(2026, 6, 1, 12, 0, 0);
      for (int s = 0; s <= 12; s++) {
        ctrl.onEncounterEvent('cc:dd', -82, t0.add(Duration(seconds: s)));
      }
      // -82: tetik eşiğinin (>-80) altında → tetiklenmez; ama evict eşiğinin
      // (<=-85) üstünde → silinmez. Encounter hâlâ aktif kalmalı.
      expect(ctrl.encounters.containsKey('cc:dd'), isTrue);
      expect(container.read(contactControllerProvider).reportedContactCount, 0);
    });

    test('güçlü sinyal (>-80) + süre dolunca contact TETİKLENİR', () {
      final t0 = DateTime(2026, 6, 1, 12, 0, 0);
      int triggers = 0;
      ctrl.setContactTrigger((_) => triggers++);
      for (int s = 0; s <= 12; s++) {
        ctrl.onEncounterEvent('ee:ff', -60, t0.add(Duration(seconds: s)));
      }
      expect(triggers, greaterThanOrEqualTo(1));
      expect(container.read(contactControllerProvider).reportedContactCount, 1);
    });
  });

  group('ContactController — dropout resume (iPhone paket kaybı)', () {
    test('time-evict edilen cihaz resume penceresinde dönerse AYNI temas, sayaç ARTMAZ', () {
      final t0 = DateTime(2026, 6, 1, 12, 0, 0);
      final triggeredIds = <String>[];
      ctrl.setContactTrigger((e) => triggeredIds.add(e.clientEventId ?? '?'));

      // A: güçlü sinyal 12s → contact tetiklenir (report=1).
      for (int s = 0; s <= 12; s++) {
        ctrl.onEncounterEvent('aa:11', -60, t0.add(Duration(seconds: s)));
      }
      expect(container.read(contactControllerProvider).reportedContactCount, 1);
      final aId = triggeredIds.first;

      // A kaybolur (dropout). Bu sırada B sürekli görünür → her event _evict
      // çağırır; A 20sn eviction'ını geçince _resumable'a taşınır.
      for (int s = 13; s <= 38; s++) {
        ctrl.onEncounterEvent('bb:22', -60, t0.add(Duration(seconds: s)));
      }
      expect(ctrl.encounters.containsKey('aa:11'), isFalse); // aktif değil (resumable)

      // A geri döner (~27sn boşluk < 120sn resume penceresi) → AYNI temas.
      for (int s = 39; s <= 50; s++) {
        ctrl.onEncounterEvent('aa:11', -60, t0.add(Duration(seconds: s)));
      }

      // A için yeni clientEventId ÜRETİLMEDİ: benzersiz id'ler en fazla {A, B}.
      // aId dışında en çok 1 farklı id (B'nin id'si) olmalı — A ikinci kez açılmadı.
      expect(triggeredIds.toSet().where((id) => id != aId).length, lessThanOrEqualTo(1));
      // Toplam contact = 2 (A bir kez + B bir kez); A dropout sonrası TEKRAR sayılmadı.
      expect(container.read(contactControllerProvider).reportedContactCount, 2);
    });

    test('RSSI ile uzaklaşıp giden cihaz resume EDİLMEZ → yeni temas (stand sayımı korunur)', () {
      final t0 = DateTime(2026, 6, 1, 12, 0, 0);
      final triggeredIds = <String>[];
      ctrl.setContactTrigger((e) => triggeredIds.add(e.clientEventId ?? '?'));

      // Faz 1: güçlü sinyal 12s → contact (report=1).
      for (int s = 0; s <= 12; s++) {
        ctrl.onEncounterEvent('cc:33', -60, t0.add(Duration(seconds: s)));
      }
      expect(container.read(contactControllerProvider).reportedContactCount, 1);
      final firstId = triggeredIds.first;

      // Faz 2: aynı cihaz sürekli görünüyor ama sinyal -90 (uzaklaştı). Yeterli
      // örnek + medyan -85 altı → RSSI-evict (gerçek ayrılış), resume YOK.
      // (Not: sürekli görüldüğü için evict sonrası zayıf bir encounter olarak
      // yeniden doğabilir ama RAPORLANMAZ; asıl kontrol Faz 3'teki yeni temas.)
      for (int s = 13; s <= 25; s++) {
        ctrl.onEncounterEvent('cc:33', -90, t0.add(Duration(seconds: s)));
      }

      // Faz 3: tekrar yaklaşır → YENİ temas (yeni clientEventId), sayaç 2 olur.
      for (int s = 26; s <= 40; s++) {
        ctrl.onEncounterEvent('cc:33', -60, t0.add(Duration(seconds: s)));
      }
      expect(container.read(contactControllerProvider).reportedContactCount, 2);
      // Yeni temas farklı clientEventId taşımalı (resume edilmediğinin kanıtı).
      expect(triggeredIds.any((id) => id != firstId), isTrue);
    });

    test('resume penceresi DIŞINDA dönüş → yeni temas', () {
      final t0 = DateTime(2026, 6, 1, 12, 0, 0);
      ctrl.setContactTrigger((_) {});

      for (int s = 0; s <= 12; s++) {
        ctrl.onEncounterEvent('dd:44', -60, t0.add(Duration(seconds: s)));
      }
      // B sürekli görünerek A'yı (dd:44) resumable'a düşürür ve 120sn+ tutar.
      for (int s = 13; s <= 150; s++) {
        ctrl.onEncounterEvent('bb:99', -60, t0.add(Duration(seconds: s)));
      }
      // A 120sn'den uzun süredir yok → resumable'dan da temizlendi.
      // Geri dönerse YENİ temas: reportedContactCount artmalı (B=1 + A-yeni=1 → ≥2 hedef
      // değil; burada sadece A'nın yeniden sayıldığını doğruluyoruz).
      final before = container.read(contactControllerProvider).reportedContactCount;
      for (int s = 151; s <= 163; s++) {
        ctrl.onEncounterEvent('dd:44', -60, t0.add(Duration(seconds: s)));
      }
      final after = container.read(contactControllerProvider).reportedContactCount;
      expect(after, greaterThan(before)); // resume yok → yeni contact sayıldı
    });
  });
}
