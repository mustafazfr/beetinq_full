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

  const ContactState({
    this.activeEncounterCount = 0,
    this.reportedContactCount = 0,
    this.lastContactAt,
  });

  ContactState copyWith({
    int? activeEncounterCount,
    int? reportedContactCount,
    DateTime? lastContactAt,
  }) {
    return ContactState(
      activeEncounterCount: activeEncounterCount ?? this.activeEncounterCount,
      reportedContactCount: reportedContactCount ?? this.reportedContactCount,
      lastContactAt: lastContactAt ?? this.lastContactAt,
    );
  }

  // PERF FIX: değer-eşitliği. onEncounterEvent HER BLE paketinde
  // (flutter_blue_plus continuousUpdates + lowLatency) state=copyWith çağırıyor.
  // Eşitlik override'ı olmadan Riverpod her paketi "değişiklik" sayıp
  // beacon_page'i baştan çiziyordu (kalabalık fuarda saniyede onlarca rebuild +
  // pil). Sayaçlar aynıysa artık yeni state == eski state → notify yok.
  @override
  bool operator ==(Object other) =>
      other is ContactState &&
      other.activeEncounterCount == activeEncounterCount &&
      other.reportedContactCount == reportedContactCount &&
      other.lastContactAt == lastContactAt;

  @override
  int get hashCode =>
      Object.hash(activeEncounterCount, reportedContactCount, lastContactAt);
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

  /// Raporlayan telefonun o anki stand'ı. BeaconController konum değişince
  /// [onLocationChanged] ile günceller. Yeni encounter'lar bu konumla doğar;
  /// per-stand temas için kullanılır.
  String? _currentLocationName;

  /// Eşik aşıldığında çağrılır (Task 1.5.7 — ApiService.sendContactEvent).
  /// Set edilmediyse no-op; encounter yine reportedAsContact=true olarak
  /// işaretlenir (duplicate tetikleme olmasın).
  void Function(ContactEncounter encounter)? _triggerContact;

  @override
  ContactState build() {
    return const ContactState();
  }

  /// 1.5.7 veya test kodu tarafından set edilir.
  void setContactTrigger(void Function(ContactEncounter)? cb) {
    _triggerContact = cb;
  }

  /// Raporlayan telefonun konumu değişince BeaconController çağırır.
  ///
  /// TASARIM (kullanıcı kararı): Contact artık "tek sürekli temas" — konum
  /// değişimi teması BÖLMEZ (per-stand rotate KALDIRILDI). Sebep: fingerprint
  /// kararsız bir kurulumda konum sürekli zıplıyordu (masa↔1-2↔televizyon) ve
  /// her zıplama yeni contact açıp dashboard'ı 8 parçaya bölüyordu. Artık
  /// yalnızca _currentLocationName güncellenir; bu, BUNDAN SONRA başlayan YENİ
  /// encounter'lara "temasın başladığı stand" olarak atanır. Mevcut
  /// encounter'ların locationName'i (ilk görüldükleri stand) sabit kalır.
  void onLocationChanged(String? newLocation) {
    if (newLocation == _currentLocationName) return;
    _currentLocationName = newLocation;
  }

  /// BeaconController scanner callback'inden çağrılır.
  void onEncounterEvent(String anonId, int rssi, DateTime now) {
    final sample = RssiSample(rssi, now);
    final existing = _encounters[anonId];
    if (existing == null) {
      // (A) DROPOUT RESUME: bu cihaz yakın geçmişte ZAMAN AŞIMIYLA silinmiş mi?
      // (iPhone'da BLE paket kaybı sık → encounter dropout'ta evict oluyordu →
      // tekrar görününce yeni clientEventId açılıp "sürekli contact" sayılıyordu.)
      // Resume penceresi içindeyse aynı teması sürdür: clientEventId + firstSeen
      // + reportedAsContact KORUNUR → backend tek kayda upsert, sayaç artmaz.
      final resumed = _resumable.remove(anonId);
      final gapSec =
          resumed == null ? -1 : now.difference(resumed.lastSeen).inSeconds;
      if (resumed != null && gapSec <= kContactResumeSeconds) {
        resumed.lastSeen = now;
        _appendSample(resumed, sample);
        _encounters[anonId] = resumed;
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
          locationName: _currentLocationName,
        );
      }
    } else {
      existing.lastSeen = now;
      _appendSample(existing, sample);
    }

    _evict(now);
    // BUG FIX (multi-agent bug-avı): _evict bu anonId'yi SİLMİŞ olabilir (süre
    // dolmuş + sinyal -85 altına düşmüş encounter). Eskiden sonraki satır
    // `_encounters[anonId]!` ile null-check crash ediyordu — üstelik bu çağrı
    // scanner callback'inde senkron, yani o tarama paketi hiç işlenmiyordu.
    // Evict edilmişse zaten "çok zayıf/uzak" demektir; tetiklenecek bir şey yok.
    final current = _encounters[anonId];
    if (current != null) _maybeTriggerContact(current);

    // UI state güncelle
    state = state.copyWith(activeEncounterCount: _encounters.length);
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
        lastContactAt: DateTime.now(),
      );
    }
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
      // 2) RSSI (uzaklaşma): pencere dolu VE yeterli örnek (medyan anlamlı olsun)
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
    state = const ContactState();
  }
}

final contactControllerProvider =
    NotifierProvider<ContactController, ContactState>(ContactController.new);
