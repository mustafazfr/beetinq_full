# Dchs Flutter Beacon


[![Pub](https://img.shields.io/pub/v/dchs_flutter_beacon.svg)](https://pub.dartlang.org/packages/dchs_flutter_beacon) 
[![GitHub](https://img.shields.io/github/license/dariocavada/dchs_flutter_beacon.svg?color=2196F3)](https://github.com/dariocavada/dchs_flutter_beacon/blob/master/LICENSE) 

[Flutter plugin](https://pub.dartlang.org/packages/dchs_flutter_beacon/) to work with iBeacons.  

An hybrid iBeacon scanner and transmitter SDK for Flutter plugin. Supports Android API 21+ and iOS 13+.

Features:

* Automatic permission management
* Ranging iBeacons  
* Monitoring iBeacons
* Transmit as iBeacon

## Installation

Add to pubspec.yaml:

```yaml
dependencies:
  dchs_flutter_beacon: latest
```

### Setup specific for Android

For target SDK version 29+ (Android 10, 11) is necessary to add manually ```ACCESS_FINE_LOCATION```

``` 
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>
```

and if you want also background scanning: 
```
<uses-permission android:name="android.permission.ACCESS_BACKGROUND_LOCATION" />
```

and if you want to broadcast beacons: 
```
<uses-permission android:name="android.permission.BLUETOOTH_ADVERTISE" />
```

Refer to the example for more detailed information.

#### iOS 13+ Beacon Visibility Issue

On iOS 13 and later, beacons may only appear briefly before being lost. 
To mitigate this issue, try increasing the setBetweenScanPeriod parameter to a value greater than 0:

``` dart
await flutterBeacon.setScanPeriod(1000);
await flutterBeacon.setBetweenScanPeriod(500);
```

#### Persistent Beacon Detection Using Cache
If you want beacons to persistently appear in the results, you can enable the tracking cache and set a maximum tracking age. For example:

``` dart
await flutterBeacon.setUseTrackingCache(true);
await flutterBeacon.setMaxTrackingAge(10000);
```

#### Android Debug Mode - Developer Options

When using Android in debug mode, some developers have reported improved beacon recognition by disabling the "Bluetooth A2DP Hardware Offload" option in the Developer Settings. Disabling this feature can make beacon detection more reliable.

### Setup specific for iOS

In order to use beacons related features, apps are required to ask the location permission. It's a two step process:

1. Declare the permission the app requires in configuration files
2. Request the permission to the user when app is running (the plugin can handle this automatically)

The needed permissions in iOS is `when in use`.

For more details about what you can do with each permission, see:  
https://developer.apple.com/documentation/corelocation/choosing_the_authorization_level_for_location_services

Permission must be declared in `ios/Runner/Info.plist`:

```xml
<dict>
  <!-- When in use -->
  <key>NSLocationWhenInUseUsageDescription</key>
  <string>Reason why app needs location</string>
  <!-- Always -->
  <!-- for iOS 11 + -->
  <key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
  <string>Reason why app needs location</string>
  <!-- for iOS 9/10 -->
  <key>NSLocationAlwaysUsageDescription</key>
  <string>Reason why app needs location</string>
  <!-- Bluetooth Privacy -->
  <!-- for iOS 13 + -->
  <key>NSBluetoothAlwaysUsageDescription</key>
  <string>Reason why app needs bluetooth</string>
</dict>
```

## iOS Troubleshooting

* Example code works properly only on **physical device** (bluetooth on simulator is disabled)
* How to deploy flutter app on iOS device [Instruction](https://flutter.dev/docs/get-started/install/macos)
* If example code don't works on device (beacons not appear), please make sure that you have enabled <br/> Location and Bluetooth (Settings -> Flutter Beacon) 

## How-to

Ranging APIs are designed as reactive streams.  

* The first subscription to the stream will start the ranging

### Initializing Library

```dart
try {
  // if you want to manage manual checking about the required permissions
  await flutterBeacon.initializeScanning;
  
  // or if you want to include automatic checking permission
  await flutterBeacon.initializeAndCheckScanning;
} on PlatformException catch(e) {
  // library failed to initialize, check code and message
}
```

### Ranging beacons

```dart
final regions = <Region>[];

if (Platform.isIOS) {
  // iOS platform, at least set identifier and proximityUUID for region scanning
  regions.add(Region(
      identifier: 'Apple Airlocate',
      proximityUUID: 'E2C56DB5-DFFB-48D2-B060-D0F5A71096E0'));
} else {
  // android platform, it can ranging out of beacon that filter all of Proximity UUID
  regions.add(Region(identifier: 'com.beacon'));
}

// to start ranging beacons
_streamRanging = flutterBeacon.ranging(regions).listen((RangingResult result) {
  // result contains a region and list of beacons found
  // list can be empty if no matching beacons were found in range
});

// to stop ranging beacons
_streamRanging.cancel();
```

### Monitoring beacons

```dart
final regions = <Region>[];

if (Platform.isIOS) {
  // iOS platform, at least set identifier and proximityUUID for region scanning
  regions.add(Region(
      identifier: 'Apple Airlocate',
      proximityUUID: 'E2C56DB5-DFFB-48D2-B060-D0F5A71096E0'));
} else {
  // Android platform, it can ranging out of beacon that filter all of Proximity UUID
  regions.add(Region(identifier: 'com.beacon'));
}

// to start monitoring beacons
_streamMonitoring = flutterBeacon.monitoring(regions).listen((MonitoringResult result) {
  // result contains a region, event type and event state
});

// to stop monitoring beacons
_streamMonitoring.cancel();
```

## Under the hood

* iOS uses native Framework [CoreLocation](https://developer.apple.com/documentation/corelocation/)
* Android uses the [Android-Beacon-Library](https://github.com/AltBeacon/android-beacon-library) ([Apache License 2.0](https://github.com/AltBeacon/android-beacon-library/blob/master/LICENSE))  

# Author

Flutter Beacon plugin originally was developed by Eyro Labs. 

DCHS Flutter Beacon is an updated version of the original plugin, now ported to Kotlin by Dario Cavada. 
For inquiries or support, feel free to reach out at dario.cavada.lab@gmail.com (https://www.suggesto.eu)


