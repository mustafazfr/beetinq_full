import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'dchs_flutter_beacon_method_channel.dart';
import 'src/authorization_status.dart';
//import 'src/beacon.dart';
import 'src/beacon_broadcast.dart';
import 'src/bluetooth_state.dart';
import 'src/monitoring_result.dart';
import 'src/ranging_result.dart';
import 'src/region.dart';

abstract class DchsFlutterBeaconPlatform extends PlatformInterface {
  /// Constructs a DchsFlutterBeaconPlatform.
  DchsFlutterBeaconPlatform() : super(token: _token);

  static final Object _token = Object();

  static DchsFlutterBeaconPlatform _instance = MethodChannelDchsFlutterBeacon();

  /// The default instance of [DchsFlutterBeaconPlatform] to use.
  ///
  /// Defaults to [MethodChannelDchsFlutterBeacon].
  static DchsFlutterBeaconPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [DchsFlutterBeaconPlatform] when
  /// they register themselves.
  static set instance(DchsFlutterBeaconPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<bool> initializeScanning();
  Future<bool> initializeAndCheckScanning();
  Future<bool> setLocationAuthorizationTypeDefault(
      AuthorizationStatus authorizationStatus);
  Future<AuthorizationStatus> get authorizationStatus;
  Future<bool> get checkLocationServicesIfEnabled;
  Future<BluetoothState> get bluetoothState;
  Future<bool> get requestAuthorization;
  Future<bool> get openBluetoothSettings;
  Future<bool> get openLocationSettings;
  Future<bool> get openApplicationSettings;
  Future<bool> setScanPeriod(int scanPeriod);
  Future<bool> setBetweenScanPeriod(int scanPeriod);
  Future<bool> setBackgroundScanPeriod(int scanPeriod);
  Future<bool> setBackgroundBetweenScanPeriod(int scanPeriod);
  Future<bool> setUseTrackingCache(bool enable);
  Future<bool> setMaxTrackingAge(int age);
  Future<bool> get close;
  Stream<RangingResult> ranging(List<Region> regions);
  Stream<MonitoringResult> monitoring(List<Region> regions);
  Stream<BluetoothState> bluetoothStateChanged();
  Stream<AuthorizationStatus> authorizationStatusChanged();
  Future<void> startBroadcast(BeaconBroadcast params);
  Future<void> stopBroadcast();
  Future<bool> isBroadcasting();
  Future<bool> isBroadcastSupported();
}
