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

    try {
      final perm = await _peripheral.hasPermission();
      if (perm != BluetoothPeripheralState.granted) {
        final req = await _peripheral.requestPermission();
        if (req != BluetoothPeripheralState.granted) {
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

      final state = await _peripheral.start(advertiseData: data);
      debugPrint('📡 [ContactAdvertiser] start → $state');
      _isRunning = true;
      return true;
    } catch (e, st) {
      debugPrint('❌ [ContactAdvertiser] start hatası: $e\n$st');
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
