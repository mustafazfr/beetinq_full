import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/contact/contact_config.dart';
import '../../core/contact/contact_encounter.dart';

/// UI için Notifier state'i. Encounter map'i RAM'de controller'da tutulur;
/// state sadece sayaçları expose eder (UI frame-rebuild'lerinde ağırlık yaratmasın).
class ContactState {
  final int activeEncounterCount;     // Şu an görünen (henüz evict olmamış) cihaz sayısı
  final int reportedContactCount;     // Bu oturumda contact eşiği aşıp raporlanan cihaz sayısı
  final DateTime? lastContactAt;
  /// KALİBRASYON: en son görülen Beetinq yayınının HAM RSSI'si (dBm) — zayıf
  /// paketler (encounter oluşturmayanlar) dahil. Saha testinde eşiği gerçek
  /// mesafe-RSSI ile ayarlamak için UI'da canlı gösterilir.
  final int? nearestRssi;

  const ContactState({
    this.activeEncounterCount = 0,
    this.reportedContactCount = 0,
    this.lastContactAt,
    this.nearestRssi,
  });

  ContactState copyWith({
    int? activeEncounterCount,
    int? reportedContactCount,
    DateTime? lastContactAt,
    int? nearestRssi,
  }) {
    return ContactState(
      activeEncounterCount: activeEncounterCount ?? this.activeEncounterCount,
      reportedContactCount: reportedContactCount ?? this.reportedContactCount,
      lastContactAt: lastContactAt ?? this.lastContactAt,
      nearestRssi: nearestRssi ?? this.nearestRssi,
    );
  }

  // PERF FIX: değer-eşitliği. onEncounterEvent HER BLE paketinde
  // (flutter_blue_plus continuousUpdates + lowLatency) state çağırıyor.
  // Eşitlik override'ı olmadan Riverpod her paketi "değişiklik" sayıp
  // beacon_page'i baştan çiziyordu. Sayaçlar+RSSI aynıysa yeni state == eski → notify yok.
  @override
  bool operator ==(Object other) =>
      other is ContactState &&
      other.activeEncounterCount == activeEncounterCount &&
      other.reportedContactCount == reportedContactCount &&
      other.lastContactAt == lastContactAt &&
      other.nearestRssi == nearestRssi;

  @override
  int get hashCode =>
      Object.hash(activeEncounterCount, reportedContactCount, lastContactAt, nearestRssi);
}

/// Contact tracing encounter aggregation (Task 1.5.5).
///
/// BeaconController scanner callback'i her contact yayını için
/// [onEncounterEvent] çağırır. Controller:
/// 1. Encounter map'te anonId ile kayıt açar/günceller, RSSI örneği ekler.
/// 2. Süre ≥ [kContactDurationSeconds] (10s) VE son 10s ortalama RSSI > -80 dBm
///    VE daha önce raporlanmadı → contact olarak işaretle + [_triggerContact]
///    hook'unu çağır (ApiService.sendContactEvent).
/// 3. [kContactEvictionSeconds] (20s) süredir görülmeyen VEYA sinyali
///    [kContactEvictRssiThreshold] (-85) altına düşen encounter'ı sil.
///
/// RAM-only: uygulama kapanınca encounter map kaybolur. Raporlanmış contact'lar
/// API'ye gittiği için kalıcı; aktif ama henüz eşiği aşmamışlar gider — kabul
/// edilen davranış (kısa süreli karşılaşmalar zaten contact sayılmaz).
class ContactController extends Notifier<ContactState> {
  final Map<String, ContactEncounter> _encounters = {};

  /// Dropout resume hafızası (kullanıcı isteği + bug-avı): ZAMAN AŞIMIYLA
  /// (paket gelmedi → iPhone dropout) evict edilen encounter'lar buraya taşınır.
  /// [kContactResumeSeconds] içinde aynı cihaz tekrar görünürse aynı temas
  /// devam ettirilir (yeni clientEventId açılmaz → ekran sayacı ve backend kaydı
  /// şişmez). RSSI ile (gerçek uzaklaşma) evict edilenler buraya KONMAZ.
  final Map<String, ContactEncounter> _resumable = {};
  static const _uuid = Uuid();

  /// Raporlayan telefonun o anki stand'ı (fingerprint/trilaterasyon). Stand
  /// segmentasyonu (bkz. kStandDwellSeconds) bu değeri ve [_currentStandSince]'i
  /// kullanır. Yeni encounter'lar "—" (null) doğar; stand ancak yeterince
  /// duruşla onaylanınca yazılır.
  String? _currentLocationName;

  /// [_currentLocationName]'in en son ne zaman bu değere geçtiği. Stand'da
  /// "yeterince kalındı mı" (commit) kararı buna göre.
  DateTime? _currentStandSince;

  /// Telefonun her stand'ı EN SON ne zaman gördüğü (konum == stand iken gelen
  /// son paket zamanı). Stand'dan AYRILMA (leave) kararı buna göre verilir.
  /// BUG FIX (2026-06-10): leave eskiden [_currentStandSince]'e bakıyordu;
  /// konum "B ↔ null" flap'leyince (fingerprint↔trilaterasyon geçişi) since
  /// her flap'te sıfırlanıp leave HİÇ tetiklenmiyordu → segment, ayrılınan
  /// stand'a süresiz yapışık kalıyordu. Bu harita flap'lerden etkilenmez.
  final Map<String, DateTime> _lastAtLocation = {};

  /// Çiftin KESİNTİSİZ temasının başlangıcı. Segment rotasyonunda ve dropout
  /// resume'da KORUNUR, yalnız yepyeni karşılaşmada sıfırlanır. Stand dwell
  /// hesabı segment'in firstSeen'i yerine bunu kullanır — yoksa stand→stand
  /// geçişte 45sn dwell fiilen 60sn'e şişiyordu (15sn leave grace + yeni
  /// segmentin sıfırlanan saati).
  final Map<String, DateTime> _pairContactSince = {};

  /// Eşik aşıldığında çağrılır (Task 1.5.7 — ApiService.sendContactEvent).
  /// Set edilmediyse no-op; encounter yine reportedAsContact=true olarak
  /// işaretlenir (duplicate tetikleme olmasın).
  void Function(ContactEncounter encounter)? _triggerContact;

  @override
  ContactState build() {
    // KALP ATIŞI (2026-06-11 saha bulgusu): _evict yalnız paket gelince
    // çalışıyordu; tam RF sessizliğinde (2 cihazlı demo — karşı taraf BT
    // kapattı/uzaklaştı) encounter'lar ve UI sayacı donuk kalıyordu
    // ("Temas: 1 cihaz" hayaleti). 5sn'lik tick, paket gelmese de mevcut
    // timeout/stale/RSSI evict'leri işletir. Karar mantığı DEĞİŞMEDİ —
    // sadece _evict artık düzenli çalışıyor.
    final heartbeat =
        Timer.periodic(const Duration(seconds: 5), (_) => _onHeartbeat());
    ref.onDispose(heartbeat.cancel);
    return const ContactState();
  }

  void _onHeartbeat() {
    if (_encounters.isEmpty && _resumable.isEmpty) return;
    _evict(DateTime.now());
    if (state.activeEncounterCount != _encounters.length) {
      state = ContactState(
        activeEncounterCount: _encounters.length,
        reportedContactCount: state.reportedContactCount,
        lastContactAt: state.lastContactAt,
        // Aktif encounter kalmadıysa bayat "en güçlü" göstergesini de temizle.
        nearestRssi: _encounters.isEmpty ? null : state.nearestRssi,
      );
    }
  }

  /// 1.5.7 veya test kodu tarafından set edilir.
  void setContactTrigger(void Function(ContactEncounter)? cb) {
    _triggerContact = cb;
  }

  /// Raporlayan telefonun konumu değişince BeaconController çağırır.
  ///
  /// TASARIM (kullanıcı kararı 2026-06-07 — stand segmentasyonu): Konum
  /// değişimi teması anında bölmez. Bunun yerine "yeterince duruş" (commit) ve
  /// "ayrılma" (leave) [_maybeSegmentRotate] içinde değerlendirilir. Burada
  /// yalnızca güncel stand + ne zamandan beri orada olunduğu güncellenir.
  /// Anlık fingerprint zıplaması [_currentStandSince]'i sıfırlar → kStandDwell
  /// dolmadan commit olmaz, yani jitter teması parçalamaz.
  void onLocationChanged(String? newLocation, [DateTime? now]) {
    if (newLocation == _currentLocationName) return;
    _currentLocationName = newLocation;
    _currentStandSince = now ?? DateTime.now();
  }

  /// BeaconController scanner callback'inden çağrılır.
  void onEncounterEvent(String anonId, int rssi, DateTime now) {
    final sample = RssiSample(rssi, now);

    // Stand segmentasyonu (leave kararı) için: telefonun şu anki standını
    // "en son bu anda gördüm" olarak işaretle (bkz. _lastAtLocation).
    final curLoc = _currentLocationName;
    if (curLoc != null) _lastAtLocation[curLoc] = now;

    // SAHA BULGUSU (2026-06-07): ZAYIF paket bir encounter'ı OLUŞTURMAZ/SÜRDÜRMEZ.
    // Uzaktaki telefon (ör. -96 dBm) seyrek paketlerle gelince: 10sn'de 3 örnek
    // dolmadığı için RSSI-evict tetiklenmiyor ama o seyrek paket 20sn timeout'u
    // sürekli sıfırlayıp encounter'ı SONSUZA dek canlı tutuyordu ("uzakta bile
    // temas kaybolmuyor"). Çözüm: evict eşiğinden (-82) zayıf paketleri encounter
    // güncellemesine SOKMA → uzak telefon 20sn'de timeout ile temizlenir. (Ham
    // RSSI yine aşağıda nearestRssi ile UI'da gösterilir; kalibrasyon bozulmaz.)
    final strongEnough = rssi > kContactEvictRssiThreshold;
    if (strongEnough) {
      var existing = _encounters[anonId];
      // BUG FIX (2026-06-10 — sahte uzun temas): _evict YALNIZ paket gelince
      // çalışır; ortamda hiç Beetinq paketi yokken (2 cihazlı demo!) timeout
      // hiç işlemez. Cihaz uzun sessizlikten dönünce ilk pakette lastSeen
      // güncellenip evict'i atlatıyor, boşluk temasın içine yutuluyordu:
      // 5sn'lik raporlanmamış görüşme + 10dk sessizlik + dönüş → sahte
      // "600sn temas" tetikleniyordu (regresyon testi: contact_gap_regression).
      // Çözüm: boşluk timeout'u aşıyorsa kaçırılmış evict'i ŞİMDİ uygula —
      // encounter resumable havuzuna taşınır, aşağıdaki (A) bloğu MEVCUT
      // resume kurallarıyla karar verir (≤45sn → aynı temas, >45sn → yeni).
      if (existing != null &&
          now.difference(existing.lastSeen).inSeconds >
              kContactEvictionSeconds) {
        _resumable[anonId] = existing;
        _encounters.remove(anonId);
        existing = null;
      }
      if (existing == null) {
        // (A) DROPOUT RESUME: bu cihaz yakın geçmişte ZAMAN AŞIMIYLA silinmiş mi?
        // Resume penceresi içindeyse aynı teması sürdür: clientEventId + firstSeen
        // + reportedAsContact KORUNUR → backend tek kayda upsert, sayaç artmaz.
        final resumed = _resumable.remove(anonId);
        final gapSec =
            resumed == null ? -1 : now.difference(resumed.lastSeen).inSeconds;
        if (resumed != null && gapSec <= kContactResumeSeconds) {
          resumed.lastSeen = now;
          _appendSample(resumed, sample);
          _encounters[anonId] = resumed;
          // Resume aynı temasın devamı → kesintisiz başlangıç korunur (kayıt
          // yoksa — ör. uygulama içi sıfırlama sonrası — firstSeen'e düş).
          _pairContactSince.putIfAbsent(anonId, () => resumed.firstSeen);
          debugPrint(
            '🔁 [ContactController] Dropout resume: $anonId (boşluk=${gapSec}s, '
            'aynı temas — sayaç artmaz)',
          );
        } else {
          _encounters[anonId] = ContactEncounter(
            seenAnonId: anonId,
            firstSeen: now,
            lastSeen: now,
            clientEventId: _uuid.v4(),
            samples: [sample],
            // Stand segmentasyonu: her temas "—" (boş stand) başlar; stand ancak
            // o standda yeterince durulunca (_maybeSegmentRotate) yazılır.
            locationName: null,
          );
          // Yepyeni karşılaşma → çiftin kesintisiz temas saati şimdi başlar.
          _pairContactSince[anonId] = now;
        }
      } else {
        existing.lastSeen = now;
        _appendSample(existing, sample);
      }
    }

    _evict(now);
    // Stand segmentasyonu: yeterince duruş → stand'lı yeni segment; ayrılış → "—".
    _maybeSegmentRotate(anonId, now);
    // BUG FIX (multi-agent bug-avı): _evict bu anonId'yi SİLMİŞ olabilir (süre
    // dolmuş + sinyal -85 altına düşmüş encounter). Eskiden sonraki satır
    // `_encounters[anonId]!` ile null-check crash ediyordu — üstelik bu çağrı
    // scanner callback'inde senkron, yani o tarama paketi hiç işlenmiyordu.
    // Evict edilmişse zaten "çok zayıf/uzak" demektir; tetiklenecek bir şey yok.
    final current = _encounters[anonId];
    if (current != null) _maybeTriggerContact(current);

    // KALİBRASYON: en son gelen ham RSSI'yı UI'da canlı göster (zayıf -96 dahil,
    // encounter oluşmasa bile) → saha testinde yakın/uzak değerleri okuyup eşik
    // ayarlanabilsin. copyWith null'ı temizleyemediği için doğrudan kuruyoruz.
    state = ContactState(
      activeEncounterCount: _encounters.length,
      reportedContactCount: state.reportedContactCount,
      lastContactAt: state.lastContactAt,
      nearestRssi: rssi,
    );
  }

  void _maybeTriggerContact(ContactEncounter e) {
    if (e.duration.inSeconds < kContactDurationSeconds) return;

    final recent = e.recentWindow(
      const Duration(seconds: kContactDurationSeconds),
    );
    // (C) MEDYAN ile karar: iPhone'un tek-tük zayıf/sıçramalı RSSI okuması tetik
    // kararını sallamasın. RSSI negatif; medyan "> -80" ise sinyal güçlü
    // (~2m içinde) demek. count > 0 zaten sağlanıyor.
    if (recent.median <= kContactRssiThreshold) return;

    // İlk tetikleme mi yoksa periyodik re-report mı?
    final firstReport = !e.reportedAsContact;
    final shouldReReport = e.reportedAsContact &&
        e.lastReportedAt != null &&
        e.lastSeen.difference(e.lastReportedAt!).inSeconds >=
            kContactReReportIntervalSeconds;

    // İlk değil ve re-report zamanı da gelmediyse çık (gereksiz API trafiği yok).
    if (!firstReport && !shouldReReport) return;

    e.reportedAsContact = true;
    e.lastReportedAt = e.lastSeen;
    debugPrint(
      '✅ [ContactController] Contact ${firstReport ? "tetiklendi" : "güncellendi"}: '
      '${e.seenAnonId} süre=${e.duration.inSeconds}s '
      'medianRssi=${recent.median.toStringAsFixed(1)} avgRssi=${recent.avg.toStringAsFixed(1)}',
    );

    try {
      // Aynı clientEventId ile gider → backend upsert ile süreyi günceller.
      _triggerContact?.call(e);
    } catch (err, st) {
      debugPrint('⚠️ [ContactController] trigger callback hatası: $err\n$st');
    }

    // Sayaç sadece ilk raporda artar — re-report aynı contact'ın güncellemesi.
    if (firstReport) {
      state = state.copyWith(
        reportedContactCount: state.reportedContactCount + 1,
        // Olayın gerçek zamanı (sentetik-zamanlı testlerle de tutarlı).
        lastContactAt: e.lastSeen,
      );
    }
  }

  /// Stand segmentasyonu (kullanıcı tasarımı). Aktif (raporlanmış) bir temasta:
  /// - "—" segmentindeyken çift aynı standda kStandDwellSeconds boyunca birlikte
  ///   kaldıysa → o ANDAN itibaren stand'lı YENİ segment başlat (eski "—" kapanır).
  /// - Stand segmentindeyken o stand'dan kStandLeaveGraceSeconds süre ayrı
  ///   kalındıysa → "—" segmentine dön (yeni segment).
  /// Eşik altı (henüz raporlanmamış) kısa görüşmeler segmentlenmez.
  void _maybeSegmentRotate(String anonId, DateTime now) {
    final e = _encounters[anonId];
    if (e == null || !e.reportedAsContact) return;
    final loc = _currentLocationName;
    final since = _currentStandSince;

    if (e.locationName == null) {
      // "—" → stand commit: konum bir stand VE orada yeterince durulduysa.
      if (loc != null && since != null) {
        // Duruş, çiftin BİRLİKTE o standda olduğu andan sayılır (max(stand'a
        // giriş, temasın başlangıcı)). BUG FIX (2026-06-10): "temasın
        // başlangıcı" SEGMENT'in firstSeen'i değil, çiftin KESİNTİSİZ temas
        // başlangıcı (_pairContactSince) — segment rotate firstSeen'i
        // sıfırladığı için stand→stand geçişte 45sn dwell fiilen 60sn oluyordu.
        final together = _pairContactSince[anonId] ?? e.firstSeen;
        final dwellStart = since.isAfter(together) ? since : together;
        if (now.difference(dwellStart).inSeconds >= kStandDwellSeconds) {
          _rotateSegment(anonId, newStand: loc, now: now);
        }
      }
    } else {
      // stand → "—": telefon bu stand'ı kStandLeaveGraceSeconds süredir
      // GÖRMEDİYSE ayrılış say. BUG FIX (2026-06-10 — stand yapışması):
      // eskiden karar _currentStandSince'e bakıyordu; konum "B ↔ null"
      // flap'leyince since her flap'te sıfırlanıp leave hiç tetiklenmiyordu.
      // _lastAtLocation ara konum flap'lerinden etkilenmez: stand'a dönülürse
      // damga tazelenir (rotate yok), dönülmezse grace dolunca "—"e geçilir.
      final lastAt = _lastAtLocation[e.locationName];
      if (lastAt == null ||
          now.difference(lastAt).inSeconds >= kStandLeaveGraceSeconds) {
        _rotateSegment(anonId, newStand: null, now: now);
      }
    }
  }

  /// Mevcut segmenti kapatıp (raporlanmışsa son kez gönderip) aynı kişi için
  /// yeni clientEventId'li bir segment başlatır. Sınır = ŞİMDİ: eski segment
  /// şu ana kadar olan süreyi alır, yeni segment şu andan başlar (kullanıcı
  /// tasarımı: "ilk N saniye '—', sonra stand'lı ayrı contact").
  void _rotateSegment(String anonId, {required String? newStand, required DateTime now}) {
    final old = _encounters[anonId];
    if (old == null) return;
    if (old.reportedAsContact) {
      try {
        _triggerContact?.call(old); // eski segmenti kapat (backend kaydı kesinleşsin)
      } catch (err, st) {
        debugPrint('⚠️ [ContactController] segment kapatma hatası: $err\n$st');
      }
    }
    // Tohum örneği: GÜNCEL sinyali temsil etsin diye son pencerenin ortalaması
    // (tüm geçmişin ortalaması dakikalarca bayat olabilir; pencere boşsa düş).
    final seed = old.recentWindow(
      const Duration(seconds: kContactDurationSeconds),
    );
    _encounters[anonId] = ContactEncounter(
      seenAnonId: anonId,
      firstSeen: now,
      lastSeen: now,
      clientEventId: _uuid.v4(),
      samples: [
        RssiSample((seed.count > 0 ? seed.avg : old.avgRssi).round(), now),
      ],
      locationName: newStand,
    );
    debugPrint(
      '🔀 [ContactController] Segment: ${old.locationName ?? "—"} → '
      '${newStand ?? "—"} ($anonId)',
    );
  }

  void _evict(DateTime now) {
    final timeout = Duration(seconds: kContactEvictionSeconds);
    final window = const Duration(seconds: kContactDurationSeconds);

    final timedOut = <String>[]; // dropout → resume edilebilir
    final departed = <String>[]; // RSSI uzaklaşma → gerçek ayrılış
    _encounters.forEach((id, e) {
      // 1) ZAMAN AŞIMI: bu kadar süredir hiç paket gelmedi. Çoğu zaman gerçek
      //    ayrılış değil, BLE/iPhone dropout. Silinir AMA _resumable'a taşınır →
      //    kContactResumeSeconds içinde tekrar görünürse aynı temas devam eder.
      if (now.difference(e.lastSeen) > timeout) {
        timedOut.add(id);
        return;
      }
      // 2) BAYATLAMA (saha bulgusu 2026-06-07): temas raporlandı ama son GÜÇLÜ
      //    okumadan (re-report) kContactStaleSeconds'tan uzun süre geçti. Cihaz
      //    hâlâ zayıf görülüyor olabilir (duvar arkasından sızan sinyal) ama
      //    fiilen uzaklaştı → gerçek ayrılış say, bitir (resume EDİLMEZ). Bu
      //    olmadan 15 dk önce biten temas, yeniden yaklaşınca aynı clientEventId
      //    ile re-report edilip eski kaydı "devam ediyor" diye güncelliyordu.
      if (e.reportedAsContact &&
          e.lastReportedAt != null &&
          now.difference(e.lastReportedAt!).inSeconds > kContactStaleSeconds) {
        departed.add(id);
        return;
      }
      // 3) RSSI (uzaklaşma): pencere dolu VE yeterli örnek (medyan anlamlı olsun)
      //    VE MEDYAN sinyal evict eşiğinin (-85) altındaysa → GERÇEK ayrılış.
      //    Silinir ve resume EDİLMEZ (sonraki görüşme yeni temas / yeni stand →
      //    stand-bazlı temas sayımı korunur). Medyan + min örnek: iPhone'un
      //    tek-tük zayıf okuması teması yanlışlıkla koparmasın (histerezis -85).
      if (e.duration >= window) {
        final recent = e.recentWindow(window);
        if (recent.count >= kContactMinSamplesForRssiEvict &&
            recent.median <= kContactEvictRssiThreshold) {
          departed.add(id);
        }
      }
    });

    for (final id in timedOut) {
      _resumable[id] = _encounters.remove(id)!; // dropout → resume havuzuna
    }
    for (final id in departed) {
      _encounters.remove(id); // gerçek ayrılış → resume YOK
      // Kesintisiz temas burada biter; sonraki karşılaşma yeni temastır.
      _pairContactSince.remove(id);
    }

    // Bayatlamış resume kayıtlarını temizle: resume penceresinden uzun süredir
    // dönmediyse cihaz gerçekten gitti, RAM'i şişirmesin.
    _resumable.removeWhere(
      (_, e) => now.difference(e.lastSeen).inSeconds > kContactResumeSeconds,
    );
  }

  void _appendSample(ContactEncounter e, RssiSample s) {
    e.samples.add(s);
    // Örneklem balonlaşmasını engelle: worst-case ~600 örnek. Aşarsa baştan kırp
    // (recentWindow zaman penceresiyle çalıştığı için eski örnekleri atmak güvenli).
    const maxSamples = 600;
    if (e.samples.length > maxSamples) {
      e.samples.removeRange(0, e.samples.length - maxSamples);
    }
  }

  /// Test ve UI için (read-only snapshot).
  @visibleForTesting
  Map<String, ContactEncounter> get encounters => Map.unmodifiable(_encounters);

  /// Opt-out durumunda RAM'i temizle (Task 1.5.8'de settings_page çağırır).
  void reset() {
    _encounters.clear();
    _resumable.clear();
    _lastAtLocation.clear();
    _pairContactSince.clear();
    state = const ContactState();
  }
}

final contactControllerProvider =
    NotifierProvider<ContactController, ContactState>(ContactController.new);
