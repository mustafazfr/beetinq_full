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

  /// iBeacon mfg data payload (Android dalı için):
  /// [0x02, 0x15, uuid(16), major(2), minor(2), txPower(1)]
  static Uint8List _buildIBeaconPayload({
    required String uuid,
    required int major,
    required int minor,
    int txPower = -59,
  }) {
    final hex = uuid.replaceAll('-', '');
    if (hex.length != 32) {
      throw FormatException('UUID 32 hex char olmalı (dash sonrası): $uuid');
    }
    final bytes = Uint8List(23);
    bytes[0] = 0x02;
    bytes[1] = 0x15;
    for (int i = 0; i < 16; i++) {
      bytes[2 + i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    bytes[18] = (major >> 8) & 0xFF;
    bytes[19] = major & 0xFF;
    bytes[20] = (minor >> 8) & 0xFF;
    bytes[21] = minor & 0xFF;
    bytes[22] = txPower & 0xFF;
    return bytes;
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

      AdvertiseData data;
      if (Platform.isAndroid) {
        // iBeacon yayını (mevcut akış, dokunulmadı).
        final ids = encodeDeviceId(deviceIdHash);
        final payload = _buildIBeaconPayload(
          uuid: kContactTracingUuid,
          major: ids.major,
          minor: ids.minor,
        );
        const appleCompanyId = 0x004C;
        data = AdvertiseData(
          manufacturerId: appleCompanyId,
          manufacturerData: payload,
          includeDeviceName: false,
        );
        debugPrint(
          '📡 [ContactAdvertiser] Android iBeacon yayını '
          '(anonId=${decodeAnonId(ids.major, ids.minor)})',
        );
      } else if (Platform.isIOS) {
        // Service UUID + local name yayını.
        // localName Apple iBeacon mfg data'sı yerine geçer; Beetinq scanner
        // (flutter_blue_plus) prefix "BTQ-" ile filtreler.
        final localName = encodeAnonIdToLocalName(deviceIdHash);
        data = AdvertiseData(
          serviceUuid: kContactTracingUuid,
          localName: localName,
          includeDeviceName: false,
        );
        debugPrint(
          '📡 [ContactAdvertiser] iOS service UUID yayını '
          '(localName=$localName)',
        );
      } else {
        debugPrint('🔕 [ContactAdvertiser] desteklenmeyen platform, atlandı.');
        return false;
      }

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
        advertiseSettings: AdvertiseSettings(advertiseSet: false),
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
    if (!_isRunning) return;
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
}

final contactAdvertiserProvider = Provider<ContactAdvertiser>(
  (ref) => ContactAdvertiser(),
);
