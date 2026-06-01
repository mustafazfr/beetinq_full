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

/// Contact sayılma süresi (saniye). İki cihaz birbirini görüp bu süre kadar
/// yan yana durunca temas başlar. Kullanıcı isteği üzerine 60→10sn'ye çekildi
/// (demo + sahada hızlı feedback). Dwell time bu temas başlangıcından itibaren
/// hesaplanır.
const int kContactDurationSeconds = 10;

/// Eviction eşiği: bu süredir görülmeyen encounter RAM'den silinir.
/// Bu süre kadar uzak kalınca "temas koptu" sayılır; tekrar yaklaşınca YENİ
/// temas başlar.
///
/// Tasarım notu: Kullanıcı önce 10sn istedi ama sahada gözlemlendi ki
/// iki cihaz KIPIRDAMASA BİLE BLE doğası gereği 8-12sn'lik paket kayıpları
/// oluyor → 10sn eviction temas BÖLÜYORDU (her 10-30sn'de bir yeni kayıt).
/// 20sn dengeli: kısa flicker temas bölmüyor, gerçek ayrılış (20sn yokluk)
/// hâlâ algılanıyor. Başlama eşiği (kContactDurationSeconds=10sn) korundu.
const int kContactEvictionSeconds = 20;

/// Contact eşiği aşıldıktan sonra, encounter hâlâ aktifse her bu kadar
/// saniyede bir güncel (daha uzun) süreyle tekrar raporlanır. Aynı
/// clientEventId ile gider; backend upsert ile süreyi günceller — temas
/// devam ederken dashboard'daki süre canlı güncellenir. 60→15sn (eviction
/// 10sn olduğu için artık kısa temas senaryoları yaygın; 15sn iyi denge:
/// API trafiği patlamaz ama dashboard hızlı canlanır).
const int kContactReReportIntervalSeconds = 15;

/// Evict için RSSI eşiği — tetik eşiğinden (kContactRssiThreshold = -80) DAHA
/// DÜŞÜK (histerezis). Tetik "> -80"de olur; evict ancak sinyal "-85'in altına"
/// düşünce teması koparır. Aradaki 5 dB ölü bant, -80 sınırında gezinen cihazda
/// "tetikle → evict → yeni encounter → tekrar tetikle" flip-flop'unu (ve buna
/// bağlı reportedContactCount şişmesini) önler. Multi-agent bug-avı bulgusu.
const int kContactEvictRssiThreshold = -85;

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

// ──────────────────────────────────────────────────────────────────────────
// Cross-platform contact — anonId'yi SERVICE UUID'ye gömme (asıl çözüm).
//
// SORUN: flutter_ble_peripheral Android'de custom `localName` YAYAMIYOR
// (plugin Android dalında localName alanı hiç işlenmiyor; sadece iOS).
// Android iBeacon (manufacturerData) yayıyordu ama iPhone'un dchs ranging'i
// bunu güvenilir yakalamıyor. İki platform anonId'yi farklı alanda taşıyınca
// cross-platform kırılıyordu.
//
// ÇÖZÜM: anonId'yi HER İKİ platformun da yayabildiği + flutter_blue_plus'ın
// her iki platformda da okuyabildiği TEK ortak alana — service UUID'nin
// kendisine — göm. Her cihaz, ortak 24-hex prefix + kendi 8-hex anonId'sini
// içeren benzersiz bir 128-bit service UUID yayar:
//   DBB2D4FF-40B6-4902-8948-8E8A<anonId8>   (son 8 hex = deviceId ilk 8 hex)
// Scanner withServices ile sabit UUID'yi filtreleyemez (cihaza özel farklı);
// bunun yerine gördüğü tüm service UUID'lerde prefix eşleşmesi arar.
// ──────────────────────────────────────────────────────────────────────────

/// Ortak prefix: kContactTracingUuid'nin ilk 24 hex'i (dash'siz). Son 8 hex
/// her cihazda anonId ile değiştirilir.
String get kContactServiceUuidPrefix =>
    kContactTracingUuid.replaceAll('-', '').substring(0, 24).toLowerCase();

/// 32 hex → "8-4-4-4-12" UUID formatı.
String _formatUuid(String hex32) {
  final h = hex32.toLowerCase();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
      '${h.substring(16, 20)}-${h.substring(20)}';
}

/// deviceId hash → cihaza özel service UUID. Son 8 hex = deviceId ilk 8 hex.
String encodeAnonIdToServiceUuid(String deviceIdHash) {
  if (deviceIdHash.length < 8) {
    throw FormatException(
      'deviceIdHash en az 8 hex karakter olmalı, alınan: ${deviceIdHash.length}',
    );
  }
  final anon8 = deviceIdHash.substring(0, 8).toLowerCase();
  if (!RegExp(r'^[0-9a-f]{8}$').hasMatch(anon8)) {
    throw FormatException('deviceIdHash hex değil: $anon8');
  }
  return _formatUuid(kContactServiceUuidPrefix + anon8);
}

/// Taranan service UUID'den anonId çıkar. Beetinq prefix'i taşımıyorsa null.
/// "DBB2D4FF-40B6-4902-8948-8E8Ada9f52a4" → "da9f:52a4".
String? decodeServiceUuidToAnonId(String? uuid) {
  if (uuid == null) return null;
  final hex = uuid.replaceAll('-', '').toLowerCase();
  if (hex.length != 32) return null;
  if (!hex.startsWith(kContactServiceUuidPrefix)) return null;
  final anon8 = hex.substring(24);
  return '${anon8.substring(0, 4)}:${anon8.substring(4, 8)}';
}
