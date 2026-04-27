# Beetinq Sense

Flutter mobil uygulaması: BLE beacon tabanlı iç mekân konumlandırma (fingerprinting + trilaterasyon) ve **cihazlar arası temas takibi**.

Backend: `../beetinq-backend` (NestJS + SQLite).

## Contact Tracing

### Nasıl Çalışır

Her telefon kendini iBeacon olarak yayınlar (`flutter_ble_peripheral` + Apple company ID `0x004C`). Cihaz kimliği:
- `deviceId` SHA-256 hash → ilk 4 byte → `major` (üst 16 bit) + `minor` (alt 16 bit) alanlarına yazılır.
- `decodeAnonId` ile okunabilir anon ID üretilir (`a1b2:c3d4` gibi).

Tek scanner (`dchs_flutter_beacon`), iki region: biri beacon UUID (konumlandırma), diğeri `CONTACT_TRACING_UUID` (temas). Ranging callback UUID'ye göre ayrıştırır:
- Beacon UUID → `_rows` (fingerprint + trilaterasyon akışı)
- Contact UUID → `ContactController.onEncounterEvent` (encounter aggregation)

### Eşikler (sabit, `core/contact/contact_config.dart`)
- `CONTACT_RSSI_THRESHOLD = -80 dBm` → ~2 metre
- `CONTACT_DURATION_SECONDS = 60` sn
- `CONTACT_EVICTION_SECONDS = 300` sn (5 dk'dır görülmeyen encounter RAM'den silinir)

Süre ≥ 60 sn **ve** son 60 sn ortalama RSSI > -80 dBm olduğunda encounter "contact" sayılır; `ApiService.sendContactEvent` ile backend'e tek kayıt gider (`POST /api/contacts`). İdempotency: `clientEventId` (uuid v4), offline kuyruk aynı retry mantığını kullanır (`offline_contact_queue_v1`).

### Platform Davranışı
- **Android**: Advertiser + scanner foreground service içinde sürekli çalışır.
- **iOS**: Scanner çalışır. **Advertiser çalışmıyor** — `flutter_ble_peripheral` 2.x iOS'ta `manufacturerData` alanını desteklemiyor, dolayısıyla iBeacon formatı craft edilemiyor. iOS cihazlar yalnızca başka Android cihazlardan gelen temas yayınlarını görür.
- Demo: **iki Android cihaz**.
- Lifecycle: iOS `paused/detached` → advertiser `stop()`, `resumed` → opt-in ise `start()`.

### Opt-Out (KVKK)
İki ayrı switch, `SharedPreferences` `_v1` anahtarları:
- `analysis_location_enabled_v1` → kapalıysa `startScanning()` atlanır; mevcut session `stop()` tarafından flush edilip gönderilir.
- `analysis_contact_enabled_v1` → kapalıysa advertiser durur, encounter map temizlenir, scanner contact UUID event'lerini düşürür (`_contactEnabledCache`).

### Endpoint Özeti
- `POST /api/contacts` — DTO: `deviceId`, `seenAnonId` (`^[0-9a-f]{4}:[0-9a-f]{4}$`), `firstSeenAt`, `lastSeenAt`, `durationSeconds`, `avgRssi` (-100..0), `sampleCount`, `clientEventId` (uuid v4, optional).
- `GET /api/stats/contacts?from=&to=` — `totalContacts`, `uniqueDevicesInvolved`, `avgDuration`, `topPairs[10]`.

### Bilinen Kısıtlar
- iOS advertiser yok (yukarıda).
- Major/minor encoding 32-bit slot; 2^32 ≈ 4 milyar çakışma alanı. Fuar ölçeğinde (1000–5000 kişi) pratikte çakışma yok, ama matematiksel olarak sıfır değil.
- Encounter aggregation RAM'de; uygulama kapanırsa aktif ama henüz eşiği aşmamış encounter'lar kaybolur. Raporlanmış contact'lar API'ye gittiği için kalıcı.

## iOS Background Ranging

`packages/dchs_flutter_beacon/` — upstream paketin yerel forku. iOS background ranging için iki müdahale ekli:

1. `CLLocationManager.allowsBackgroundLocationUpdates = YES` + `pausesLocationUpdatesAutomatically = NO`
2. Ranging başlarken `startUpdatingLocation`, dururken `stopUpdatingLocation`

Bu sayede iOS uygulamayı background'da suspend etmez; ranging callback'leri ekran kilitliyken ve başka uygulamada da gelmeye devam eder. **Killed (force-quit) durumunda çalışmaz** — Apple region-launch'ı için ek native kod gerekirdi, bitirme scope'u dışında.

**Kullanıcı şartı:** iOS'ta **Konum izni "Her zaman"** olmalı. App ilk açıldığında WhenInUse istenir; Always için kullanıcı Ayarlar → Beetinq → Konum → "Her zaman" seçmeli. UI'da bu uyarı yer alıyor.

**Trade-off:**
- Status bar'da sürekli mavi/kırmızı "konum kullanılıyor" göstergesi görünür. Bu Apple'ın UX standardıdır; *herhangi bir* location servisi aktifken app hangi hassasiyette olursa olsun gösterilir.
- GPS çipi **açılmıyor** — `kCLLocationAccuracyThreeKilometers` ayarı iOS'a "konum lazım ama düşük hassasiyet yeter" der; iOS GPS yerine cell tower + Wi-Fi triangulation kullanır. `startUpdatingLocation` çağrısının amacı konum almak değil, iOS'un app'i suspend etmemesini sağlamak (Apple background BLE app'leri için tek kanonik yol bu).
- Pil etkisi: BLE radyo background ranging için zaten açıktı, asıl maliyet o. Bu fork'tan eklenen cell/Wi-Fi positioning subsystem'i ihmal edilebilir.

## Çalıştırma

```bash
flutter pub get
flutter analyze
flutter run       # gerçek cihaz — simülatör BLE göremez
```

LAN IP'yi `lib/features/beacon/api_service.dart` `_lanIp` sabitinde set et.
HTTPS için `_useHttps = true` (backend tarafında `HTTPS_ENABLED=true`).
