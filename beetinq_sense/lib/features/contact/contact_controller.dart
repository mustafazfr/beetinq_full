import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
}

/// Contact tracing encounter aggregation (Task 1.5.5).
///
/// BeaconController ranging callback'i her contact UUID yayını için
/// [onEncounterEvent] çağırır. Controller:
/// 1. Encounter map'te anonId ile kayıt açar/günceller, RSSI örneği ekler.
/// 2. Süre ≥ 60s VE son 60s ortalama RSSI > -80 dBm VE daha önce raporlanmadı
///    → contact olarak işaretle + [_triggerContact] hook'unu çağır
///    (API send Task 1.5.7'de hook'a bağlanacak).
/// 3. [kContactEvictionSeconds] (5 dk) süredir görülmeyen encounter'ı sil.
///
/// RAM-only: uygulama kapanınca encounter map kaybolur. Raporlanmış contact'lar
/// API'ye gittiği için kalıcı; aktif ama henüz eşiği aşmamışlar gider — kabul
/// edilen davranış (kısa süreli karşılaşmalar zaten contact sayılmaz).
class ContactController extends Notifier<ContactState> {
  final Map<String, ContactEncounter> _encounters = {};

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

  /// BeaconController ranging callback'inden çağrılır.
  void onEncounterEvent(String anonId, int rssi, DateTime now) {
    final sample = RssiSample(rssi, now);
    final existing = _encounters[anonId];
    if (existing == null) {
      _encounters[anonId] = ContactEncounter(
        seenAnonId: anonId,
        firstSeen: now,
        lastSeen: now,
        samples: [sample],
      );
    } else {
      existing.lastSeen = now;
      existing.samples.add(sample);
      // Örneklem balonlaşmasını engelle: son 10 dk'lık worst-case ~600 örnek.
      // Aşarsa baştan kırp.
      const maxSamples = 600;
      if (existing.samples.length > maxSamples) {
        existing.samples.removeRange(
          0,
          existing.samples.length - maxSamples,
        );
      }
    }

    _evict(now);
    _maybeTriggerContact(_encounters[anonId]!);

    // UI state güncelle
    state = state.copyWith(activeEncounterCount: _encounters.length);
  }

  void _maybeTriggerContact(ContactEncounter e) {
    if (e.reportedAsContact) return;
    if (e.duration.inSeconds < kContactDurationSeconds) return;

    final recent = e.recentWindow(
      const Duration(seconds: kContactDurationSeconds),
    );
    // RSSI negatif; "> -80" sinyal güçlü demek. count > 0 zaten sağlanıyor.
    if (recent.avg <= kContactRssiThreshold) return;

    e.reportedAsContact = true;
    debugPrint(
      '✅ [ContactController] Contact tetiklendi: ${e.seenAnonId} '
      'süre=${e.duration.inSeconds}s avgRssi=${recent.avg.toStringAsFixed(1)}',
    );

    try {
      _triggerContact?.call(e);
    } catch (err, st) {
      debugPrint('⚠️ [ContactController] trigger callback hatası: $err\n$st');
    }

    state = state.copyWith(
      reportedContactCount: state.reportedContactCount + 1,
      lastContactAt: DateTime.now(),
    );
  }

  void _evict(DateTime now) {
    final threshold = Duration(seconds: kContactEvictionSeconds);
    _encounters.removeWhere(
      (_, e) => now.difference(e.lastSeen) > threshold,
    );
  }

  /// Test ve UI için (read-only snapshot).
  @visibleForTesting
  Map<String, ContactEncounter> get encounters => Map.unmodifiable(_encounters);

  /// Opt-out durumunda RAM'i temizle (Task 1.5.8'de settings_page çağırır).
  void reset() {
    _encounters.clear();
    state = const ContactState();
  }
}

final contactControllerProvider =
    NotifierProvider<ContactController, ContactState>(ContactController.new);
