# Beetinq Sense — Görev Listesi

Bitirme savunması öncesi yapılması gerekenler, öncelik sırasıyla. Her görev küçük ve test edilebilir. Bitince `[x]` ile işaretle, altına 1 satır not düş.

**Çalışma prensibi:** Sırayla yap. Bir görevi bitirmeden sonrakine geçme. Her görev bittikten sonra `git commit` at.

---

## 🔴 Öncelik 1 — Temel Düzeltmeler

### 1.1 Önceki düzeltme paketini uygula
- [x] `beetinq_fix.zip` içindeki dosyaları mevcut koda entegre et (üzerine yaz + yeni eklenenler). — zip zaten elle uygulanmıştı, kontrol edildi.
- [x] Backend: `npm install @nestjs/throttler` çalıştır. — `^6.5.0` kurulu.
- [x] Mobil: `pubspec.yaml`'a `uuid: ^4.3.3` ekle, `flutter pub get`. — `4.5.3` lockta.
- [x] `beetinq-backend/database.sqlite` varsa sil (şema değişti). — test data korundu.
- [x] Backend derle, mobil analiz. — build temiz, analyze 1 pre-existing info.
- Commit: `fix: kritik veri kaybı + idempotency + beacon endpoint`

### 1.2 HTTPS + Opt-out (KVKK için şart)
- [x] Backend: Self-signed cert üret (geliştirme için). — `certs/dev-{key,cert}.pem`, SAN=localhost+127.0.0.1+172.20.10.13.
- [x] Backend: `main.ts` içinde env değişkeniyle HTTP/HTTPS seçimi. — `HTTPS_ENABLED=true`, tek port.
- [x] Mobil: `_baseUrl` HTTPS desteği (flag ile). — `_useHttps = false` sabiti.
- [x] Mobil: Ayarlar ekranı (`features/settings/settings_page.dart`).
- [x] Ayarlar: **İki ayrı switch** — "Konum Analizi" ve "Temas Analizi".
- [x] SharedPreferences anahtarları: `analysis_location_enabled_v1`, `analysis_contact_enabled_v1` (default `true`).
- [x] Switch'ler false'sa ilgili tarama/advertise çalışmasın. — location: `startScanning` guard; contact: advertiser stop + scanner `_contactEnabledCache` guard.
- Commit: `feat: HTTPS desteği + kullanıcı opt-out switch'leri`

---

## 🟣 Öncelik 1.5 — Contact Tracing (Ana Özellik)

**Önemli:** Bu görevler sıralı. Önceki bitmeden sonrakine geçme. Her adımı gerçek cihazda test et.

### 1.5.1 Altyapı ve paket kurulumu
- [x] Mobil: `flutter_ble_peripheral` paket. — **^1.2.7 bulunamadı, ^2.1.0'a bumplandı** (kullanıcı onayıyla).
- [x] Android manifest: `BLUETOOTH_ADVERTISE`.
- [x] iOS Info.plist: `NSBluetoothPeripheralUsageDescription` + mevcutlar korundu.
- [x] iOS `UIBackgroundModes`: `bluetooth-peripheral` eklendi (`location`, `bluetooth-central` korundu).
- [x] `flutter pub get`, `flutter analyze` → temiz (1 pre-existing info).
- Commit: `feat(contact): BLE peripheral paket kurulumu ve izinler`

### 1.5.2 Contact tracing sabitleri ve ID encoding
- [x] `lib/core/contact/contact_config.dart` — UUID sabiti + eşikler + encode/decode + tests (14/14).
- Commit: `feat(contact): UUID sabitleri ve deviceId encoding`

### 1.5.3 ContactAdvertiser servisi
- [x] `features/contact/contact_advertiser.dart` — Android-only iBeacon yayın (0x004C + mfg data).
- [x] iOS'ta `start()` no-op + log (paket kısıtı, kapsam notu eklendi).
- [x] Riverpod `contactAdvertiserProvider`.
- Commit: `feat(contact): ContactAdvertiser servisi`

### 1.5.4 Scanner region'ına contact UUID'yi ekle
- [x] `startDeviceRanging` içinde ikinci Region (`ContactTrace-<uuid>`) appenlendi.
- [x] Ranging callback UUID'ye göre ayrıştırıyor (target → `_rows`, contact → `_onContactBeacon`).
- [ ] Gerçek cihazda saha testi (1.5.10 kapsamında).
- Commit: `feat(contact): scanner'a contact UUID region ekle`

### 1.5.5 ContactEncounter modeli ve aggregation
- [x] `core/contact/contact_encounter.dart` — model + `recentWindow`.
- [x] `features/contact/contact_controller.dart` — Notifier, trigger hook, 5dk eviction, sample cap (600).
- [x] `contactControllerProvider`.
- Commit: `feat(contact): encounter aggregation ve contact tetikleme`

### 1.5.6 Backend: ContactEvent entity + endpoint
- [x] Entity + DTO + service (idempotent) + controller (`POST /api/contacts`) + module + app.module bağlantısı.
- [x] curl test: 201 insert, 201 duplicate=true, 400 bad format, 400 bad rssi, 400 bad time.
- [x] **Bonus fix**: pre-existing TypeORM `string | null` bug'ları (`visit.entity`, `beacon.entity`) `type: 'varchar'` ile düzeltildi — yoksa server hiç ayağa kalkmıyordu.
- Commit: `feat(backend): ContactEvent entity ve endpoint`

### 1.5.7 Mobil → Backend contact event gönderimi
- [x] `sendContactEvent`, `flushContactQueue`, `pendingContactCount`, `_postContact`.
- [x] Ayrı `_kContactQueueKey = 'offline_contact_queue_v1'`, `_contactQueueLock`.
- [x] Trigger hook `BeaconController.initSdk`'da wire edildi — `ApiService.sendContactEvent` çağrılıyor.
- Commit: `feat(contact): mobilden backend'e contact event gönderimi`

### 1.5.8 Lifecycle ve opt-out entegrasyonu
- [x] `didChangeAppLifecycleState` iOS pause/detached → stop, resumed → start (opt-in).
- [x] "Temas Analizi" switch advertiser toggle + `setContactEnabledCache` (scanner region sökmek yerine event-drop — daha az kırılgan).
- [x] `_ContactIndicator` widget: "Temas: X cihaz görüldü · N kayıtlı contact".
- Commit: `feat(contact): lifecycle + opt-out entegrasyonu`

### 1.5.9 Temas istatistikleri endpoint + panel
- [x] `GET /api/stats/contacts` — totalContacts, uniqueDevicesInvolved (d∪a set), avgDuration, topPairs[10].
- [x] Admin panele "Temas Raporu" kartı eklendi (`renderContactStats`).
- [ ] Force-directed graph (opsiyonel, vakit varsa).
- Commit: `feat(contact): temas istatistikleri endpoint ve panel`

### 1.5.10 Saha testi ve dokümantasyon
- [ ] İki gerçek **Android** cihazda (iOS advertiser yok — 1.5.3 notu) test et.
- [ ] Senaryolar:
  - İki Android yan yana 60+ saniye → backend'de 1 contact kaydı.
  - 5m uzakta 60+ saniye → RSSI zayıf, contact **oluşmamalı**.
  - Android A → Android B doğrulandıktan sonra roller değiştirilip tekrar test.
  - iOS cihaz varsa: sadece **scanner** rolünde, Android'den gelen yayını görebiliyor mu.
- [ ] Bulunan bug'ları "Bilinen Sorunlar"a yaz.
- [x] README.md'ye contact tracing bölümü eklendi.
- Commit: `docs(contact): saha testi sonuçları ve dokümantasyon`

---

## 🔴 Öncelik 2 — Diğer Rapor Gereklilikleri

### 2.1 Gerçek grid tabanlı heatmap
- [x] `simpleheat@0.4.0` CDN, offscreen canvas + drawImage compositing.
- [x] Mevcut radial gradient kaldırıldı; trilaterasyon + fingerprint noktaları beslenir.
- Commit: `feat: grid tabanlı yoğunluk ısı haritası`

### 2.2 14 Günlük Veri Retention (KVKK)
- [x] `@nestjs/schedule ^6.1.3` + `ScheduleModule.forRoot()`.
- [x] `CleanupService` `@Cron(EVERY_DAY_AT_3AM)` visit + contact delete, Logger log.
- [x] `RETENTION_DAYS` env ile override edilebilir.
- Commit: `feat: 14 günlük retention cron job`

### 2.3 PDF Rapor Export — TEKRAR AÇILDI (2026-05-19)
- [x] `pdfkit ^0.18.0` aktif kullanımda.
- [x] `GET /api/stats/report.pdf?from=&to=` — A4, 1 sayfa, 4 bölüm: özet, stand dwell tablosu, kaynak dağılımı, top temas çiftleri + KVKK notu.
- [x] Türkçe karakter ASCII downgrade (PDFKit Helvetica/Times WinAnsi encoding kısıtı; asset font yerine pratik çözüm).
- [x] Admin panel `📄 PDF Rapor` butonu (CSV İndir yanına).
- [x] Smoke test: status 200, 2.5KB valid PDF (PDF 1.3, 1 sayfa), date filter çalışıyor.
- Sia özetindeki "etkinlik sonrası analiz raporu (PDF/Panel)" maddesini kapatır.
- Commit: `feat(report): PDF rapor endpoint + dashboard butonu`

### 2.4 Tarih Aralığı Filtresi (Admin Panel)
- [x] Panel üstü date range input + Uygula/Temizle butonları.
- [x] `loadAll()` `dateQuery()` helper ile `?from=&to=` ISO format zenginleştirildi.
- Commit: `feat: panelde tarih filtresi`

### 2.5 Beacon Yönetimi (Admin Panel)
- [x] Sağ panele "BEACONS" kartı: form (UUID/major/minor/x/y/name/standId) + liste + sil.
- [x] Stand dropdown `stands` listesinden dinamik populate.
- [x] `POST /api/beacons` ve `DELETE /api/beacons/:id` smoke test geçti.
- Commit: `feat: admin panelde beacon yönetimi`

### 2.6 Beacon Kalibrasyonu — DENENDİ, GERİ ALINDI
- [x] Manuel ekleme formu kaldırıldı; beacon listesi sadece otomatik mobilden gelir.
- [x] Canvas'ta beacon drag-drop (mor üçgen, etiket: major/minor[·name]).
- [x] Backend: `UpdateBeaconDto` + `PATCH /api/beacons/:id`.
- [x] Heatmap toggle (showHeatmap state, localStorage).
- [~] Mesafe kısıtları + gradient descent: kullanıcı reddetti (mobilde x,y zaten girilirse overlap). Geri alındı 2.7'de.
- Commit: `feat: beacon kalibrasyonu - mesafe kısıtları + gradient descent` (sonra revert)

### 2.8 Gerçek Trilaterasyon (LS + EWMA)
- [x] `TrilaterationEngine.calculatePosition` — IDW centroid yerine **Linear Least Squares**. Reference olarak en güçlü RSSI'lı beacon seçilir, kuadratik terimler düşürülerek 2x2 normal denklem analitik invert ile çözülür.
- [x] EWMA (alpha=0.3) konum yumuşatma + `resetSmoothing()` API'si.
- [x] 3+ beacon zorunlu (matematiksel asgari). Daha azı varsa null → controller fingerprint fallback'ine düşer.
- [x] Singular durum (collinear beacon'lar, det≈0) ve NaN/Infinity koruması.
- [x] `flutter analyze` temiz.
- Saha testi notu: Pi beacon ile (0,0) referansta hata ölçümü tezde grafikle kıyaslanabilir.
- Commit: `feat: LS trilaterasyon + EWMA pozisyon yumuşatma`

### 2.7 Mobil-First Beacon/Stand Akışı
- [x] Admin paneldeki MESAFE KISITLARI panel + gradient descent kodu silindi (constraints state, fonksiyonlar, draw çizgileri).
- [x] Admin'de "Stand Ekle" formu kaldırıldı (`addingMode`, `addStandMode`, `saveStand` silindi). Stand'lar sadece mobilden gelir.
- [x] BEACONS panel'ine "🎯 Otomatik Yerleştir (Grid)" butonu eklendi (paralel PATCH).
- [x] Backend `CreateBeaconDto` x,y opsiyonel + `BeaconsService.nextAutoPosition` (1m grid, 5'lik satır).
- [x] Backend `CreateStandDto` x,y opsiyonel + `StandsService.create` idempotent (aynı isim → mevcut'u döndür) + auto-grid.
- [x] Mobil `ApiService.registerBeaconLocation` x,y nullable + 409→PATCH fallback.
- [x] Mobil `ApiService.registerStand` yeni metod (idempotent backend'e POST).
- [x] Mobil `BeaconController.saveCurrentFingerprint` sonrası `unawaited(_registerStandFromFingerprint)` — fingerprint=stand mental modeli.
- [x] Mobil `BeaconController.addBeaconLocation` imza değişti: `BeaconLocation` yerine düz parametreler, x,y nullable, POST sonrası `syncBeaconLocationsFromBackend`.
- [x] Mobil `_BeaconLocationsSheet` UI: x,y "opsiyonel" işaretiyle, boşsa hint "auto-grid".
- [x] Backend testi (curl): stand idempotent ✅, beacon auto-grid (1,1)→(2,1) ✅, 409 ✅, PATCH update ✅.
- [x] `flutter analyze` temiz (1 pre-existing info), `npm run build` temiz.
- Commit: `feat: mobil-first beacon/stand akışı + auto-grid yerleşim`

---

## 🟢 Öncelik 3 — Polish (Vakit Kalırsa)

### 3.1 Real-time WebSocket
- [x] **Yapıldı (2026-05-22)** — kullanıcı onayıyla scope'a alındı. socket.io gateway + admin panel hybrid (WS push + polling fallback). Detay aşağıda 2.20.

### 3.2 Error UX iyileştirme (Mobil)
- [x] `_friendlyError` — raw Exception mesajlarını Türkçe user-facing metinlere çevirir.
- [x] `_OfflineQueueBanner` — pendingCount > 0 ise sarı uyarı "X kayıt kuyrukta" (visit + contact toplamı, 5sn poll).

### 3.3 Pil optimizasyonu (Contact tracing)
- [x] `tuneScanLowPower` (scanPeriod=1100ms, between=5000ms) + normal mode swap.
- [x] `BeaconController` `_scanPowerTimer` dakikalık kontrol; `_lastBeaconActivity` target veya contact event'te güncelleniyor; 10dk threshold.

---

## 📝 Savunma Günü Kontrol Listesi

- [ ] Tüm senaryoların demo prova'sı yapıldı.
- [ ] Raspberry Pi beacon + iki test telefonu hazır.
- [ ] Backend lokal'de stabil.
- [ ] Bitirme tezinde **Scope ve Kısıtlamalar** bölümü var.
- [ ] iOS background advertising sorusu için hazır cevap mevcut.
- [ ] Contact tracing eşikleri (RSSI/süre) raporda gerekçeli yazılmış.
- [ ] KVKK maddelerinin her biri için kodda karşılığı gösterilebiliyor.

---

## 🐛 Bilinen Sorunlar / Sonra Bakılacaklar

- (örnek) Kalman filter ilk 3-4 event'te stabilize oluyor, ilk ziyaret yanlış olabilir — düşük öncelik.

---

## 🚀 2026-05-18 İyileştirme Paketi (Saha Testi Öncesi)

Tek seans kapsamlı incelemenin çıktıları. Bug yok; algoritma + dashboard zenginleştirmesi.

### 2.9 Trilateration İyileştirmeleri (Weighted LS + Outlier Rejection + Fallback)
- [x] `_weightedLeastSquares` — 1/d² ağırlık; uzak beacon LS'i artık bozmuyor.
- [x] Leave-one-out outlier rejection: 4+ beacon ile en sapan beacon atılıp tekrar çözülüyor.
- [x] 2-beacon weighted midpoint fallback — kenar/zayıf alanlarda konum hiç kesilmiyor.
- [x] Adaptive EWMA (α 0.15-0.6 jump'a göre rampa) — hareketsizde stabil, hareketle responsive.
- [x] Distance cap 50→80m (n=2 senaryosu için future-proof).
- Sandbox simulasyon (test/simulation/positioning_simulation_test.dart):
  - σ=3 dBm single-sample median: **1.10m → 0.77m** (%30 iyileşme)
  - σ=3 dBm 3 sample + EWMA median: 0.74m → **0.64m**
  - σ=6 dBm (gürültülü) p95: **10.36m → 3.71m** (%64 outlier rejection sayesinde)
  - Kenar simülasyonu p95: **2.97m → 2.02m** (%32)
- Commit: `feat(positioning): weighted LS + outlier rejection + 2-beacon fallback`

### 2.10 KNN Inverse-Distance Weighted Voting
- [x] Eşit majority vote yerine w=1/(score+0.5) ağırlıklı oy. Yakın aday daha çok söz hakkı.
- [x] Tie-break: ağırlık eşitse düşük toplam skor kazanır.
- Commit: `feat(fingerprint): KNN inverse-distance weighted voting`

### 2.11 RSSI Filter — Median Window 3→5
- [x] BeaconController'da `medianWindow=5` (spike'lara karşı daha sağlam, gecikme +~200ms ihmal).
- Commit: `feat(filter): RSSI median window 5'e yükseltildi`

### 2.12 Dashboard Genişletmesi
- [x] Backend yeni endpoint'ler:
  - `GET /api/stats/hourly` — saatlik trafik (24 kova)
  - `GET /api/stats/active?minutes=5` — şu an aktif cihaz
  - `GET /api/stats/sources` — fingerprint/trilateration/unknown dağılımı
  - `GET /api/stats/dwell-distribution` — 5 kova histogram
  - `GET /api/stats/visits.csv` — UTF-8 BOM + CRLF, Excel uyumlu
- [x] Heatmap aggregation: trilateration noktaları 0.5m grid'e quantize edilip count ile gruplanıyor (önceden count=1 sabitle gönderiliyordu).
- [x] Dashboard yenileme:
  - Chart.js (CDN) ile saatlik trafik bar chart, dwell histogram, kaynak doughnut chart
  - "Şu an aktif" canlı stat-card (pulse animasyonlu)
  - Toplam temas + benzersiz cihaz kartları
  - "📥 CSV İndir" butonu (date filter ile)
  - Contact network mini-graph (canvas force-directed, dependency-free)
  - Summary endpoint single-source-of-truth (önceden dwellData reduce'tan hesaplanıyordu)
- [x] Smoke test: tüm endpoint'ler 200, aggregate doğru (3 visit → 2 trilat aynı x,y → count=2).
- Commit: `feat(dashboard): saatlik trafik, aktif kullanıcı, kaynak dağılımı, contact graph, CSV export`

---

## 🚀 2026-05-19 Platform & Arka Plan Düzeltmeleri (Saha Testi Öncesi)

Temas takibi + arka plan davranışı kapsamlı incelendi; 5 düzeltme yapıldı.

### 2.13 Android FGS Tipi — `location|connectedDevice`
- [x] AndroidManifest `foregroundServiceType="location|connectedDevice"`.
- [x] `FOREGROUND_SERVICE_CONNECTED_DEVICE` izni eklendi.
- [x] `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` izni eklendi.
- Neden: Android 14+ FGS tipi yapılan işle eşleşmek zorunda. Contact tracing (BLUETOOTH_SCAN+ADVERTISE) sadece `location` ile başlatılırsa runtime exception fırlatır.

### 2.14 iOS Contact UUID Region Monitoring
- [x] `startIosMonitoring` artık contact UUID için de region monitoring kuruyor.
- Neden: iOS'ta ranging arka planda doğrudan çalışmaz; region entry/exit OS-level uyandırma ile penceresi açılır. Önceden sadece target UUID region monitoring vardı, contact background scan yapmıyordu.

### 2.15 ContactEncounter Timestamp-Aware
- [x] `RssiSample` model (rssi + ts).
- [x] `ContactEncounter.samples` (List<RssiSample>).
- [x] `recentWindow(Duration)` gerçek zaman penceresinden cut yapar — sample yoğunluğundan (scan period değişiminden) bağımsız.
- Neden: Önceki `sublist(n - window.inSeconds)` "1 sample/sn" kabulüne dayanıyordu; low-power scan modunda 5sn/sample, normal modda 300ms/sample → pencere yanlış kesiyordu.

### 2.16 Battery Optimization Muafiyeti Dialog (Android)
- [x] SettingsPage'e "Pil Optimizasyonu" kartı (Android-only). Yeşil/turuncu durum gösterimi + "Kapat" butonu.
- [x] `permission_handler` `Permission.ignoreBatteryOptimizations` ile request.
- Neden: Xiaomi/Huawei/Samsung agresif batarya optimizasyonu FGS'i sessizce öldürür. Saha günü kesintisiz tarama için kullanıcı muafiyet vermeli.

### 2.17 Server URL Runtime Ayarı
- [x] `SettingsPrefs.getServerBaseUrl/setServerBaseUrl` (anahtar `server_base_url_v1`).
- [x] `ApiService.loadServerUrl/setServerUrl` static cache + normalize ("192.168.1.42" → `http://192.168.1.42:3000/api`).
- [x] `main.dart` açılışta `WidgetsFlutterBinding.ensureInitialized()` + `ApiService.loadServerUrl()`.
- [x] SettingsPage "Sunucu Adresi" kartı: IP/URL input + Kaydet/Temizle butonları.
- Neden: Saha günü hotspot ↔ fakülte WiFi geçişinde LAN IP değişir. Önceden uygulama yeniden derlenmesi gerekiyordu; artık Ayarlar ekranından canlı değişiyor.

Commit: `feat(platform): Android 14 FGS tipi + iOS contact region monitoring + battery opt + server URL runtime`

### 2.18 Cross-platform Contact Tracing (iOS-iOS + iOS↔Android tam çift yönlü)
- [x] `flutter_blue_plus` paketi eklendi (^2.3.2). Mevcut `dchs_flutter_beacon` ve `flutter_ble_peripheral` paketleri korundu; bağımlılık çakışması yok.
- [x] `contact_config.dart`: `encodeAnonIdToLocalName` ("BTQ-a1b2c3d4"), `decodeLocalNameToAnonId` ("BTQ-deadbeef" → "dead:beef"), `kContactAdvLocalNamePrefix`.
- [x] `ContactAdvertiser` iOS dalı:
  - Önceden no-op'tu (`flutter_ble_peripheral` `manufacturerData` desteklemiyor).
  - Artık `AdvertiseData(serviceUuid, localName: "BTQ-xxxxxxxx")` yayınlar.
  - Android dalı = iBeacon (mevcut), dokunulmadı.
- [x] `ContactBleScanner` (yeni dosya): paralel BLE scanner.
  - `FlutterBluePlus.startScan(withServices: [Guid(kContactTracingUuid)])` ile filtreli scan.
  - `onScanResults` listener → `decodeLocalNameToAnonId` → `ContactController.onEncounterEvent`.
  - Self-skip (kendi yayınımızı atla), RSSI sanity, opt-out cache.
- [x] BeaconController entegrasyonu:
  - `initSdk`: contactEnabled ise advertiser + scanner birlikte başlat.
  - `stop`, `wipeAndReset`: scanner.stop ek.
  - `setContactEnabledCache`: scanner cache forward.
  - iOS lifecycle pause/resume: scanner stop/start ek.
- [x] SettingsPage contact toggle: scanner start/stop ek.
- [x] Test (10 yeni unit test): `encodeAnonIdToLocalName`, `decodeLocalNameToAnonId`, platform tutarlılığı (Android iBeacon ↔ iOS localName aynı anonId).
- [x] Toplam 80 test yeşil, analyze temiz (1 pre-existing info).

**Sonuç tablosu (önce vs sonra)**:
| Cihaz çifti | Önce | Sonra |
|---|---|---|
| Android ↔ Android | ✅ iBeacon | ✅ iBeacon (mevcut) |
| Android ↔ iOS | ⚠️ tek yönlü (iOS, Android'i görür) | ✅ çift yönlü (iBeacon + service UUID) |
| iOS ↔ iOS | ❌ hiç görmez | ✅ service UUID |

Commit: `feat(contact): cross-platform tracing — iOS service UUID + flutter_blue_plus scanner`

### 2.19 Otomatik Backend Keşfi (Subnet Scan)
- [x] Backend `DiscoveryController` — `GET /api/discover` → `{service: 'beetinq', version: 1, serverTime}`.
- [x] `@SkipThrottle({ short: true, long: true })` — named throttler bypass (parametresiz çalışmıyor; smoke test bulgusu: 100 paralel istekten 92'si 429 dönüyordu).
- [x] Mobil `ServerDiscovery` — NetworkInterface IPv4 listesinden /24 subnet çıkar, chunk=32 paralel `GET /api/discover`, ilk başarı kazanır (Completer pattern). Per-request timeout 500ms, overall timeout 6s.
- [x] `ApiService.tryAutoDiscover` — discovery + setServerUrl entegrasyon.
- [x] `main.dart` bootstrap: `hasCachedServerUrl` false ise `unawaited(tryAutoDiscover())` — uygulama açılışını bloke etmez.
- [x] SettingsPage "🔍 Otomatik Bul" butonu — manuel tetikleme, loading spinner, başarı/başarısız snackbar.
- [x] Smoke test: 254 paralel `/discover` → hepsi 200, latency ~0.4ms. Throttle bypass doğrulandı.

**Sebep**: Saha günü kullanıcı IP yazmasın diye. Subnet scan mDNS'e tercih edildi çünkü fakülte/kurumsal WiFi'lerde multicast genelde blocked. /24 = 254 IP × 32 paralel = ~1-2 saniyede biter.

Commit: `feat(discovery): otomatik backend keşfi (subnet scan + /api/discover)`

---

## 🔍 2026-05-22 Sunum Hazırlık İncelemesi (Sia PDF kontrolü + bug fix)

Sia proje özeti (PDF) ile mevcut kod baştan sona karşılaştırıldı, bug taraması yapıldı. Tüm ana özellikler mevcut çıktı; 3 düzeltme + 1 yeni özellik eklendi. Backend build/test, flutter analyze/test temiz; mock veri ile uçtan uca doğrulandı.

### 2.20 Gerçek Zamanlı WebSocket (Sia "WebSocket veri yayını" maddesi)
- [x] `@nestjs/websockets` + `@nestjs/platform-socket.io` kuruldu.
- [x] `events/events.gateway.ts` — `EventsGateway.emitDataChanged(kind)`; `events/events.module.ts` export.
- [x] `VisitsService` + `ContactsService` create/upsert sonrası `emitDataChanged` yayınlar (EventsModule import).
- [x] Admin panel: socket.io-client CDN + hybrid. WS bağlıyken anlık push + 30sn güvenlik polling; WS koparsa 5sn polling fallback. Header'da "● canlı (WS)" / "○ polling" göstergesi.
- [x] Test: socket.io handshake 200; client bağlanıp visit POST'unda `data-changed` event'i anında alındı.
- **Not:** Polling KALDIRILMADI — fallback olarak korundu (demo güvenliği). REST/stats endpoint'lerine dokunulmadı.
- Commit: `feat(realtime): WebSocket veri yayını + admin panel hybrid (polling fallback)`

### 2.21 Self-contact Guard (bug fix)
- [x] `BeaconController._selfContactAnonId` — initSdk'da kendi deviceId'sinden hesaplanır; `_onContactBeacon` kendi iBeacon yayınını görürse atlar.
- **Neden:** Bazı Android cihazlar kendi advertisement'ını ranging'de görüyor → cihaz kendisiyle "contact" kaydı oluşturabiliyordu. flutter_blue_plus scanner'da zaten self-skip vardı; iBeacon ranging tarafının karşılığı eklendi.
- Commit: `fix(contact): iBeacon ranging self-contact guard`

### 2.22 Uzun Temas Süresi Re-report (bug fix)
- [x] `kContactReReportIntervalSeconds=60`. `ContactEncounter`'a `clientEventId` (sabit) + `lastReportedAt`.
- [x] `ContactController._maybeTriggerContact` — ilk eşik aşımında gönderir, sonra her 60sn'de güncel süreyle AYNI clientEventId ile re-report (sayaç sadece ilk raporda artar).
- [x] `ApiService.sendContactEvent` — opsiyonel `clientEventId` parametresi (verilmezse v4 üretir, geriye uyumlu).
- [x] Backend `ContactsService.create` — duplicate clientEventId'de UPDATE (upsert): lastSeen/duration/avgRssi/sampleCount güncellenir, firstSeen sabit.
- [x] Mock test: aynı clientEventId 60s→300s re-report → tek kayıt, süre güncellendi (`updated:true`), yeni satır yok.
- **Neden:** Önceden contact bir kez tetiklenip ~60sn'de donuyordu; "kişi başı ortalama temas süresi" çıktısı (Sia beklenen çıktı) gerçek süreyi yansıtmıyordu.
- Commit: `fix(contact): uzun temas süresi re-report + backend upsert`

### 2.23 Temas Görselleştirme Düzeltmesi (kimlik normalizasyonu + matris)
- [x] **Kök sorun:** Panel temas grafiği her cihazı İKİ düğümle çiziyordu — "rapor eden" (deviceId tam hash) ve "görülen" (seenAnonId kısa). Aynı kişi iki düğüm → graf okunmuyordu, `uniqueDevicesInvolved` da şişiyordu (5 kişi → ~10).
- [x] Backend `StatsService.deviceIdToAnonId` — deviceId'nin ilk 4 byte'ı anonId'ye indirgenir (mobil encodeDeviceId ile aynı). `getContactStats` artık yönsüz çift (A↔B=B↔A) toplar; `participants` + `pairs` döndürür; `uniqueDevicesInvolved` GERÇEK kişi sayısı.
- [x] Admin panel: karışık force-directed graf kaldırıldı. Yerine **temas matrisi** (kişi×kişi, hücre=temas sayısı, renk=toplam süre, hover=detay) + **sıralı çift listesi** (süre + ~mesafe + RSSI).
- [x] Mock demo doğrulama: 5 kişi, 10 temas → matris doğru; Ali↔Veli yönsüz birleşti (×3, 635s). `topPairs` geriye uyumlu tutuldu (PDF raporu etkilenmedi).
- Commit: `fix(contact): kimlik normalizasyonu + panel temas matrisi (graf yerine)`

### 2.25 Temas Kaydına Konum (stand bazlı temas)
- [x] **Neden:** Temas kaydında konum yoktu → "kim kiminle" vardı ama "nerede" yoktu. Fuar organizatörü için "hangi stand networking hotspot / nerede kalabalık" bilgisi yoktu. Mobilde temas anındaki konum (detectedLocation) zaten biliniyordu ama kaydedilmiyordu.
- [x] Backend: `ContactEvent.locationName` (nullable) + DTO + service (insert & upsert) + `getContactStats.standBreakdown` (locationName→count/totalDuration, en çok temas önce).
- [x] Mobil: `ApiService.sendContactEvent` locationName param + `BeaconController` trigger'da `state.detectedLocation` geçirilir (konum yoksa null).
- [x] Panel: "Stand Bazlı Temas" yatay bar grafiği (networking hotspot). 5 kişi demo: Sony Standı 3 temas hotspot; 500 kişi: Sony 1076 temas.
- [x] Şema: nullable kolon, eski veri bozulmaz (synchronize ALTER). Backend build + 80 flutter test + 1 backend test temiz.
- Commit: `feat(contact): temas kaydına konum + stand bazlı temas grafiği`

### 2.26 UUID Gömme + Admin Stand Ekleme (kullanıcı isteği 2026-05-22)
- [x] **UUID gömüldü:** `kDefaultBeaconUuid = 'E2C56DB5-DFFB-48D2-B060-D0F5A71096E0'` (beacon_config). `initSdk` kayıtlı target yoksa varsayılanla başlatıp diske yazar. Yeni cihazda UUID elle girilmez, tarama otomatik başlar.
- [x] Mobil "Beacon Hedefi" UUID giriş alanı + `_uuidCtrl` kaldırıldı (beacon_page). `saveTarget` API'si duruyor (ileride lazım olursa).
- [x] **Admin panel "Stand Ekle" formu geri geldi** (2.7'de kaldırılmıştı — kullanıcı geri istedi). İsim input + "+ Stand Ekle" butonu → `POST /api/stands` (idempotent, auto-grid). Konum boş → 1m grid, sonra haritadan sürükle. Mobil fingerprint→stand akışı da korundu (ikisi birlikte).
- [x] Karar değişikliği: Stand'lar artık HEM mobilden (fingerprint) HEM admin panelden elle eklenebilir. Beacon'lar yine sadece mobilden otomatik.
- [x] flutter analyze temiz (1 pre-existing), 80 test geçti. Stand ekleme curl: 201 + idempotent doğrulandı.
- Commit: `feat: beacon UUID gömüldü + admin panel elle stand ekleme`

### 2.27 Fingerprint Senkronu (radio map paylaşımı) + DB temizliği
- [x] **Sorun:** Beacon koordinatları tüm cihazlara senkronlanıyordu ama fingerprint'ler değil — sadece stand İSMİ backend'e gidiyordu, RSSI parmak izi telefonda kalıyordu. Diğer cihazlar fingerprint konumlama yapamıyordu.
- [x] Backend: `Fingerprint` entity (`rssiMap` simple-json) + DTO + service (upsert) + `POST/GET/DELETE /api/fingerprints` + module + app.module + AdminService.wipe + AdminModule.
- [x] Mobil: `ApiService.pushFingerprint/fetchFingerprints/deleteFingerprint`. `saveCurrentFingerprint` → rssiMap'i de push eder. `syncFingerprintsFromBackend` (id dedup, backend authoritative) initSdk'da çağrılır. `removeFingerprint` backend'den de siler.
- [x] Sonuç: bir cihaz mekânı haritalar (her stand'da "Konum Kaydet"), diğer tüm cihazlar açılışta indirip kullanır. Beacon senkronuyla simetrik.
- [x] Test: curl push/upsert/GET/400/wipe ✅; backend build + 1 test ✅; flutter analyze (1 pre-existing) + 80 test ✅.
- Commit: `feat: fingerprint (radio map) backend senkronu — cihazlar arası paylaşım`

### DB Temizliği (2026-05-23)
- [x] `database.sqlite` temizlendi (eski 29 Nisan visit'leri + benim 21 Mayıs smoke test contact'ı + kapı/duvar stand). Yedek alındı: `database.sqlite.bak-*`. visit 4→0, contact 2→0, stand 2→0.
- Sebep: Kullanıcı panelde eski test verisini gerçek sanıp karıştı; temiz başlangıç için.

### 2.28 Saha Günü Kolaylıkları (kullanıcı isteği 2026-05-23)
- [x] **Sunucu bağlantı göstergesi** (`_ConnectionIndicator`): ana ekranda yeşil/kırmızı "Sunucu bağlı/bağlanılamıyor" + URL, 10 sn'de bir `/api/discover` ping. Bağlantı yoksa "Tekrar Dene" butonu. `ApiService.pingServer` + `currentBaseUrl`. Saha günü #1 sorunun (bağlantı) anında teşhisi.
- [x] **Manuel "Senkronize Et" butonu** (AppBar 🔄): `syncAllFromBackend` → fingerprint + beacon koordinatlarını çeker, snackbar "X konum · Y beacon". Restart beklemeden güncelleme.
- [x] **Periyodik otomatik sync** (`_syncTimer`, 30 sn): ikinci telefon, birinci telefon haritalarken canlı güncellensin. initSdk başlatır; stop/wipe/dispose temizler.
- [x] flutter analyze (1 pre-existing) + 80 test ✅.
- Commit: `feat(mobil): sunucu bağlantı göstergesi + manuel/periyodik senkron`

### Sia PDF eşleştirme sonucu
- ✅ Tüm ana özellikler mevcut. Bilinçli sapmalar (tezde "Kapsam ve Kısıtlamalar"da belirtilecek):
  - **Anlık gönderim** (PDF "günde birkaç kez") — gerçek zamanlı panel için bilinçli. KORUNDU.
  - **At-rest şifreleme yok** — veri zaten anonim hash; HTTPS altyapısı kodda mevcut (`_useHttps` flag), saha testinde HTTP. Tezde gerekçelenecek.
  - **iOS arka plan contact** — Apple kısıtı (kapsam notu).
- ⚠️ Demo notu: ilk smoke test sırasında gerçek `database.sqlite`'a 1 örnek contact yazıldı — demo öncesi admin panel "🗑️ Tüm Veriyi Sil" ile temizlenebilir.
