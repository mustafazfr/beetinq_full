# Beetinq Sense

Fuar ve etkinlik alanları için **BLE beacon tabanlı iç mekân konumlandırma** ve
**cihazlar arası temas takibi** sistemi. Ziyaretçilerin hangi standlarda ne kadar
vakit geçirdiğini ölçer, cihazlar arası yakınlaşmaları (networking) anonim olarak
kaydeder ve tümünü gerçek zamanlı bir yönetim panelinde görselleştirir.

> Bitirme projesi. Mobil uygulama (Flutter), backend (NestJS) ve web tabanlı
> yönetim paneli üç bileşenden oluşur.

---

## Özellikler

**Konumlandırma**
- BLE beacon tarama (`dchs_flutter_beacon`)
- RSSI sinyal filtreleme: Rolling Median + Kalman
- **Fingerprinting** (KNN, k=3, per-location-best eşleştirme + konum yapışkanlığı)
- **Trilaterasyon** (ağırlıklı Linear Least Squares + EWMA yumuşatma + outlier
  reddi + 2-beacon fallback)
- Stand bazlı dwell time (kalış süresi) — hysteresis + oturum kurtarma
- Offline-first ziyaret kuyruğu (idempotent `clientEventId`)

**Temas takibi (cross-platform)**
- Her cihaz, anonim kimliğini gömdüğü cihaza-özel bir **BLE service UUID** yayınlar
  (iOS + Android simetrik); karşı cihaz `flutter_blue_plus` ile yakalar
- Yakınlık eşiği: **RSSI > −80 dBm (~2 m)**, süre **≥ 10 sn**
- Mobilde RAM'de toplama → tek `ContactEvent` olarak backend'e
- Sunucu tarafında **temporal merge**: parçalı/çift-yönlü kayıtlar tek sürekli
  temasa birleşir (A↔B yön-bağımsız)

**Yönetim paneli** (gerçek zamanlı, WebSocket + polling fallback)
- Stand haritası (drag-drop ile beacon/stand yerleştirme)
- Heatmap, saatlik trafik, dwell dağılımı, konum kaynağı oranı
- Temas raporu: kim kiminle ne zaman temas etti + stand bazlı yakınlaşma
- PDF analiz raporu, CSV dışa aktarım
- Seçerek silme (kategori + tarih), sunucu/cihaz sıfırlama

**Gizlilik (KVKK/GDPR)**
- Tüm cihaz kimlikleri SHA-256 ile anonim (MAC/kişisel veri saklanmaz)
- Konum ve temas analizi ayrı ayrı kapatılabilir (opt-out)
- 14 gün otomatik veri retention (cron)

---

## Mimari

```
 ┌─────────────────┐   BLE    ┌─────────────────┐
 │  Mobil cihaz A  │◄────────►│  Mobil cihaz B  │   ← temas (service UUID)
 │  (Flutter)      │          │  (Flutter)      │
 └────────┬────────┘          └────────┬────────┘
          │ beacon tarama (RSSI)        │
          │ ┌──────────┐                │
          ├─┤ iBeacon  │ (Raspberry Pi / fiziksel beacon'lar)
          │ └──────────┘                │
          │  HTTP (visit + contact, offline kuyruk)
          ▼                             ▼
 ┌─────────────────────────────────────────────┐
 │  Backend (NestJS + TypeORM + SQLite)         │
 │  /api: visits · contacts · stands · beacons  │
 │        fingerprints · stats · admin          │
 │  WebSocket: data-changed push                │
 └───────────────────────┬─────────────────────┘
                         │ HTTP + WS
                         ▼
 ┌─────────────────────────────────────────────┐
 │  Yönetim paneli (public/index.html)          │
 │  harita · heatmap · grafikler · temas raporu │
 └─────────────────────────────────────────────┘
```

**Konumlandırma akışı:** beacon RSSI → median+Kalman filtre → fingerprint KNN
eşleşirse stand; yoksa trilaterasyon (LS) ile (x,y) → dwell time → backend.

---

## Teknoloji Yığını

| Katman | Teknoloji |
|---|---|
| Mobil | Flutter, Riverpod, dchs_flutter_beacon, flutter_ble_peripheral, flutter_blue_plus |
| Backend | NestJS 11, TypeORM 0.3, better-sqlite3, socket.io |
| Panel | Vanilla JS, Canvas, Chart.js, socket.io-client |
| Konumlandırma | KNN fingerprinting, weighted LS trilaterasyon, Kalman+median filtre |

---

## Kurulum

### Backend
```bash
cd beetinq-backend
npm install
npm run start:dev        # http://0.0.0.0:3000  (panel: http://localhost:3000)
```

### Mobil
```bash
cd beetinq_sense
flutter pub get
flutter run              # gerçek cihaz şart (simülatör BLE göremez)
# veya release APK:
flutter build apk --release
```
> iOS için Xcode'dan çalıştırılır. Temas takibi testi **iki fiziksel cihaz**
> gerektirir.

---

## Kullanım

1. Mobil uygulamayı aç → izinleri ver (Konum "Her zaman" + Bluetooth).
2. Beacon'ları ortama yerleştir; panelden haritaya konumlandır (drag-drop).
3. Her stand'da dur → "Konum Kaydet" ile fingerprint al (stand başına 2-3 kez).
4. Gez → panel canlı olarak konumu, dwell time'ı ve temasları gösterir.

---

## Test

```bash
# Mobil birim + simülasyon testleri
cd beetinq_sense && flutter test

# Backend birim testleri (jest)
cd beetinq-backend && npm test

# Backend uçtan uca senaryo testi (backend çalışırken)
./beetinq-backend/scripts/sandbox-test.sh

# Panel için mock veri
./beetinq-backend/scripts/seed-mock.sh
```

---

## Kapsam Dışı (Platform Sınırları)

- **iOS'ta arka planda temas takibi yok** — Apple üçüncü parti BLE advertising'i
  arka planda kısıtlar; iOS'ta uygulama açıkken çalışır, Android'de arka planda
  (foreground service) sürer.
- Bazı giriş seviyesi Android cihazlar BLE 5.0 extended advertising desteklemez;
  legacy advertising ile çözülür.
