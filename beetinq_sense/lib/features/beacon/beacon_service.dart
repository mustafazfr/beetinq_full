import 'dart:async';
import 'dart:io';

import 'package:dchs_flutter_beacon/dchs_flutter_beacon.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class BeaconService {
  final DchsFlutterBeacon _beacon;

  static const _channel = MethodChannel('com.beetinq.sense/beacon_service');

  BeaconService({DchsFlutterBeacon? beacon}) : _beacon = beacon ?? flutterBeacon;

  Stream<BluetoothState> bluetoothStateChanged() => _beacon.bluetoothStateChanged();
  Stream<AuthorizationStatus> authorizationStatusChanged() =>
      _beacon.authorizationStatusChanged();

  StreamSubscription<RangingResult>? _rangingSub;
  StreamSubscription<MonitoringResult>? _monitoringSub;

  /// Foreground service başlatma sonucu:
  /// null  → başarılı veya iOS (gerek yok)
  /// String → hata mesajı (controller UI'ya yansıtabilir)
  Future<String?> startForegroundService() async {
    if (!Platform.isAndroid) return null;
    try {
      await _channel.invokeMethod('startService');
      return null;
    } on MissingPluginException {
      // Native channel henüz bağlanmamış — non-fatal, ranging yine de çalışabilir
      return null;
    } catch (e) {
      // FGS_START_FAILED veya beklenmedik hata — controller'a ilet
      return e.toString();
    }
  }

  Future<void> stopForegroundService() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('stopService');
    } on MissingPluginException {
      // Non-fatal
    } catch (e) {
      debugPrint('⚠️ [BeaconService] stopForegroundService hatası: $e');
    }
  }

  Future<void> tuneScanningSafe() async {
    try {
      await _beacon.setScanPeriod(300);          // 300ms — daha sık tarama
      await _beacon.setBetweenScanPeriod(0);     // Aralık yok, sürekli tara
      if (Platform.isAndroid) {
        await _beacon.setUseTrackingCache(true);
        await _beacon.setMaxTrackingAge(5000);   // 5sn — daha kısa cache
      }
    } on MissingPluginException {
      // Non-fatal
    } on PlatformException {
      // Non-fatal
    }
  }

  /// Task 3.3: 10 dakikadır hiç aktif beacon/contact yoksa düşük güç moduna
  /// geç. Tarayıcı daha seyrek çalışır, pil ömrü uzar; aktivite dönünce
  /// [tuneScanningSafe] ile normal moda döndürülür.
  Future<void> tuneScanLowPower() async {
    try {
      await _beacon.setScanPeriod(1100);         // iBeacon default civarı
      await _beacon.setBetweenScanPeriod(5000);  // 5sn ara
      if (Platform.isAndroid) {
        await _beacon.setUseTrackingCache(true);
        await _beacon.setMaxTrackingAge(15000);  // Cache daha uzun — işlem az
      }
    } on MissingPluginException {
      // Non-fatal
    } on PlatformException {
      // Non-fatal
    }
  }

  Future<void> initialize() async {
    try {
      await _beacon.initializeAndCheckScanning;
    } on PlatformException catch (e) {
      throw BeaconInitException('${e.code}: ${e.message}');
    }
  }

  Future<AuthorizationStatus> getAuthorizationStatus() async => _beacon.authorizationStatus;

  Future<BluetoothState> getBluetoothState() async => _beacon.bluetoothState;

  Future<bool> requestAuthorization() async => _beacon.requestAuthorization;

  Future<void> openAppSettings() async => _beacon.openApplicationSettings;

  List<Region> buildRegions({
    required String identifier,
    required String uuid,
    int? major,
    int? minor,
  }) {
    return [
      Region(identifier: identifier, proximityUUID: uuid, major: major, minor: minor),
    ];
  }

  List<Region> buildIosRegions({
    required String identifier,
    required String uuid,
    int? major,
    int? minor,
  }) => buildRegions(identifier: identifier, uuid: uuid, major: major, minor: minor);

  Stream<RangingResult> startRanging(List<Region> regions) {
    _rangingSub?.cancel();
    return _beacon.ranging(regions);
  }

  Stream<MonitoringResult> startMonitoring(List<Region> regions) {
    _monitoringSub?.cancel();
    return _beacon.monitoring(regions);
  }

  Future<void> stopAll() async {
    await _rangingSub?.cancel();
    _rangingSub = null;
    await _monitoringSub?.cancel();
    _monitoringSub = null;
    await _beacon.close;
  }

  void bindRangingSubscription(StreamSubscription<RangingResult> sub) {
    _rangingSub?.cancel();
    _rangingSub = sub;
  }

  void bindMonitoringSubscription(StreamSubscription<MonitoringResult> sub) {
    _monitoringSub?.cancel();
    _monitoringSub = sub;
  }
}

class BeaconInitException implements Exception {
  final String message;
  BeaconInitException(this.message);
  @override
  String toString() => 'BeaconInitException: $message';
}
