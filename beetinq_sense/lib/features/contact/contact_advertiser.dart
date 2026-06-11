import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_ble_peripheral/flutter_ble_peripheral.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/contact/contact_config.dart';

/// Cihazı BLE üzerinden yayınlayan servis. Contact tracing akışının
/// "advertiser" tarafı.
///
/// Platform farkı (Task 2.18 — cross-platform contact tracing):
/// - **Android**: iBeacon format (manufacturerId=0x004C + mfg data). Mevcut
///   `dchs_flutter_beacon` ranging tarafından yakalanır.
/// - **iOS**: `flutter_ble_peripheral` 2.x `manufacturerData` alanını
///   desteklemediği için iBeacon yapılamaz. Bunun yerine **service UUID +
///   local name** yayını yapılır ("BTQ-<8hex>"). Yeni `ContactBleScanner`
///   (flutter_blue_plus) tarafından yakalanır.
///
/// **Önemli**: iOS yayınında `manufacturerId` set edilmez. iOS'ta paket bunu
/// reddederse advertise hiç başlamaz; bizim yaptığımız "sadece service UUID
/// + localName" pattern desteklenen kombinasyon.
class ContactAdvertiser {
  final FlutterBlePeripheral _peripheral = FlutterBlePeripheral();
  bool _isRunning = false;
  /// Son start denemesinin sonuç state'i — UI'da hata sebebini göstermek için.
  /// null = henüz denenmedi; granted/ready = başarılı; denied/unsupported/
  /// turnedOff vs. = hata sebebi.
  BluetoothPeripheralState? _lastStartState;
  String? _lastErrorMessage;

  /// UI hata mesajı için: state'ten okunabilir Türkçe açıklama üretir.
  String? get lastError {
    if (_lastErrorMessage != null) return _lastErrorMessage;
    final s = _lastStartState;
    if (s == null) return null;
    switch (s) {
      case BluetoothPeripheralState.denied:
        return 'Bluetooth yayın izni reddedildi';
      case BluetoothPeripheralState.permanentlyDenied:
        return 'Yayın izni kalıcı reddedildi — Ayarlardan elle ver';
      case BluetoothPeripheralState.restricted:
        return 'OS yayını kısıtladı (ebeveyn kontrolü vb.)';
      case BluetoothPeripheralState.unsupported:
        return 'Bu cihaz BLE yayın (peripheral) DESTEKLEMİYOR';
      case BluetoothPeripheralState.turnedOff:
        return 'Bluetooth kapalı';
      default:
        return null; // granted/ready/unknown/limited → hata değil
    }
  }


  /// Advertise başlatır. deviceIdHash (SHA-256 hex) Android'de major/minor'e,
  /// iOS'ta local name'e encode edilir.
  ///
  /// Dönüş: true = başladı, false = atlandı/başarısız.
  Future<bool> start(String deviceIdHash) async {
    if (_isRunning) {
      debugPrint('⏩ [ContactAdvertiser] zaten çalışıyor, atlandı.');
      return true;
    }

    _lastErrorMessage = null;
    try {
      // Donanım desteği kontrolü (Samsung A serisi gibi bazı cihazlar BLE
      // peripheral/advertising DESTEKLEMEZ → start hep başarısız olur, kod
      // fix'i yok). Bunu net mesajla raporla.
      final supported = await _peripheral.isSupported;
      if (!supported) {
        _lastErrorMessage = 'Bu cihaz BLE yayın (peripheral) DESTEKLEMİYOR';
        debugPrint('❌ [ContactAdvertiser] $_lastErrorMessage');
        return false;
      }

      final perm = await _peripheral.hasPermission();
      if (perm != BluetoothPeripheralState.granted) {
        final req = await _peripheral.requestPermission();
        if (req != BluetoothPeripheralState.granted) {
          _lastStartState = req;
          debugPrint('❌ [ContactAdvertiser] advertise izni alınmadı: $req');
          return false;
        }
      }

      // CROSS-PLATFORM ÇÖZÜM: anonId'yi service UUID'ye gömüp HER İKİ
      // platformda da AYNI yayını yap (simetrik). Eski asimetrik tasarım
      // (Android iBeacon / iOS localName) cross-platform'da çalışmıyordu:
      // - flutter_ble_peripheral Android'de localName yayamıyor.
      // - iPhone'un dchs ranging'i Android iBeacon'unu güvenilir yakalamıyor.
      // Artık her cihaz cihaza-özel service UUID (prefix + anonId) yayar;
      // flutter_blue_plus (iki platformda da çalışan kanıtlı yol) prefix
      // eşleşmesiyle yakalar. iOS foreground'da service UUID yayar (CoreBluetooth
      // destekli tek kombinasyon), Android legacy advertising ile yayar (18 byte
      // sığar). manufacturerData/localName/iBeacon TAMAMEN bırakıldı.
      if (!Platform.isAndroid && !Platform.isIOS) {
        debugPrint('🔕 [ContactAdvertiser] desteklenmeyen platform, atlandı.');
        return false;
      }
      final serviceUuid = encodeAnonIdToServiceUuid(deviceIdHash);
      final data = AdvertiseData(
        serviceUuid: serviceUuid,
        includeDeviceName: false,
      );
      debugPrint(
        '📡 [ContactAdvertiser] service UUID yayını (${Platform.isIOS ? "iOS" : "Android"}) '
        'uuid=$serviceUuid',
      );

      // BUG FIX (kritik — Galaxy A20s vb.): flutter_ble_peripheral'in default
      // AdvertiseSettings.advertiseSet=true → native startAdvertisingSet
      // (BLE 5.0 EXTENDED advertising) kullanıyor. Giriş seviyesi / eski
      // Android cihazlar (A20s 2019) extended advertising DESTEKLEMEZ →
      // "PlatformException(18, UNDOCUMENTED, startAdvertisingSet)". iBeacon
      // zaten LEGACY advertising (31-byte paket) ile yayınlanır; extended'e
      // gerek yok. advertiseSet:false → plugin legacy startAdvertising
      // (AdvertiseCallback) kullanır, A20s'in desteklediği klasik yol.
      // iOS bu flag'ten etkilenmez (CoreBluetooth kendi yönetir).
      final state = await _peripheral.start(
        advertiseData: data,
        advertiseSettings: AdvertiseSettings(
          advertiseSet: false,
          // BUG FIX (2026-06-11 — KRİTİK saha bulgusu): plugin'in default
          // timeout'u 400 MİLİSANİYE! Android her yayını 400ms sonra OS
          // seviyesinde kendiliğinden kapatıyordu (dumpsys bluetooth_manager:
          // 8/8 oturum, hepsi 379-411ms) ve plugin bunu state'ine işlemediği
          // için isAdvertising true kalıyordu → "gösterge yeşil ama yayın yok".
          // Android→iPhone yönü bu yüzden HİÇ çalışmamıştı (iPhone→Android
          // yönü iOS'un sürekli yayını sayesinde çalışıyordu, asimetri fark
          // edilmedi). timeout: 0 = süresiz yayın (Android API: "0 disables
          // the time limit"). iOS bu alanı zaten yok sayar.
          timeout: 0,
        ),
      );
      _lastStartState = state;
      debugPrint('📡 [ContactAdvertiser] start → $state');
      // BUG FIX: Eskiden state ne dönerse dönsün _isRunning=true set
      // ediliyordu → advertise başarısız olsa bile sessizce "çalışıyor" gibi
      // davranıyordu, ContactBleScanner.start'a benzer state-bazlı kontrol yok.
      // Sadece açıkça reddedilen durumlarda false dön; geri kalan unknown/
      // success durumlarında true varsay (flutter_ble_peripheral start sonrası
      // didStartAdvertising callback ile gerçek durumu raporlar — bunu da
      // burada bekleyemeyiz çünkü Future hemen dönüyor).
      // Net hata durumları: izin/destek/BT-off. unknown durumu Android'de
      // start sırasında normaldir (didStartAdvertising sonradan gelir) →
      // unknown'ı başarı say.
      final ok = state != BluetoothPeripheralState.denied &&
                 state != BluetoothPeripheralState.permanentlyDenied &&
                 state != BluetoothPeripheralState.restricted &&
                 state != BluetoothPeripheralState.unsupported &&
                 state != BluetoothPeripheralState.turnedOff;
      _isRunning = ok;
      if (!ok) {
        debugPrint('❌ [ContactAdvertiser] start başarısız: $state');
      }
      return ok;
    } catch (e, st) {
      debugPrint('❌ [ContactAdvertiser] start hatası: $e\n$st');
      _lastErrorMessage = 'Yayın başlatılamadı: $e';
      _isRunning = false;
      return false;
    }
  }

  Future<void> stop() async {
    // BUG FIX (2026-06-11 saha): eski `if (!_isRunning) return;` guard'ı
    // kaldırıldı — bayrak native gerçekten koptuysa (false ama OS hâlâ
    // yayında) opt-out yayını FİİLEN durduramıyordu (KVKK ihlali riski).
    // stop artık koşulsuz native stop dener; zaten durmuşsa no-op.
    try {
      await _peripheral.stop();
      debugPrint('🛑 [ContactAdvertiser] stop');
    } catch (e) {
      debugPrint('⚠️ [ContactAdvertiser] stop hatası: $e');
    } finally {
      _isRunning = false;
    }
  }

  bool get isAdvertising => _isRunning;

  /// Native katmana "şu an GERÇEKTEN yayın var mı" diye sorar. [_isRunning]
  /// bayrağı OS gerçeğinden kopabiliyor (BT toggle, hızlı stop→start, OS'in
  /// yayını sessizce öldürmesi) — sağlık kontrolü bayrağa değil buna bakar.
  /// Kanal hatasında bayrağa düşer (en iyi tahmin).
  Future<bool> verifyAdvertising() async {
    try {
      return await _peripheral.isAdvertising;
    } catch (_) {
      return _isRunning;
    }
  }

  /// SELF-HEALING (2026-06-11 saha bulgusu): BT/opt-out toggle sonrası native
  /// yayın ölü kalıp _isRunning true kalınca start() "zaten çalışıyor" diye
  /// no-op dönüyordu → "gösterge yeşil ama yayın yok". Bu metod gerçek durumu
  /// sorgular; yayın yoksa bayrağı sıfırlayıp baştan başlatır. Periyodik
  /// sağlık kontrolü (BeaconController._contactHealthCheck) çağırır.
  Future<bool> ensureStarted(String deviceIdHash) async {
    if (await verifyAdvertising()) {
      _isRunning = true; // bayrak ↔ native senkron
      return true;
    }
    _isRunning = false;
    return start(deviceIdHash);
  }
}

final contactAdvertiserProvider = Provider<ContactAdvertiser>(
  (ref) => ContactAdvertiser(),
);
