/// Contact Tracing sabitleri ve yardımcı fonksiyonlar.
///
/// Her telefon kendini iBeacon olarak yayınlar; beacon UUID'sinden ayrı
/// bir UUID kullanılır ki tarayıcı iki akışı ayırabilsin.
///
/// Cihaz kimliği (SHA-256 hash, 64 hex char) major+minor alanlarına
/// sığdırılır: hash'in ilk 4 byte'ı → 32 bit → major (üst 16) + minor (alt 16).
/// Collision: 2^32 ≈ 4 milyar slot, fuar ölçeğinde ihmal edilebilir.
library;

/// Contact tracing için global UUID. Beacon UUID'sinden farklı olmalı.
const String kContactTracingUuid = 'DBB2D4FF-40B6-4902-8948-8E8A642CDA0C';

/// "Contact" sayılma eşiği: RSSI değeri bu değerden büyükse (yani sinyal
/// yeterince güçlüyse — dBm negatif, -80 > -90) ve süre aşıldıysa contact
/// kabul edilir. -80 dBm ≈ 2 metre.
const int kContactRssiThreshold = -80;

/// Contact sayılma süresi (saniye). Bu süre kadar sürekli (veya birbirini
/// takip eden örneklerle) görülen encounter, contact olarak raporlanır.
const int kContactDurationSeconds = 60;

/// Eviction eşiği: bu süredir görülmeyen encounter RAM'den silinir.
/// Bu süre kadar uzak kalınca "temas koptu" sayılır; tekrar yaklaşınca YENİ
/// temas başlar. Demo/test kolaylığı için 90sn'ye çekildi (eskiden 5 dk idi;
/// "5 dakika uzak kalmak" test için çok uzundu). Gerçek bir temasın kısa BLE
/// kesintisinde bölünmemesi için 90sn yeterli pay bırakıyor.
const int kContactEvictionSeconds = 90;

/// Contact eşiği aşıldıktan sonra, encounter hâlâ aktifse her bu kadar
/// saniyede bir güncel (daha uzun) süreyle tekrar raporlanır. Aynı
/// clientEventId ile gider; backend upsert ile süreyi günceller. Böylece
/// uzun temasların GERÇEK süresi kaydedilir — yoksa eşik bir kez aşılıp
/// contact ~60sn olarak donuyordu ve "ortalama temas süresi" çıktısı yanıltıcı
/// oluyordu.
const int kContactReReportIntervalSeconds = 60;

/// Device hash'ini (hex string) iBeacon major/minor çiftine çevirir.
///
/// Hash SHA-256 hex (64 char). İlk 8 char (4 byte) alınır, 32-bit unsigned
/// int olarak parse edilir; üst 16 bit → major, alt 16 bit → minor.
///
/// Throws [FormatException] hash geçersizse.
({int major, int minor}) encodeDeviceId(String deviceIdHash) {
  if (deviceIdHash.length < 8) {
    throw FormatException(
      'deviceIdHash en az 8 hex karakter olmalı, alınan uzunluk: '
      '${deviceIdHash.length}',
    );
  }
  final prefix = deviceIdHash.substring(0, 8);
  final value = int.tryParse(prefix, radix: 16);
  if (value == null) {
    throw FormatException('deviceIdHash hex olarak parse edilemedi: $prefix');
  }
  // 32-bit unsigned; int.parse hex ile zaten pozitif döner.
  final major = (value >> 16) & 0xFFFF;
  final minor = value & 0xFFFF;
  return (major: major, minor: minor);
}

/// major/minor → okunabilir anon ID (örn. "a1b2:c3d4").
///
/// Aynı cihazı encounter aggregation'da anahtar olarak kullanmak için
/// stabil ve kısa bir string üretir. İki cihaz aynı major/minor üretirse
/// (collision) aynı anon ID'yi paylaşırlar — kabul edilen risk.
String decodeAnonId(int major, int minor) {
  final m = major.toRadixString(16).padLeft(4, '0');
  final n = minor.toRadixString(16).padLeft(4, '0');
  return '$m:$n';
}

// ──────────────────────────────────────────────────────────────────────────
// Cross-platform contact advertisement helpers (Task 2.18).
//
// iOS `flutter_ble_peripheral` 2.x `manufacturerData` desteklemediği için
// iBeacon yayını yapamaz. Bunun yerine **service UUID + local name** yayını
// kullanılır. anonId aynı 32-bit slot'ta tutulur ama major/minor yerine
// localName alanına ASCII olarak gömülür ("BTQ-a1b2c3d4").
//
// Scanner tarafı her iki yolu da yakalar:
// - iBeacon (Android yayını)   → dchs_flutter_beacon ranging → mevcut akış
// - service UUID (iOS yayını)  → flutter_blue_plus scanner   → yeni akış
//
// `kContactTracingUuid` her iki format'ta da aynı; sadece yayın çerçevesi
// (frame layout) farklı.
// ──────────────────────────────────────────────────────────────────────────

/// iOS service-UUID yayınlarında local name prefix'i. Scanner bu prefix ile
/// Beetinq paketlerini diğer BLE cihazlardan ayırır.
const String kContactAdvLocalNamePrefix = 'BTQ-';

/// 64 karakter hex deviceId hash → "BTQ-a1b2c3d4" local name.
/// (İlk 4 byte iBeacon encode'unda da kullanılan slot.)
String encodeAnonIdToLocalName(String deviceIdHash) {
  if (deviceIdHash.length < 8) {
    throw FormatException(
      'deviceIdHash en az 8 hex karakter olmalı, alınan: ${deviceIdHash.length}',
    );
  }
  final prefix = deviceIdHash.substring(0, 8).toLowerCase();
  // Validate hex
  if (!RegExp(r'^[0-9a-f]{8}$').hasMatch(prefix)) {
    throw FormatException('deviceIdHash hex değil: $prefix');
  }
  return '$kContactAdvLocalNamePrefix$prefix';
}

/// Scanner'da yakalanan local name'i anon ID'ye çevirir.
/// Geçersiz format → null.
///
/// "BTQ-a1b2c3d4" → "a1b2:c3d4" (decodeAnonId(0xA1B2, 0xC3D4) ile eşdeğer).
String? decodeLocalNameToAnonId(String? localName) {
  if (localName == null) return null;
  if (!localName.startsWith(kContactAdvLocalNamePrefix)) return null;
  final hex = localName.substring(kContactAdvLocalNamePrefix.length);
  if (!RegExp(r'^[0-9a-f]{8}$', caseSensitive: false).hasMatch(hex)) return null;
  final lo = hex.toLowerCase();
  return '${lo.substring(0, 4)}:${lo.substring(4, 8)}';
}
