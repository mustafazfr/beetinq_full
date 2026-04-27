import 'dart:async';
import 'package:flutter/services.dart';

import 'dchs_flutter_beacon_platform_interface.dart';
import 'src/authorization_status.dart';
//import 'src/beacon.dart';
import 'src/beacon_broadcast.dart';
import 'src/bluetooth_state.dart';
import 'src/monitoring_result.dart';
import 'src/ranging_result.dart';
import 'src/region.dart';

/// An implementation of [DchsFlutterBeaconPlatform] that uses method channels.
class MethodChannelDchsFlutterBeacon extends DchsFlutterBeaconPlatform {
  static const MethodChannel _methodChannel = MethodChannel('flutter_beacon');
  static const EventChannel _rangingChannel =
      EventChannel('flutter_beacon_event');
  static const EventChannel _monitoringChannel =
      EventChannel('flutter_beacon_event_monitoring');
  static const EventChannel _bluetoothStateChangedChannel =
      EventChannel('flutter_bluetooth_state_changed');
  static const EventChannel _authorizationStatusChangedChannel =
      EventChannel('flutter_authorization_status_changed');

  Stream<BluetoothState>? _onBluetoothState;
  Stream<AuthorizationStatus>? _onAuthorizationStatus;

  @override
  Future<bool> initializeScanning() async {
    final result = await _methodChannel.invokeMethod('initialize');
    return _parseBoolResult(result);
  }

  @override
  Future<bool> initializeAndCheckScanning() async {
    final result = await _methodChannel.invokeMethod('initializeAndCheck');
    return _parseBoolResult(result);
  }

  @override
  Future<bool> setLocationAuthorizationTypeDefault(
      AuthorizationStatus authorizationStatus) async {
    return await _methodChannel.invokeMethod(
        'setLocationAuthorizationTypeDefault', authorizationStatus.value);
  }

  @override
  Future<AuthorizationStatus> get authorizationStatus async {
    final status = await _methodChannel.invokeMethod('authorizationStatus');
    return AuthorizationStatus.parse(status);
  }

  @override
  Future<bool> get checkLocationServicesIfEnabled async {
    final result =
        await _methodChannel.invokeMethod('checkLocationServicesIfEnabled');
    return _parseBoolResult(result);
  }

  @override
  Future<BluetoothState> get bluetoothState async {
    final status = await _methodChannel.invokeMethod('bluetoothState');
    return BluetoothState.parse(status);
  }

  @override
  Future<bool> get requestAuthorization async {
    final result = await _methodChannel.invokeMethod('requestAuthorization');
    return _parseBoolResult(result);
  }

  @override
  Future<bool> get openBluetoothSettings async {
    final result = await _methodChannel.invokeMethod('openBluetoothSettings');
    return _parseBoolResult(result);
  }

  @override
  Future<bool> get openLocationSettings async {
    final result = await _methodChannel.invokeMethod('openLocationSettings');
    return _parseBoolResult(result);
  }

  @override
  Future<bool> get openApplicationSettings async {
    final result = await _methodChannel.invokeMethod('openApplicationSettings');
    return _parseBoolResult(result);
  }

  @override
  Future<bool> setScanPeriod(int scanPeriod) async {
    return await _methodChannel
        .invokeMethod('setScanPeriod', {"scanPeriod": scanPeriod});
  }

  @override
  Future<bool> setBetweenScanPeriod(int scanPeriod) async {
    return await _methodChannel.invokeMethod(
        'setBetweenScanPeriod', {"betweenScanPeriod": scanPeriod});
  }

  @override
  Future<bool> setBackgroundScanPeriod(int scanPeriod) async {
    return await _methodChannel
        .invokeMethod('setBackgroundScanPeriod', {"scanPeriod": scanPeriod});
  }

  @override
  Future<bool> setBackgroundBetweenScanPeriod(int scanPeriod) async {
    return await _methodChannel.invokeMethod(
        'setBackgroundBetweenScanPeriod', {"betweenScanPeriod": scanPeriod});
  }

  @override
  Future<bool> setUseTrackingCache(bool enable) async {
    return await _methodChannel
        .invokeMethod('setUseTrackingCache', {"enable": enable});
  }

  @override
  Future<bool> setMaxTrackingAge(int maxTrackingAge) async {
    return await _methodChannel
        .invokeMethod('setMaxTrackingAge', {"maxTrackingAge": maxTrackingAge});
  }

  @override
  Future<bool> get close async {
    final result = await _methodChannel.invokeMethod('close');
    return _parseBoolResult(result);
  }

  @override
  Stream<RangingResult> ranging(List<Region> regions) {
    final list = regions.map((region) => region.toJson).toList();
    final Stream<RangingResult> onRanging = _rangingChannel
        .receiveBroadcastStream(list)
        .map((dynamic event) => RangingResult.from(event));
    return onRanging;
  }

  @override
  Stream<MonitoringResult> monitoring(List<Region> regions) {
    final list = regions.map((region) => region.toJson).toList();
    final Stream<MonitoringResult> onMonitoring = _monitoringChannel
        .receiveBroadcastStream(list)
        .map((dynamic event) => MonitoringResult.from(event));
    return onMonitoring;
  }

  @override
  Stream<BluetoothState> bluetoothStateChanged() {
    _onBluetoothState ??= _bluetoothStateChangedChannel
        .receiveBroadcastStream()
        .map((dynamic event) => BluetoothState.parse(event));
    return _onBluetoothState!;
  }

  @override
  Stream<AuthorizationStatus> authorizationStatusChanged() {
    _onAuthorizationStatus ??= _authorizationStatusChangedChannel
        .receiveBroadcastStream()
        .map((dynamic event) => AuthorizationStatus.parse(event));
    return _onAuthorizationStatus!;
  }

  @override
  Future<void> startBroadcast(BeaconBroadcast params) async {
    await _methodChannel.invokeMethod('startBroadcast', params.toJson);
  }

  @override
  Future<void> stopBroadcast() async {
    await _methodChannel.invokeMethod('stopBroadcast');
  }

  @override
  Future<bool> isBroadcasting() async {
    final flag = await _methodChannel.invokeMethod('isBroadcasting');
    return flag == true || flag == 1;
  }

  @override
  Future<bool> isBroadcastSupported() async {
    final flag = await _methodChannel.invokeMethod('isBroadcastSupported');
    return flag == true || flag == 1;
  }

  bool _parseBoolResult(dynamic result) {
    if (result is bool) {
      return result;
    } else if (result is int) {
      return result == 1;
    }
    return false;
  }
}
