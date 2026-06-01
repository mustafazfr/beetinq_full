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
}
