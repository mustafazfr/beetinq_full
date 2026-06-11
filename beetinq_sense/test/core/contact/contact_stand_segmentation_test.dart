// Stand segmentasyonu — derin senaryo testleri (2026-06-11, demo öncesi).
//
// contact_gap_regression_test.dart temel akışları kilitler (commit, leave,
// stand→stand dwell). Bu dosya segmentasyonun DİĞER mekanizmalarla
// ETKİLEŞİMİNİ test eder — saha testi en zor kısımlar:
//   1) Dropout-resume bir stand segmentini BÖLMEMELİ (locationName +
//      clientEventId korunur; resume'un ilk paketi sahte leave tetiklememeli —
//      _lastAtLocation güncellemesi rotate'ten ÖNCE çalışır, sıralama kritik).
//   2) Raporlanmamış (eşik altı) encounter HİÇ segmentlenmez — ölü bant
//      RSSI'da (-78) standda 60sn durulsa bile stand yazılmaz.
//   3) Konum "A ↔ null" flap'i commit'i tetikleMEZ (bilinçli konservatif
//      davranış: yanlış stand yazmaktansa "—" kalır).
//   4) Birden çok peer bağımsız segmentlenir (biri commit olur, genç olan "—").
//   5) Rotate yeni clientEventId üretir ve eski segmenti ESKİ stand'ıyla
//      kapatır (backend'e son rapor eski segmentin kimliğiyle gider).

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

  /// t0'dan başlayıp [seconds] boyunca her saniye güçlü paket besler.
  DateTime feed(ContactController c, String id, DateTime from, int seconds,
      {int rssi = -60}) {
    for (int s = 0; s <= seconds; s++) {
      c.onEncounterEvent(id, rssi, from.add(Duration(seconds: s)));
    }
    return from.add(Duration(seconds: seconds));
  }

  test('1) dropout-resume stand segmentini BÖLMEZ (id + stand korunur)', () {
    final t0 = DateTime(2026, 6, 1, 12, 0, 0);
    ctrl.setContactTrigger((_) {});

    // Stand A'da 60sn temas: ~10sn'de "—" segmenti raporlanır (kayıt 1),
    // 45sn'de A'ya rotate olur, ~57sn'de stand segmenti raporlanır (kayıt 2).
    // NOT: rotasyonun sayacı 2 yapması TASARIM — her segment ayrı kayıttır.
    ctrl.onLocationChanged('Sergi-A', t0);
    final tEnd = feed(ctrl, 'aa:11', t0, 60);
    expect(ctrl.encounters['aa:11']?.locationName, 'Sergi-A');
    final cidBefore = ctrl.encounters['aa:11']?.clientEventId;
    final reportedBefore =
        container.read(contactControllerProvider).reportedContactCount;
    expect(reportedBefore, 2,
        reason: '"—" + stand segmenti = 2 ayrı kayıt (tasarım)');

    // 30sn TAM sessizlik (timeout 20sn'i aşar ama resume 45sn içinde),
    // telefon stand A'da kalmaya devam ediyor. Peer geri gelir.
    final tBack = tEnd.add(const Duration(seconds: 30));
    feed(ctrl, 'aa:11', tBack, 12);

    final e = ctrl.encounters['aa:11'];
    expect(e, isNotNull);
    // Aynı temasın devamı: clientEventId değişmemeli (backend tek kayda upsert).
    expect(e!.clientEventId, cidBefore,
        reason: 'resume yeni segment AÇMAMALI');
    // Stand etiketi korunmalı — resume\'un ilk paketi sahte leave tetiklememeli
    // (_lastAtLocation o pakette rotate\'ten ÖNCE tazelenir).
    expect(e.locationName, 'Sergi-A');
    expect(container.read(contactControllerProvider).reportedContactCount,
        reportedBefore, reason: 'sayaç şişmemeli');
  });

  test('2) ölü bant RSSI (-78): standda 60sn bile dursa segment YAZILMAZ', () {
    final t0 = DateTime(2026, 6, 1, 12, 0, 0);
    ctrl.setContactTrigger((_) {});

    ctrl.onLocationChanged('Sergi-A', t0);
    // -78: evict kapısının (-80) üstünde → encounter yaşar; tetik eşiğinin
    // (-75) altında → asla raporlanmaz. 60sn boyunca besle.
    feed(ctrl, 'bb:22', t0, 60, rssi: -78);

    final e = ctrl.encounters['bb:22'];
    expect(e, isNotNull, reason: 'ölü bantta encounter yaşamalı');
    expect(e!.reportedAsContact, isFalse);
    // Raporlanmamış temas segmentlenmez → stand asla yazılmaz.
    expect(e.locationName, isNull,
        reason: 'eşik altı temasa stand yazılmamalı');
  });

  test('3) konum "A ↔ null" flap\'i commit TETİKLEMEZ (konservatif)', () {
    final t0 = DateTime(2026, 6, 1, 12, 0, 0);
    ctrl.setContactTrigger((_) {});

    // Temas raporlu hâle gelsin ("—" segmenti).
    var t = feed(ctrl, 'cc:33', t0, 15);
    expect(ctrl.encounters['cc:33']?.reportedAsContact, isTrue);

    // Konum 5sn'de bir Sergi-A ↔ null flap'liyor (fingerprint sınırda) — 90sn.
    // Hiçbir A dilimi 45sn dwell'i doldurmaz → commit OLMAMALI.
    for (int cycle = 0; cycle < 18; cycle++) {
      ctrl.onLocationChanged(cycle.isEven ? 'Sergi-A' : null, t);
      for (int s = 0; s < 5; s++) {
        ctrl.onEncounterEvent('cc:33', -60, t.add(Duration(seconds: s)));
      }
      t = t.add(const Duration(seconds: 5));
    }
    expect(ctrl.encounters['cc:33']?.locationName, isNull,
        reason: 'flap sırasında yanlış stand commit edilmemeli');
  });

  test('4) iki peer bağımsız segmentlenir (kıdemli commit olur, genç "—" kalır)', () {
    final t0 = DateTime(2026, 6, 1, 12, 0, 0);
    ctrl.setContactTrigger((_) {});

    ctrl.onLocationChanged('Cafe', t0);
    // Peer-1 baştan beri yan yana; peer-2 45. saniyede geliyor.
    for (int s = 0; s <= 55; s++) {
      final now = t0.add(Duration(seconds: s));
      ctrl.onEncounterEvent('dd:44', -60, now);
      if (s >= 45) ctrl.onEncounterEvent('ee:55', -60, now);
    }

    // Peer-1: temas başlangıcı + stand girişi t0 → 45sn dwell doldu → Cafe.
    expect(ctrl.encounters['dd:44']?.locationName, 'Cafe');
    // Peer-2: çiftin KESİNTİSİZ teması t0+45'te başladı → dwell 10sn → "—".
    expect(ctrl.encounters['ee:55']?.locationName, isNull,
        reason: 'genç temasın dwell\'i kendi başlangıcından sayılmalı');
  });

  test('5) rotate: eski segment ESKİ kimlikle kapanır, yenisi YENİ clientEventId alır', () {
    final t0 = DateTime(2026, 6, 1, 12, 0, 0);
    final reports = <({String? loc, String? cid})>[];
    ctrl.setContactTrigger(
        (e) => reports.add((loc: e.locationName, cid: e.clientEventId)));

    ctrl.onLocationChanged('Sergi-A', t0);
    feed(ctrl, 'ff:66', t0, 50); // "—" raporlanır → 45sn'de A'ya rotate

    final e = ctrl.encounters['ff:66'];
    expect(e?.locationName, 'Sergi-A');

    // Rotasyon ANI: "—" segmentinin kapanış raporu eski (null-stand) kimlikle
    // gitmiş olmalı; yeni segmentin clientEventId'si farklı olmalı.
    final dashReports = reports.where((r) => r.loc == null).toList();
    expect(dashReports, isNotEmpty, reason: '"—" segmenti raporlanmış olmalı');
    final dashCid = dashReports.last.cid;
    expect(dashCid, isNotNull);
    expect(e!.clientEventId, isNot(dashCid),
        reason: 'stand segmenti YENİ clientEventId taşımalı (ayrı kayıt)');

    // Yeni segment raporlandıysa stand'lı rapor da yeni kimlikle gitmeli.
    final standReports = reports.where((r) => r.loc == 'Sergi-A').toList();
    if (standReports.isNotEmpty) {
      expect(standReports.last.cid, e.clientEventId);
    }
  });
}
