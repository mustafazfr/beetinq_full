import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/contact/contact_config.dart';

/// İkincil contact scanner (Task 2.18).
///
/// `dchs_flutter_beacon` ranging yalnız iBeacon (manufacturerData) yayınlarını
/// yakalar. iOS cihazlar paket kısıtı nedeniyle iBeacon yayını yapamaz,
/// sadece **service UUID + local name** yayınlar. Bu scanner ikinci paralel
/// bir BLE tarayıcı ile o yayınları yakalar ve mevcut `ContactController`
/// encounter agregasyonunu besler.
///
/// Mevcut akışlar (iBeacon ranging, target beacon scan, trilateration vs.)
/// **hiç değiştirilmez**; bu scanner sadece "iOS yayını gören" paralel kaynak.
///
/// Kullanım:
/// ```dart
/// await scanner.start(
///   selfDeviceIdHash: deviceId,
///   onEncounter: (anonId, rssi, now) =>
///       contactController.onEncounterEvent(anonId, rssi, now),
/// );
/// // ...
/// await scanner.stop();
/// ```
class ContactBleScanner {
  static const _logTag = '[ContactBleScanner]';

  StreamSubscription<List<ScanResult>>? _sub;
  bool _running = false;
  String? _selfAnonId; // Kendi yayınımızı görürsek atlayalım.
  bool _contactEnabledCache = true;

  /// Settings opt-out toggle anında [contactEnabled] gönderir; sonraki scan
  /// event'leri controller'a düşürülmeden filtrelenir.
  void setContactEnabledCache(bool enabled) {
    _contactEnabledCache = enabled;
  }

  bool get isScanning => _running;

  /// Tarayıcıyı başlatır. selfDeviceIdHash verilirse kendi yayınımızı atlar
  /// (Android cihaz hem advertise hem scan yaparsa kendini görür → false-event).
  Future<bool> start({
    required String selfDeviceIdHash,
    required void Function(String anonId, int rssi, DateTime now) onEncounter,
  }) async {
    if (_running) {
      debugPrint('$_logTag zaten çalışıyor, atlandı.');
      return true;
    }

    try {
      // Self-filter için anonId'yi hesapla. Geçersiz hash'te scanner yine
      // çalışır, sadece self-filtering devre dışı kalır.
      try {
        _selfAnonId = decodeServiceUuidToAnonId(
          encodeAnonIdToServiceUuid(selfDeviceIdHash),
        );
      } catch (_) {
        _selfAnonId = null;
      }

      // BLE adapter destek + açık kontrolü. Açık değilse start yine çağrılır,
      // OS hata fırlatınca catch'e düşer; UI tarafı zaten ayrı bir Bluetooth
      // banner gösteriyor.
      final supported = await FlutterBluePlus.isSupported;
      if (!supported) {
        debugPrint('$_logTag BLE desteklenmiyor, scanner başlatılmadı.');
        return false;
      }

      // BUG FIX (iOS startup race): CoreBluetooth adaptörü uygulama açılışında
      // `.unknown` durumunda başlar; `poweredOn`'a geçmesi birkaç yüz ms sürer.
      // startScan'i adaptör hazır olmadan çağırırsak iOS
      // "CBManagerStateUnknown" PlatformException fırlatır ve scanner hiç
      // başlamaz. Bu yüzden adaptörün açık duruma geçmesini bekle. 5sn içinde
      // açılmazsa (BT gerçekten kapalı) scanner'ı atla — UI ayrıca Bluetooth
      // banner'ı gösteriyor, advertiser tarafı kendi içinde kuyruğa alıyor.
      if (FlutterBluePlus.adapterStateNow != BluetoothAdapterState.on) {
        try {
          await FlutterBluePlus.adapterState
              .firstWhere((s) => s == BluetoothAdapterState.on)
              .timeout(const Duration(seconds: 5));
        } on TimeoutException {
          debugPrint(
              '$_logTag BLE adaptörü 5sn içinde açılmadı (state='
              '${FlutterBluePlus.adapterStateNow}), scanner atlandı.');
          return false;
        }
      }

      // Stream listen önce, scan sonra: ilk paketleri kaçırmamak için sıralama.
      _sub = FlutterBluePlus.onScanResults.listen(
        (results) {
          if (!_contactEnabledCache) return;
          final now = DateTime.now();
          for (final r in results) {
            final adv = r.advertisementData;
            // CROSS-PLATFORM: anonId artık service UUID'ye gömülü (hem iOS hem
            // Android aynı yayını yapıyor). Yayınlanan service UUID'lerde
            // Beetinq prefix'i ara → anonId çıkar. (Eski localName yolu da
            // geriye uyum için kontrol edilir.)
            String? anonId;
            for (final g in adv.serviceUuids) {
              final decoded = decodeServiceUuidToAnonId(g.str);
              if (decoded != null) { anonId = decoded; break; }
            }
            // Geriye uyum: eski sürüm localName "BTQ-..." yaymışsa onu da yakala.
            anonId ??= decodeLocalNameToAnonId(adv.advName);
            if (anonId == null) continue;
            // Self-skip — kendi yayınımızı sayma.
            if (_selfAnonId != null && anonId == _selfAnonId) continue;
            // RSSI sanity (BLE -100..-1 dBm).
            if (r.rssi >= 0 || r.rssi < -100) continue;
            onEncounter(anonId, r.rssi, now);
          }
        },
        onError: (Object e, StackTrace st) {
          debugPrint('$_logTag scan stream hatası (devam): $e\n$st');
        },
      );

      // withServices KULLANILMIYOR: her cihaz CİHAZA ÖZEL service UUID (prefix
      // + anonId) yayıyor; sabit UUID ile filtrelenemez. Tüm BLE cihazları
      // taranır, callback'te prefix eşleşmesiyle Beetinq paketleri ayıklanır.
      // continuousUpdates=true: RSSI canlı güncellensin (her paket için event).
      await FlutterBluePlus.startScan(
        continuousUpdates: true,
        // androidScanMode default lowLatency — pil tüketimi yüksek ama saha
        // demosunda gerekli.
      );

      _running = true;
      debugPrint('$_logTag başladı (self=$_selfAnonId)');
      return true;
    } catch (e, st) {
      debugPrint('$_logTag start hatası: $e\n$st');
      await _safeStopScan();
      return false;
    }
  }

  Future<void> stop() async {
    if (!_running) return;
    await _safeStopScan();
    await _sub?.cancel();
    _sub = null;
    _running = false;
    debugPrint('$_logTag stop');
  }

  Future<void> _safeStopScan() async {
    try {
      if (FlutterBluePlus.isScanningNow) {
        await FlutterBluePlus.stopScan();
      }
    } catch (e) {
      debugPrint('$_logTag stopScan hatası: $e');
    }
  }
}

final contactBleScannerProvider = Provider<ContactBleScanner>(
  (ref) => ContactBleScanner(),
);
