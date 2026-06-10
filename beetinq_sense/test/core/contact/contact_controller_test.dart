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

    test('histerezis: -78 dBm (ölü bant) encounter KORUNUR ve tetiklenmez', () {
      final t0 = DateTime(2026, 6, 1, 12, 0, 0);
      for (int s = 0; s <= 12; s++) {
        ctrl.onEncounterEvent('cc:dd', -78, t0.add(Duration(seconds: s)));
      }
      // -78: tetik eşiğinin (>-75) altında → tetiklenmez; ama evict eşiğinin
      // (>-80) üstünde → kapıdan geçer, silinmez. Ölü bant (-80..-75) → aktif kalır.
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

    test('zayıf sinyal (-90, evict eşiği altı) encounter OLUŞTURMAZ — uzak telefon temas değil', () {
      // SAHA BULGUSU 2026-06-07: uzaktaki (ör. -96) telefon seyrek-zayıf paketlerle
      // encounter'ı sonsuza dek canlı tutuyordu. Artık evict eşiğinden (-82) zayıf
      // paket encounter'ı OLUŞTURMAZ/SÜRDÜRMEZ.
      final t0 = DateTime(2026, 6, 1, 12, 0, 0);
      for (int s = 0; s <= 30; s++) {
        ctrl.onEncounterEvent('cc:33', -90, t0.add(Duration(seconds: s)));
      }
      expect(ctrl.encounters.containsKey('cc:33'), isFalse); // zayıf → encounter yok
      expect(container.read(contactControllerProvider).reportedContactCount, 0);
    });

    test('güçlü temas zayıflayınca (uzaklaşma) timeout ile biter', () {
      final t0 = DateTime(2026, 6, 1, 12, 0, 0);
      ctrl.setContactTrigger((_) {});
      // Faz 1: güçlü 12s → contact (report=1, encounter aktif).
      for (int s = 0; s <= 12; s++) {
        ctrl.onEncounterEvent('dd:55', -60, t0.add(Duration(seconds: s)));
      }
      expect(container.read(contactControllerProvider).reportedContactCount, 1);
      // Faz 2: -90 (evict eşiği altı → encounter güncellenmez). _evict çalışsın
      // diye event akışı sürüyor; son güçlü görülme s=12. >20sn sonra timeout.
      for (int s = 15; s <= 40; s += 3) {
        ctrl.onEncounterEvent('dd:55', -90, t0.add(Duration(seconds: s)));
      }
      // Güçlü görülmeden 20sn+ geçti → timeout ile aktif encounter'dan düştü.
      expect(ctrl.encounters.containsKey('dd:55'), isFalse);
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

    test('bayatlama: zayıf görülmeye devam eden temas 60sn sonra biter → yeni temas', () {
      final t0 = DateTime(2026, 6, 1, 12, 0, 0);
      final ids = <String>[];
      ctrl.setContactTrigger((e) => ids.add(e.clientEventId ?? '?'));

      // Faz 1: güçlü 12 sn → temas (report=1).
      for (int s = 0; s <= 12; s++) {
        ctrl.onEncounterEvent('aa:11', -60, t0.add(Duration(seconds: s)));
      }
      expect(container.read(contactControllerProvider).reportedContactCount, 1);
      final firstId = ids.first;

      // Faz 2: cihaz uzaklaştı ama -78 (ölü bant -80..-75) ile hâlâ GÖRÜLÜYOR —
      // kapıdan geçer (timeout yok), median -78 <= -75 olduğu için re-report yok.
      // Son güçlü rapordan 60sn+ geçince BAYATLAMA teması bitirmeli.
      for (int s = 15; s <= 90; s += 5) {
        ctrl.onEncounterEvent('aa:11', -78, t0.add(Duration(seconds: s)));
      }

      // Faz 3: tekrar güçlü → bayatlayan eski temas bittiği için YENİ temas açılır.
      for (int s = 95; s <= 108; s++) {
        ctrl.onEncounterEvent('aa:11', -60, t0.add(Duration(seconds: s)));
      }
      expect(container.read(contactControllerProvider).reportedContactCount, 2);
      expect(ids.any((id) => id != firstId), isTrue); // yeni clientEventId
    });
  });

  group('ContactController — stand segmentasyonu', () {
    test('standda yeterince durulunca "—" segmenti kapanır, stand segmenti açılır', () {
      final t0 = DateTime(2026, 6, 1, 12, 0, 0);
      final segs = <String?>[]; // her tetiklemede o anki stand
      ctrl.setContactTrigger((e) => segs.add(e.locationName));

      // Rapor başında konum "A Standı" (sentetik saat ile).
      ctrl.onLocationChanged('A Standı', t0);

      // 0–60 sn arası güçlü temas. İlk ~45 sn "—", sonra A Standı'na commit.
      for (int s = 0; s <= 60; s++) {
        ctrl.onEncounterEvent('aa:11', -60, t0.add(Duration(seconds: s)));
      }

      // En az bir rapor "—" (null) ile, en az bir rapor "A Standı" ile gitmeli.
      expect(segs.any((l) => l == null), isTrue, reason: 'ilk segment "—" olmalı');
      expect(segs.any((l) => l == 'A Standı'), isTrue, reason: 'duruş sonrası stand segmenti');
      // "—" segmenti stand segmentinden ÖNCE gelmeli.
      expect(segs.indexWhere((l) => l == null) <
             segs.indexWhere((l) => l == 'A Standı'), isTrue);
    });

    test('kısa uğrayış (<45sn) stand yazmaz — "—" olarak kalır', () {
      final t0 = DateTime(2026, 6, 1, 12, 0, 0);
      final segs = <String?>[];
      ctrl.setContactTrigger((e) => segs.add(e.locationName));
      ctrl.onLocationChanged('Geçiş', t0);
      // Sadece 30 sn → commit eşiği (45sn) dolmaz.
      for (int s = 0; s <= 30; s++) {
        ctrl.onEncounterEvent('bb:22', -60, t0.add(Duration(seconds: s)));
      }
      expect(segs.isNotEmpty, isTrue);
      expect(segs.every((l) => l == null), isTrue); // hep "—"
    });
  });
}
