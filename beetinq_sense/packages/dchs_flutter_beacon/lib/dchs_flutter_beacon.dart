import 'dart:async';

import 'dchs_flutter_beacon_platform_interface.dart';
import 'src/authorization_status.dart';
//import 'src/beacon.dart';
import 'src/beacon_broadcast.dart';
import 'src/bluetooth_state.dart';
import 'src/monitoring_result.dart';
import 'src/ranging_result.dart';
import 'src/region.dart';

// Esporta le classi dal folder src
export 'src/authorization_status.dart';
export 'src/beacon_broadcast.dart';
export 'src/beacon.dart';
export 'src/bluetooth_state.dart';
export 'src/monitoring_result.dart';
export 'src/ranging_result.dart';
export 'src/region.dart';

final DchsFlutterBeacon flutterBeacon = DchsFlutterBeacon();

class DchsFlutterBeacon {
  // Singleton instance
  static final DchsFlutterBeacon _instance = DchsFlutterBeacon._internal();

  factory DchsFlutterBeacon() {
    return _instance;
  }

  DchsFlutterBeacon._internal();

  DchsFlutterBeaconPlatform get _platform => DchsFlutterBeaconPlatform.instance;

  Future<bool> get initializeScanning => _platform.initializeScanning();
  Future<bool> get initializeAndCheckScanning =>
      _platform.initializeAndCheckScanning();
  Future<bool> setLocationAuthorizationTypeDefault(
          AuthorizationStatus authorizationStatus) =>
      _platform.setLocationAuthorizationTypeDefault(authorizationStatus);
  Future<AuthorizationStatus> get authorizationStatus =>
      _platform.authorizationStatus;
  Future<bool> get checkLocationServicesIfEnabled =>
      _platform.checkLocationServicesIfEnabled;
  Future<BluetoothState> get bluetoothState => _platform.bluetoothState;
  Future<bool> get requestAuthorization => _platform.requestAuthorization;
  Future<bool> get openBluetoothSettings => _platform.openBluetoothSettings;
  Future<bool> get openLocationSettings => _platform.openLocationSettings;
  Future<bool> get openApplicationSettings => _platform.openApplicationSettings;

  Future<bool> setScanPeriod(int scanPeriod) =>
      _platform.setScanPeriod(scanPeriod);
  Future<bool> setBetweenScanPeriod(int scanPeriod) =>
      _platform.setBetweenScanPeriod(scanPeriod);
  Future<bool> setBackgroundScanPeriod(int scanPeriod) =>
      _platform.setBackgroundScanPeriod(scanPeriod);
  Future<bool> setBackgroundBetweenScanPeriod(int scanPeriod) =>
      _platform.setBackgroundBetweenScanPeriod(scanPeriod);

  Future<bool> setUseTrackingCache(bool enable) =>
      _platform.setUseTrackingCache(enable);
  Future<bool> setMaxTrackingAge(int age) => _platform.setMaxTrackingAge(age);

  Future<bool> get close => _platform.close;
  Stream<RangingResult> ranging(List<Region> regions) =>
      _platform.ranging(regions);
  Stream<MonitoringResult> monitoring(List<Region> regions) =>
      _platform.monitoring(regions);
  Stream<BluetoothState> bluetoothStateChanged() =>
      _platform.bluetoothStateChanged();
  Stream<AuthorizationStatus> authorizationStatusChanged() =>
      _platform.authorizationStatusChanged();
  Future<void> startBroadcast(BeaconBroadcast params) =>
      _platform.startBroadcast(params);
  Future<void> stopBroadcast() => _platform.stopBroadcast();
  Future<bool> isBroadcasting() => _platform.isBroadcasting();
  Future<bool> isBroadcastSupported() => _platform.isBroadcastSupported();
}
