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
const int kContactEvictionSeconds = 300; // 5 dk

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
