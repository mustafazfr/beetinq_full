import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_ble_peripheral/flutter_ble_peripheral.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/contact/contact_config.dart';

/// Cihazı iBeacon olarak yayınlayan servis. Contact tracing akışının
/// "advertiser" tarafı; "scanner" tarafı BeaconService'te (Task 1.5.4).
///
/// PAKET KISITI (Task 1.5.3 kararı — A): flutter_ble_peripheral 2.x iOS'ta
/// manufacturerData alanını desteklemiyor; yalnızca service UUID / localName
/// yayınlayabilir. iBeacon formatı CLBeaconRegion tarafı için Apple şirket
/// kimliği (0x004C) + mfg data ile crafted olmalı — bu yüzden iOS'ta
/// advertiser çalıştırılmıyor. iOS cihazlar sadece scanner rolünde kalır.
/// Demo senaryosu: iki Android cihaz.
class ContactAdvertiser {
  final FlutterBlePeripheral _peripheral = FlutterBlePeripheral();
  bool _isRunning = false;

  /// iBeacon mfg data payload: [0x02, 0x15, uuid(16), major(2), minor(2), txPower(1)]
  /// Company ID (0x004C) AdvertiseData.manufacturerId alanında ayrı gider.
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
    bytes[0] = 0x02; // iBeacon sub-type
    bytes[1] = 0x15; // length
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

  /// Advertise başlatır. deviceIdHash (SHA-256 hex) major/minor'e encode edilir.
  /// Dönüş: true = başladı, false = atlandı/başarısız.
  Future<bool> start(String deviceIdHash) async {
    if (!Platform.isAndroid) {
      debugPrint(
        '🔕 [ContactAdvertiser] iOS — advertiser çalıştırılmıyor '
        '(paket kısıtı, sadece scanner).',
      );
      return false;
    }

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

      final ids = encodeDeviceId(deviceIdHash);
      final payload = _buildIBeaconPayload(
        uuid: kContactTracingUuid,
        major: ids.major,
        minor: ids.minor,
      );

      // Apple company ID — iBeacon formatı için mandatory.
      const appleCompanyId = 0x004C;

      final data = AdvertiseData(
        manufacturerId: appleCompanyId,
        manufacturerData: payload,
        includeDeviceName: false,
      );

      final state = await _peripheral.start(advertiseData: data);
      debugPrint(
        '📡 [ContactAdvertiser] start → $state '
        '(anonId=${decodeAnonId(ids.major, ids.minor)})',
      );
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

  /// Raporlama için sync getter; native durumu da sorgulamak istersen
  /// [FlutterBlePeripheral.isAdvertising] kullan.
  bool get isAdvertising => _isRunning;
}

final contactAdvertiserProvider = Provider<ContactAdvertiser>(
  (ref) => ContactAdvertiser(),
);
