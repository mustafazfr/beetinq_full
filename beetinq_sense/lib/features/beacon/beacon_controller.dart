import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:dchs_flutter_beacon/dchs_flutter_beacon.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/contact/contact_config.dart';
import '../../core/filters/rssi_filter.dart';
import '../contact/contact_advertiser.dart';
import '../contact/contact_controller.dart';
import '../settings/settings_prefs.dart';
import 'api_service.dart';
import 'beacon_config.dart';
import 'beacon_prefs.dart';
import 'beacon_service.dart';
import 'device_id_service.dart';

import '../../core/positioning/fingerprint_engine.dart';
import '../../core/positioning/trilateration_engine.dart';

final beaconServiceProvider = Provider<BeaconService>((ref) {
  return BeaconService();
});

final beaconPrefsProvider = Provider<BeaconPrefs>((ref) => BeaconPrefs());

final beaconControllerProvider =
    NotifierProvider<BeaconController, BeaconState>(BeaconController.new);

enum BeaconLifecycle { active, stale }

class BeaconRow {
  final String key; // uuid-major-minor
  final String uuid;
  final int? major;
  final int? minor;

  final BeaconLifecycle lifecycle;

  final int rawRssi;
  final double filteredRssi;

  final DateTime lastSeen;
  final int seenCount;

  const BeaconRow({
    required this.key,
    required this.uuid,
    required this.lifecycle,
    required this.rawRssi,
    required this.filteredRssi,
    required this.lastSeen,
    required this.seenCount,
    this.major,
    this.minor,
  });

  BeaconRow copyWith({
    int? rawRssi,
    double? filteredRssi,
    DateTime? lastSeen,
    int? seenCount,
    BeaconLifecycle? lifecycle,
  }) {
    return BeaconRow(
      key: key,
      uuid: uuid,
      major: major,
      minor: minor,
      rawRssi: rawRssi ?? this.rawRssi,
      filteredRssi: filteredRssi ?? this.filteredRssi,
      lastSeen: lastSeen ?? this.lastSeen,
      seenCount: seenCount ?? this.seenCount,
      lifecycle: lifecycle ?? this.lifecycle,
    );
  }
}

class BeaconState {
  final bool initialized;
  final bool monitoring;
  final bool ranging;

  final DateTime? currentSessionStart;

  final AuthorizationStatus? authorizationStatus;
  final BluetoothState? bluetoothState;

  final List<MonitoringResult> monitoringResults;

  final List<BeaconRow> beacons;
  final List<BeaconRow> top3;

  final BeaconTarget? target;

  final String? detectedLocation;

  final double? trilaterationX;
  final double? trilaterationY;

  final String? positionSource;

  final String? error;
  final String? errorType;

  final List<BeaconLocation> beaconLocations;
  final List<Fingerprint> knownFingerprints;

  const BeaconState({
    required this.initialized,
    required this.monitoring,
    required this.ranging,
    required this.monitoringResults,
    required this.beacons,
    required this.top3,
    this.authorizationStatus,
    this.bluetoothState,
    this.target,
    this.detectedLocation,
    this.trilaterationX,
    this.trilaterationY,
    this.positionSource,
    this.currentSessionStart,
    this.error,
    this.errorType,
    this.beaconLocations = const [],
    this.knownFingerprints = const [],
  });

  factory BeaconState.initial() => const BeaconState(
        initialized: false,
        monitoring: false,
        ranging: false,
        monitoringResults: [],
        beacons: [],
        top3: [],
        detectedLocation: null,
        trilaterationX: null,
        trilaterationY: null,
        positionSource: null,
        currentSessionStart: null,
      );

  // Sentinel: copyWith'te nullable alanı bilerek null'a çekmek için kullanılır.
  static const Object clearValue = Object();

  BeaconState copyWith({
    bool? initialized,
    bool? monitoring,
    bool? ranging,
    AuthorizationStatus? authorizationStatus,
    BluetoothState? bluetoothState,
    List<MonitoringResult>? monitoringResults,
    List<BeaconRow>? beacons,
    List<BeaconRow>? top3,
    Object? target = clearValue,
    Object? detectedLocation = clearValue,
    Object? trilaterationX = clearValue,
    Object? trilaterationY = clearValue,
    Object? positionSource = clearValue,
    Object? currentSessionStart = clearValue,
    Object? error = clearValue,
    Object? errorType = clearValue,
    List<BeaconLocation>? beaconLocations,
    List<Fingerprint>? knownFingerprints,
  }) {
    return BeaconState(
      initialized: initialized ?? this.initialized,
      monitoring: monitoring ?? this.monitoring,
      ranging: ranging ?? this.ranging,
      authorizationStatus: authorizationStatus ?? this.authorizationStatus,
      bluetoothState: bluetoothState ?? this.bluetoothState,
      monitoringResults: monitoringResults ?? this.monitoringResults,
      beacons: beacons ?? this.beacons,
      top3: top3 ?? this.top3,
      target: identical(target, clearValue) ? this.target : target as BeaconTarget?,
      detectedLocation: identical(detectedLocation, clearValue) ? this.detectedLocation : detectedLocation as String?,
      trilaterationX: identical(trilaterationX, clearValue) ? this.trilaterationX : trilaterationX as double?,
      trilaterationY: identical(trilaterationY, clearValue) ? this.trilaterationY : trilaterationY as double?,
      positionSource: identical(positionSource, clearValue) ? this.positionSource : positionSource as String?,
      currentSessionStart: identical(currentSessionStart, clearValue) ? this.currentSessionStart : currentSessionStart as DateTime?,
      error: identical(error, clearValue) ? this.error : error as String?,
      errorType: identical(errorType, clearValue) ? this.errorType : errorType as String?,
      beaconLocations: beaconLocations ?? this.beaconLocations,
      knownFingerprints: knownFingerprints ?? this.knownFingerprints,
    );
  }
}

class BeaconController extends Notifier<BeaconState> with WidgetsBindingObserver {
  StreamSubscription<RangingResult>? _rangingSub;
  StreamSubscription<MonitoringResult>? _monitoringSub;
  StreamSubscription<BluetoothState>? _btStateSub;

  // Aggregation storage
  final Map<String, BeaconRow> _rows = {};
  final Map<String, RssiFilter> _filters = {};

  // Aggregated beacon list
  List<BeaconRow> _top3Stable = const [];
  static const double _swapHysteresisDb = 3.0;

  bool _initInProgress = false;

  // Contact tracing opt-out cache (Task 1.5.8): ranging callback sync
  // olduğu için SharedPreferences'a her event'te async çağrı yerine
  // mutable cache. Settings page toggle edince [setContactEnabledCache]
  // ile güncellenir.
  bool _contactEnabledCache = true;
  // BUG FIX: Watchdog reentrancy guard. Watchdog restart sırasında
  // tekrar tetiklenirse iki paralel startDeviceRanging çalışmaz.
  bool _isRestartingRanging = false;

  Timer? _statusPollTimer;
  Timer? _rangingWatchdogTimer;
  Timer? _scanPowerTimer;

  // Task 3.3: adaptif scan period. 10 dk aktivite yoksa düşük güç moduna
  // geç. [_lastBeaconActivity] target veya contact beacon görüldüğünde
  // güncellenir.
  DateTime? _lastBeaconActivity;
  bool _isLowPowerMode = false;
  static const _scanIdleThreshold = Duration(minutes: 10);
  DateTime? _lastRangingEvent;
  DateTime? _lastValidBeaconTime;

  // HYSTERESIS: Sinyal kopmalarında "ping-pong" etkisini önler.
  int _locationLossCount = 0;
  static const int _locationLossThreshold = 5;

  // --- Position Engines ---
  final FingerprintEngine fingerprintEngine = FingerprintEngine();
  final TrilaterationEngine trilaterationEngine = TrilaterationEngine();

  late final BeaconService _service;
  BeaconPrefs get _prefs => ref.read(beaconPrefsProvider);
  ApiService get _api => ref.read(apiServiceProvider);
  DeviceIdService get _deviceId => ref.read(deviceIdServiceProvider);

  @override
  BeaconState build() {
    _service = ref.read(beaconServiceProvider);
    WidgetsBinding.instance.addObserver(this);
    ref.onDispose(() {
      WidgetsBinding.instance.removeObserver(this);
      _statusPollTimer?.cancel();
      _statusPollTimer = null;
      _rangingWatchdogTimer?.cancel();
      _rangingWatchdogTimer = null;
      _rangingSub?.cancel();
      _rangingSub = null;
      _monitoringSub?.cancel();
      _monitoringSub = null;
      _btStateSub?.cancel();
      _btStateSub = null;
    });
    return BeaconState.initial();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    if (lifecycle == AppLifecycleState.paused ||
        lifecycle == AppLifecycleState.detached) {
      if (state.detectedLocation != null && state.currentSessionStart != null) {
        _prefs.saveCurrentSession(
          state.detectedLocation,
          state.currentSessionStart,
          positionSource: state.positionSource,
          trilaterationX: state.trilaterationX,
          trilaterationY: state.trilaterationY,
          lastSeenTime: _lastValidBeaconTime,
        ).ignore();
        _log('💾 Lifecycle $lifecycle — session diske yazıldı: ${state.detectedLocation}');
      }
      // Contact tracing (Task 1.5.8): iOS'ta advertiser arka planda çalışamaz.
      // Platform.isAndroid kontrolü advertiser.start içinde de var; burada
      // stop'u çağırmak her iki platform için güvenli (Android zaten no-op).
      if (Platform.isIOS) {
        ref.read(contactAdvertiserProvider).stop();
      }
    }

    if (lifecycle == AppLifecycleState.resumed) {
      // Contact tracing (Task 1.5.8): iOS'ta ön plana dönüldüğünde advertise
      // yeniden başlatılır (opt-in durumunda). Android'de zaten sürekli.
      if (Platform.isIOS) {
        _restartContactAdvertiserIfEnabled();
      }
    }
  }

  /// iOS resumed → advertiser'ı opt-in durumuna göre yeniden başlat.
  Future<void> _restartContactAdvertiserIfEnabled() async {
    try {
      final enabled = await SettingsPrefs().isContactEnabled();
      if (!enabled) return;
      final reporterDeviceId = await _deviceId.getDeviceId();
      await ref.read(contactAdvertiserProvider).start(reporterDeviceId);
    } catch (e) {
      _log('contact advertiser resume hatası: $e');
    }
  }

  void _log(String msg) {
    debugPrint('[BeaconController] $msg');
  }

  /// Settings page opt-out toggle'ı burayı çağırır; ranging callback
  /// değişikliği anında görür. startScanning tekrar çağrılmasına gerek yok.
  void setContactEnabledCache(bool enabled) {
    _contactEnabledCache = enabled;
  }

  /// Contact tracing beacon'ları için callback (Task 1.5.5).
  /// ContactController encounter map'ini günceller, eşik aşılırsa
  /// API tetiklemesi 1.5.7'deki hook üzerinden yapılır.
  void _onContactBeacon(int major, int minor, int rssi, DateTime now) {
    final anonId = decodeAnonId(major, minor);
    ref
        .read(contactControllerProvider.notifier)
        .onEncounterEvent(anonId, rssi, now);
  }

  Future<void> refreshStatus() async {
    _log('refreshStatus()');
    try {
      final auth = await _service.getAuthorizationStatus();
      final bt = await _service.getBluetoothState();
      state = state.copyWith(
        authorizationStatus: auth,
        bluetoothState: bt,
        error: null,
      );
      _log('refreshStatus done: auth=$auth bt=$bt');
    } catch (e, st) {
      _log('refreshStatus ERROR: $e\n$st');
      state = state.copyWith(error: e.toString());
    }
  }

  Future<void> initSdk() async {
    _log('initSdk() tapped');
    if (_initInProgress) return;
    _initInProgress = true;

    _statusPollTimer?.cancel();
    _statusPollTimer = null;

    try {
      state = state.copyWith(error: null);

      await _service.initialize();
      await _service.tuneScanningSafe();

      var auth = await _service.getAuthorizationStatus();
      if (auth == AuthorizationStatus.notDetermined) {
        await _service.requestAuthorization();
        auth = await _service.getAuthorizationStatus();
      }

      if (auth == AuthorizationStatus.denied ||
          auth == AuthorizationStatus.restricted) {
        state = state.copyWith(
          error: 'Konum/Bluetooth izni reddedildi. Lütfen ayarlardan izin verin.',
          errorType: 'permission_denied',
        );
        return;
      }

      if (Platform.isAndroid) {
        final bgStatus = await Permission.locationAlways.status;
        if (bgStatus.isDenied) {
          _log('Android: Arka plan konum izni isteniyor...');
          final result = await Permission.locationAlways.request();
          if (result.isPermanentlyDenied) {
            _log('⚠️ Arka plan konum izni kalıcı reddedildi.');
          } else if (!result.isGranted) {
            _log('⚠️ Arka plan konum izni reddedildi.');
          }
        }
      }

      final bt = await _service.getBluetoothState();

      await _btStateSub?.cancel();
      _btStateSub = _service.bluetoothStateChanged().listen((btState) {
        if (btState == state.bluetoothState) return;
        state = state.copyWith(bluetoothState: btState);
        if (btState == BluetoothState.stateOff) {
          state = state.copyWith(
            error: 'Bluetooth kapatıldı.',
            errorType: 'bluetooth_off',
          );
        } else if (btState == BluetoothState.stateOn &&
            state.errorType == 'bluetooth_off') {
          state = state.copyWith(error: null, errorType: null);
          initSdk();
        }
      });

      if (bt == BluetoothState.stateOff) {
        state = state.copyWith(
          initialized: true,
          bluetoothState: bt,
          error: 'Bluetooth kapalı. Lütfen Bluetooth\'u açın.',
          errorType: 'bluetooth_off',
        );
        return;
      }

      var target = await _prefs.loadTarget();
      if (target != null && !_isValidUuid(target.uuid)) {
        _log('⚠️ Diskten yüklenen UUID geçersiz: "${target.uuid}", target atlanıyor.');
        target = null;
      }

      final savedFingerprints = await _prefs.loadFingerprints();
      if (savedFingerprints.isNotEmpty) {
        fingerprintEngine.loadFingerprints(savedFingerprints);
        _log('✅ ${savedFingerprints.length} fingerprint diskten yüklendi.');
      }

      final savedLocations = await _prefs.loadBeaconLocations();
      if (savedLocations.isNotEmpty) {
        _log('✅ ${savedLocations.length} beacon lokasyonu diskten yüklendi.');
      }

      // --- ÖLÜMSÜZLÜK MANTIĞI: Yarım kalan oturumu yükle ---
      final sessionData = await _prefs.loadCurrentSession();
      String? savedLocation;
      DateTime? savedStartTime;
      String? savedPositionSource;
      double? savedTrilaterationX;
      double? savedTrilaterationY;

      if (sessionData != null) {
        savedLocation = sessionData['location'] as String?;
        savedStartTime = sessionData['startTime'] as DateTime?;
        savedPositionSource = sessionData['positionSource'] as String?;
        savedTrilaterationX = sessionData['trilaterationX'] as double?;
        savedTrilaterationY = sessionData['trilaterationY'] as double?;
        final savedLastSeen = sessionData['lastSeenTime'] as DateTime?;

        const maxGapForRecovery = Duration(minutes: 5);
        final referenceTime = savedLastSeen ?? savedStartTime;
        final gapSinceClose = referenceTime != null
            ? DateTime.now().difference(referenceTime)
            : Duration.zero;

        if (savedStartTime != null && gapSinceClose > maxGapForRecovery) {
          // Oturum gerçekten bitti — veriyi API'ye gönder.
          // ÖNEMLİ: api_service artık "önce kuyruğa yaz, sonra gönder"
          // pattern'ı kullanıyor. Yani veri KESİNLİKLE kaybolmaz.
          // clearCurrentSession'ı gönderim sonrası yapmak yerine
          // hemen yapabiliriz çünkü payload artık kuyrukta güvende.
          final DateTime startTime = savedStartTime;
          final DateTime exitTime = savedLastSeen ?? startTime;
          final duration = exitTime.difference(startTime);

          if (duration.inSeconds >= 10 && savedLocation != null) {
            final loc = savedLocation;
            final pSrc = savedPositionSource;
            final tlX = savedTrilaterationX;
            final tlY = savedTrilaterationY;
            _log('📤 Eski oturum API\'ye gönderiliyor (exit=$exitTime, dur=${duration.inSeconds}s): $loc');

            // Önce API çağrısını başlat — api_service içeride önce
            // kuyruğa yazıp sonra flush etmeye çalışır, veri kaybı yok.
            try {
              final deviceId = await _deviceId.getDeviceId();
              await _api.sendVisitEvent(
                deviceId: deviceId,
                locationName: loc,
                enterTime: startTime,
                exitTime: exitTime,
                durationSeconds: duration.inSeconds,
                positionSource: pSrc,
                x: tlX,
                y: tlY,
              );
            } catch (e) {
              _log('❌ Eski oturum gönderim hatası: $e');
            }
          } else {
            _log('⚠️ Eski oturum çok kısa veya konum yok, atlanıyor: $savedLocation (${duration.inSeconds}s)');
          }

          // Payload kuyruğa yazıldı, session'ı artık güvenle silebiliriz.
          await _prefs.clearCurrentSession();
          savedLocation = null;
          savedStartTime = null;
        } else if (savedStartTime != null) {
          _log('♻️ Kurtarılan Oturum (${gapSinceClose.inSeconds}sn kapalı): $savedLocation');
          if (savedLastSeen != null) {
            _lastValidBeaconTime = savedLastSeen;
          }
        }
      }

      state = state.copyWith(
        initialized: true,
        authorizationStatus: auth,
        bluetoothState: bt,
        target: target,
        detectedLocation: savedLocation,
        currentSessionStart: savedStartTime,
        positionSource: savedPositionSource,
        trilaterationX: savedTrilaterationX,
        trilaterationY: savedTrilaterationY,
        beaconLocations: List.unmodifiable(savedLocations),
        knownFingerprints: List.unmodifiable(savedFingerprints),
      );

      if (target != null) {
        _log('Kayıtlı UUID bulundu. Taramalar otomatik başlatılıyor...');
        await startScanning();
      }

      // Kuyrukta bekleyenleri göndermeyi dene
      _api.flushQueue().ignore();
      _api.flushContactQueue().ignore();

      // Contact tracing (Task 1.5.7): eşik aşıldığında API'ye gönderilsin.
      final reporterDeviceId = await _deviceId.getDeviceId();
      ref.read(contactControllerProvider.notifier).setContactTrigger(
        (encounter) {
          _api.sendContactEvent(
            deviceId: reporterDeviceId,
            seenAnonId: encounter.seenAnonId,
            firstSeenAt: encounter.firstSeen,
            lastSeenAt: encounter.lastSeen,
            durationSeconds: encounter.duration.inSeconds,
            avgRssi: encounter.recentWindow(
              const Duration(seconds: kContactDurationSeconds),
            ).avg,
            sampleCount: encounter.sampleCount,
          ).ignore();
        },
      );

      // Contact tracing (Task 1.5.8): advertiser'ı opt-in durumuna göre başlat.
      // iOS'ta paket kısıtı nedeniyle start içinde no-op; Android'de çalışır.
      final contactEnabled = await SettingsPrefs().isContactEnabled();
      if (contactEnabled) {
        ref.read(contactAdvertiserProvider).start(reporterDeviceId).ignore();
      }
    } catch (e, st) {
      _log('initSdk ERROR: $e\n$st');
      state = state.copyWith(error: e.toString());
    } finally {
      _initInProgress = false;
    }
  }

  Future<void> openSettings() async {
    try {
      await _service.openAppSettings();
    } catch (e) {
      _log('openSettings ERROR: $e');
    }
  }

  Future<void> requestAuth() async {
    _log('requestAuth() tapped');
    try {
      state = state.copyWith(error: null);
      await _service.requestAuthorization();
      final auth = await _service.getAuthorizationStatus();
      state = state.copyWith(authorizationStatus: auth);
    } catch (e) {
      state = state.copyWith(error: e.toString());
    }
  }

  Future<void> saveTarget(BeaconTarget target) async {
    final normalized = BeaconTarget(
      uuid: _normalizeUuid(target.uuid),
      major: target.major,
      minor: target.minor,
    );

    if (!_isValidUuid(normalized.uuid)) {
      state = state.copyWith(
        error: 'UUID formatı geçersiz. Beklenen format: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx. '
            'Girilen: "${normalized.uuid}"',
      );
      return;
    }

    await _prefs.saveTarget(normalized);

    _rows.clear();
    _filters.clear();
    _top3Stable = const [];
    _lastValidBeaconTime = null;
    _locationLossCount = 0;

    state = state.copyWith(
      target: normalized,
      error: null,
      beacons: const [],
      top3: const [],
      detectedLocation: null,
      trilaterationX: null,
      trilaterationY: null,
      positionSource: null,
      currentSessionStart: null,
    );

    if (!state.initialized) {
      _log('SDK initialize değil — initSdk() çalıştırılıyor...');
      await initSdk();
    } else {
      _log('Yeni UUID kaydedildi. Taramalar başlatılıyor...');
      await startScanning();
    }
  }

  Future<void> startScanning() async {
    // KVKK opt-out guard (Task 1.2): kullanıcı konum analizini kapattıysa
    // tarama hiç başlamasın. Hem initSdk auto-start hem manuel çağrılar
    // tek noktadan buradan geçer.
    final enabled = await SettingsPrefs().isLocationEnabled();
    if (!enabled) {
      _log('⛔ Konum analizi opt-out — startScanning atlandı.');
      return;
    }

    if (Platform.isAndroid) {
      _log('Android: Sadece Ranging başlatılıyor');
      await startDeviceRanging();
    } else {
      _log('iOS: Monitoring + Ranging başlatılıyor');
      await startIosMonitoring();
      await startDeviceRanging();
    }

    _startScanPowerMonitor();
  }

  /// Task 3.3: dakikada bir aktiviteyi kontrol eder ve gerekirse
  /// tuneScanningSafe ↔ tuneScanLowPower arası switch yapar.
  void _startScanPowerMonitor() {
    _scanPowerTimer?.cancel();
    _lastBeaconActivity ??= DateTime.now();
    _scanPowerTimer = Timer.periodic(const Duration(minutes: 1), (_) async {
      final last = _lastBeaconActivity;
      if (last == null) return;
      final idle = DateTime.now().difference(last);
      if (!_isLowPowerMode && idle > _scanIdleThreshold) {
        _log('💤 ${idle.inMinutes}dk boşta — düşük güç moduna geçiliyor');
        await _service.tuneScanLowPower();
        _isLowPowerMode = true;
      } else if (_isLowPowerMode && idle < _scanIdleThreshold) {
        _log('⚡ Aktivite döndü — normal tarama moduna geçiliyor');
        await _service.tuneScanningSafe();
        _isLowPowerMode = false;
      }
    });
  }

  Future<void> startIosMonitoring() async {
    _log('startIosMonitoring() tapped');
    final t = state.target;
    if (t == null) {
      state = state.copyWith(error: 'Önce UUID (target) kaydet.');
      return;
    }

    try {
      state = state.copyWith(error: null);

      final regions = _service.buildIosRegions(
        identifier: 'Beetinq-${t.uuid}-${t.major ?? 0}-${t.minor ?? 0}',
        uuid: t.uuid,
        major: t.major,
        minor: t.minor,
      );

      _monitoringSub?.cancel();
      _monitoringSub = _service.startMonitoring(regions).listen((result) {
        final updated = [result, ...state.monitoringResults].take(50).toList();
        state = state.copyWith(monitoring: true, monitoringResults: updated);
      });

      _service.bindMonitoringSubscription(_monitoringSub!);
      state = state.copyWith(monitoring: true);
    } catch (e) {
      state = state.copyWith(error: e.toString());
    }
  }

  Future<void> startDeviceRanging() async {
    _log('startDeviceRanging() çağrıldı');
    final t = state.target;

    if (t == null) {
      state = state.copyWith(error: 'Önce UUID (target) kaydet.');
      return;
    }

    try {
      state = state.copyWith(error: null);

      final regions = _service.buildIosRegions(
        identifier: 'Beetinq-${t.uuid}-${t.major ?? 0}-${t.minor ?? 0}',
        uuid: t.uuid,
        major: t.major,
        minor: t.minor,
      );

      // Contact tracing (Task 1.5.4): ikinci region — başka cihazların
      // iBeacon yayınları. Ayrı UUID olduğu için mevcut fingerprint/
      // trilaterasyon akışına girmez; callback içinde ayrıştırılır.
      final contactRegions = _service.buildIosRegions(
        identifier: 'ContactTrace-$kContactTracingUuid',
        uuid: kContactTracingUuid,
      );
      final allRegions = [...regions, ...contactRegions];

      _contactEnabledCache = await SettingsPrefs().isContactEnabled();
      final targetUuidUpper = t.uuid.toUpperCase();
      final contactUuidUpper = kContactTracingUuid.toUpperCase();

      await _rangingSub?.cancel();
      _rangingSub = _service.startRanging(allRegions).listen(
        (result) async {
          final now = DateTime.now();
          _lastRangingEvent = now;

          if (state.errorType == 'ranging_stopped') {
            state = state.copyWith(error: null, errorType: null);
          }

          // 1. Gelen verileri işle (Filtreleme)
          for (final b in result.beacons) {
            final String uuid = b.proximityUUID.toUpperCase();
            final int major = b.major;
            final int minor = b.minor;
            final int raw = b.rssi;

            // Contact tracing UUID'si: _rows'a düşmez, ayrı akışa gider.
            // (Aggregation Task 1.5.5'te ContactController'da yapılacak.)
            if (uuid == contactUuidUpper) {
              if (_contactEnabledCache) {
                _lastBeaconActivity = now;
                _onContactBeacon(major, minor, raw, now);
              }
              continue;
            }
            // Beklenmeyen UUID (target dışı ve contact dışı) — savunma:
            // log bırak, işleme alma.
            if (uuid != targetUuidUpper) {
              continue;
            }
            // Task 3.3: target beacon görüldü → adaptif aktivite işareti.
            _lastBeaconActivity = now;

            final key = '$uuid-$major-$minor';

            final filter = _filters.putIfAbsent(key, () {
              return RssiFilter(
                medianWindow: 3,
                kalmanQ: 0.5,
                kalmanErrorMeasure: 20,
                kalmanErrorEstimate: 30,
              );
            });

            final filtered = filter.apply(raw.toDouble());

            final existing = _rows[key];
            if (existing == null) {
              _rows[key] = BeaconRow(
                key: key,
                uuid: uuid,
                major: major,
                minor: minor,
                lifecycle: BeaconLifecycle.active,
                rawRssi: raw,
                filteredRssi: filtered,
                lastSeen: now,
                seenCount: 1,
              );
            } else {
              _rows[key] = existing.copyWith(
                rawRssi: raw,
                filteredRssi: filtered,
                lastSeen: now,
                seenCount: existing.seenCount + 1,
              );
            }
          }

          // 2. Eskiyenleri temizle
          _updateLifecycleAndEvict(now);

          // 3. Listeyi sırala
          final allList = _rows.values.toList()
            ..sort((a, b) => b.filteredRssi.compareTo(a.filteredRssi));

          final activeList =
              allList.where((b) => b.lifecycle == BeaconLifecycle.active).toList();
          final top3Candidate = activeList.take(3).toList();

          final top3 = _stabilizeTop3(_top3Stable, top3Candidate);
          _top3Stable = top3;

          if (top3.isNotEmpty) {
            _lastValidBeaconTime = top3.first.lastSeen;
          }

          // --- FAZ 3: CANLI KONUM TAHMİNİ ---
          String? bestMatchName;
          double? trilaterationX;
          double? trilaterationY;
          String? positionSource;

          final Map<String, int> currentFingerprint = {};
          final Map<String, double> currentRssiMapDouble = {};
          for (var b in allList) {
            if (b.lifecycle == BeaconLifecycle.active) {
              currentFingerprint[b.key] = b.filteredRssi.round();
              currentRssiMapDouble[b.key] = b.filteredRssi;
            }
          }

          final match = fingerprintEngine.findNearestMatch(currentFingerprint, threshold: 15.0);

          if (match != null) {
            bestMatchName = match.fingerprint.name.replaceAll(RegExp(r'\s*#\d+$'), '');
            positionSource = 'fingerprint';
            _log('Konum (FP): $bestMatchName (Skor: ${match.score.toStringAsFixed(2)}, Oy: ${match.voteCount}/${match.k})');
          } else if (state.beaconLocations.isNotEmpty) {
            final pos = trilaterationEngine.calculatePosition(
              state.beaconLocations,
              currentRssiMapDouble,
            );
            if (pos != null) {
              trilaterationX = pos['x']!;
              trilaterationY = pos['y']!;
              positionSource = 'trilateration';
              final nearest = state.beaconLocations.map((loc) {
                final rssi = currentRssiMapDouble[loc.id];
                return rssi != null ? MapEntry(loc, rssi) : null;
              }).whereType<MapEntry<BeaconLocation, double>>().fold<MapEntry<BeaconLocation, double>?>(
                null,
                (best, e) => best == null || e.value > best.value ? e : best,
              );
              bestMatchName = nearest?.key.locationLabel;
              _log('Konum (TL): $bestMatchName x=${trilaterationX.toStringAsFixed(2)} y=${trilaterationY.toStringAsFixed(2)}');
            }
          }

          // --- FAZ 4: DWELL TIME (BEKLEME SÜRESİ) ---
          DateTime? newSessionStart = state.currentSessionStart;

          // HYSTERESIS
          if (bestMatchName == null && state.detectedLocation != null) {
            _locationLossCount++;
            if (_locationLossCount < _locationLossThreshold) {
              _log('⚡ Geçici sinyal kaybı ($_locationLossCount/$_locationLossThreshold), konum korunuyor: ${state.detectedLocation}');
              bestMatchName = state.detectedLocation;
              trilaterationX ??= state.trilaterationX;
              trilaterationY ??= state.trilaterationY;
              positionSource ??= state.positionSource;
            } else {
              _locationLossCount = 0;
              _log('📵 Sinyal kaybı onaylandı ($_locationLossThreshold ardışık event)');
            }
          } else {
            _locationLossCount = 0;
          }

          // Konum değişti mi?
          if (state.detectedLocation != bestMatchName) {
            final exitTime = top3.isNotEmpty
                ? top3.first.lastSeen
                : (_lastValidBeaconTime ?? DateTime.now());

            if (state.detectedLocation != null && state.currentSessionStart != null) {
              final duration = exitTime.difference(state.currentSessionStart!);

              if (duration.inSeconds >= 10) {
                _log('✅ ZİYARET TAMAMLANDI: ${state.detectedLocation} (${duration.inSeconds} sn)');

                // VERİ KAYBI FIX: api_service artık önce enqueue ediyor,
                // sonra göndermeye çalışıyor. Bu yüzden fire-and-forget
                // kullanmak güvenli — ancak state reset öncesinde yerel
                // değişkenlere kopyalıyoruz ki yeni event state'i
                // değiştirse bile biz orijinal değerlerle gönderiyoruz.
                final closingLocation = state.detectedLocation!;
                final closingStart = state.currentSessionStart!;
                final closingSource = state.positionSource;
                final closingX = state.trilaterationX;
                final closingY = state.trilaterationY;

                state = state.copyWith(
                  detectedLocation: null,
                  currentSessionStart: null,
                );

                // ref.read() referanslarını fire-forget dışında yakala
                final deviceIdSvc = _deviceId;
                final apiSvc = _api;
                Future<void>(() async {
                  try {
                    final deviceId = await deviceIdSvc.getDeviceId();
                    await apiSvc.sendVisitEvent(
                      deviceId: deviceId,
                      locationName: closingLocation,
                      enterTime: closingStart,
                      exitTime: exitTime,
                      durationSeconds: duration.inSeconds,
                      positionSource: closingSource,
                      x: closingX,
                      y: closingY,
                    );
                  } catch (e) {
                    _log('❌ Ziyaret gönderim hatası (ranging): $e');
                  }
                });
              } else {
                _log('⚠️ Geçiş (Ziyaret sayılmadı): ${state.detectedLocation} (${duration.inSeconds} sn)');
              }
            }

            if (bestMatchName != null) {
              newSessionStart = now;
              _log('Yeni Oturum Başladı: $bestMatchName');
            } else {
              newSessionStart = null;
            }

            _prefs.saveCurrentSession(
              bestMatchName,
              newSessionStart,
              positionSource: positionSource,
              trilaterationX: trilaterationX,
              trilaterationY: trilaterationY,
              lastSeenTime: _lastValidBeaconTime,
            ).ignore();
          }

          // 4. UI State'ini Güncelle
          state = state.copyWith(
            ranging: true,
            beacons: allList,
            top3: top3,
            detectedLocation: bestMatchName,
            trilaterationX: trilaterationX,
            trilaterationY: trilaterationY,
            positionSource: positionSource,
            currentSessionStart: newSessionStart,
          );
        },
        onError: (Object e, StackTrace st) {
          _log('⚠️ Ranging stream error (devam ediliyor): $e\n$st');
          state = state.copyWith(
            error: 'Tarama hatası: $e. Devam ediliyor...',
          );
        },
        cancelOnError: false,
      );

      if (Platform.isAndroid) {
        final notifStatus = await Permission.notification.status;
        if (notifStatus.isDenied) {
          await Permission.notification.request();
        }
      }

      final fgsError = await _service.startForegroundService();
      if (fgsError != null) {
        _log('⚠️ ForegroundService başlatılamadı: $fgsError');
        state = state.copyWith(
          error: 'Arka plan servisi başlatılamadı. Uygulama ön planda tutulmalı.',
          errorType: 'ranging_stopped',
        );
      }

      _service.bindRangingSubscription(_rangingSub!);
      state = state.copyWith(ranging: true);

      // --- RANGING WATCHDOG ---
      _lastRangingEvent = DateTime.now();
      _rangingWatchdogTimer?.cancel();
      _rangingWatchdogTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
        if (_lastRangingEvent == null) return;
        // REENTRANCY GUARD: Önceki watchdog restart çalışıyor olabilir.
        if (_isRestartingRanging) return;

        final elapsed = DateTime.now().difference(_lastRangingEvent!).inSeconds;

        // Periyodik disk sync: foreground kill durumunda lastSeenTime güncel kalsın.
        if (state.detectedLocation != null && state.currentSessionStart != null) {
          _prefs.saveCurrentSession(
            state.detectedLocation,
            state.currentSessionStart,
            positionSource: state.positionSource,
            trilaterationX: state.trilaterationX,
            trilaterationY: state.trilaterationY,
            lastSeenTime: _lastValidBeaconTime,
          ).ignore();
        }

        if (elapsed >= 15 && state.ranging) {
          _isRestartingRanging = true;
          try {
            _log('⚠️ Ranging watchdog: $elapsed sn veri yok, yeniden başlatılıyor...');
            state = state.copyWith(
              error: 'Sinyal alınamıyor, tarama yeniden başlatılıyor...',
              errorType: 'ranging_stopped',
            );
            await _rangingSub?.cancel();
            _rangingSub = null;
            _rows.clear();
            _filters.clear();
            _top3Stable = const [];
            state = state.copyWith(
              beacons: const [],
              top3: const [],
            );
            await startDeviceRanging();
          } finally {
            _isRestartingRanging = false;
          }
        }
      });
    } catch (e) {
      state = state.copyWith(error: e.toString());
    }
  }

  /// STABILIZE: Top3'ü swap hysteresis ile stabilize eder.
  ///
  /// BUG FIX: Önceki versiyonda duplicate kontrol sonda yapılıyordu —
  /// aynı beacon iki slot'a yazılıp sonra deduplication ile 3 yerine
  /// 2 elemana düşüyordu. Yeni versiyonda her slot seçimi öncesinde
  /// usedKeys kontrol edilir; duplicate aday atlanır ve candidate
  /// listesinden bir sonraki alınır.
  List<BeaconRow> _stabilizeTop3(List<BeaconRow> current, List<BeaconRow> candidate) {
    if (current.isEmpty) return candidate;
    if (candidate.isEmpty) return const [];

    final currentMap = {for (final b in current) b.key: b};
    final result = <BeaconRow>[];
    final usedKeys = <String>{};

    int candIdx = 0;
    for (int slot = 0; slot < 3 && candIdx < candidate.length; slot++) {
      // Bir sonraki henüz kullanılmamış candidate'i bul
      while (candIdx < candidate.length && usedKeys.contains(candidate[candIdx].key)) {
        candIdx++;
      }
      if (candIdx >= candidate.length) break;

      final cand = candidate[candIdx];
      candIdx++;

      // Eğer bu beacon zaten current içinde varsa, direkt kabul
      if (currentMap.containsKey(cand.key)) {
        result.add(cand);
        usedKeys.add(cand.key);
        continue;
      }

      // Slotta eskiden kim vardı?
      final prev = slot < current.length ? current[slot] : null;
      if (prev == null || usedKeys.contains(prev.key)) {
        // prev yok veya zaten başka slot'a girdi → candidate'i koy
        result.add(cand);
        usedKeys.add(cand.key);
        continue;
      }

      // Eğer prev hâlâ active ve cand çok az daha iyiyse, swap yapma
      final diff = cand.filteredRssi - prev.filteredRssi;
      if (prev.lifecycle == BeaconLifecycle.active && diff < _swapHysteresisDb) {
        // Güncel RSSI için _rows'tan tazele
        final freshPrev = _rows[prev.key] ?? prev;
        result.add(freshPrev);
        usedKeys.add(freshPrev.key);
      } else {
        result.add(cand);
        usedKeys.add(cand.key);
      }
    }

    return result;
  }

  Future<void> stop() async {
    _log('stop() tapped');

    // Contact tracing (Task 1.5.8): advertiser'ı her koşulda kapat;
    // opt-out ile tetiklenmeyen stop'larda da BLE pilini boşaltmamak için.
    await ref.read(contactAdvertiserProvider).stop();
    ref.read(contactControllerProvider.notifier).reset();

    _statusPollTimer?.cancel();
    _statusPollTimer = null;
    _rangingWatchdogTimer?.cancel();
    _rangingWatchdogTimer = null;
    _scanPowerTimer?.cancel();
    _scanPowerTimer = null;
    _isLowPowerMode = false;
    _lastBeaconActivity = null;
    _btStateSub?.cancel();
    _btStateSub = null;
    _lastRangingEvent = null;

    final lastSeen = _lastValidBeaconTime;
    _lastValidBeaconTime = null;
    _initInProgress = false;
    _isRestartingRanging = false;

    await _rangingSub?.cancel();
    _rangingSub = null;
    await _monitoringSub?.cancel();
    _monitoringSub = null;

    if (state.detectedLocation != null && state.currentSessionStart != null) {
      final exitTime = lastSeen ?? DateTime.now();
      final duration = exitTime.difference(state.currentSessionStart!);
      if (duration.inSeconds >= 10) {
        _log('🛑 stop() — Açık oturum kapatılıyor: ${state.detectedLocation} (${duration.inSeconds} sn)');
        try {
          final deviceId = await _deviceId.getDeviceId();
          await _api.sendVisitEvent(
            deviceId: deviceId,
            locationName: state.detectedLocation!,
            enterTime: state.currentSessionStart!,
            exitTime: exitTime,
            durationSeconds: duration.inSeconds,
            positionSource: state.positionSource ?? 'unknown',
            x: state.trilaterationX,
            y: state.trilaterationY,
          );
        } catch (e) {
          _log('❌ stop() API hatası: $e');
        }
      }
      await _prefs.clearCurrentSession();
    }

    state = state.copyWith(
      initialized: false,
      monitoring: false,
      ranging: false,
      beacons: const [],
      top3: const [],
      detectedLocation: null,
      trilaterationX: null,
      trilaterationY: null,
      positionSource: null,
      currentSessionStart: null,
      error: null,
      errorType: null,
    );

    _rows.clear();
    _filters.clear();
    _top3Stable = const [];

    try {
      await _service.stopForegroundService();
      await _service.stopAll();
      _log('stopAll() native done');
    } catch (e, st) {
      _log('stopAll ERROR: $e\n$st');
      state = state.copyWith(error: e.toString());
    }

    await refreshStatus();
  }

  Future<bool> saveCurrentFingerprint(String name) async {
    final activeBeacons = state.beacons.where((b) {
      return b.lifecycle == BeaconLifecycle.active && b.filteredRssi > -95;
    }).toList();

    if (activeBeacons.isEmpty) {
      _log('Hata: Kaydedilecek aktif beacon bulunamadı.');
      return false;
    }

    final Map<String, int> rssiSnapshot = {};
    for (var b in activeBeacons) {
      rssiSnapshot[b.key] = b.filteredRssi.round();
    }

    final fp = Fingerprint(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: name,
      rssiMap: rssiSnapshot,
    );
    fingerprintEngine.addFingerprintWithAutoIndex(fp);

    await _prefs.saveFingerprints(fingerprintEngine.knownFingerprints);

    _log('Fingerprint Kaydedildi: "$name" (${rssiSnapshot.length} beacon ile)');
    state = state.copyWith(knownFingerprints: List.unmodifiable(fingerprintEngine.knownFingerprints));
    return true;
  }

  // --- Admin: BeaconLocation Yönetimi ---

  Future<void> addBeaconLocation(BeaconLocation location) async {
    final updated = [
      ...state.beaconLocations.where((l) => l.id != location.id),
      location,
    ];
    await _prefs.saveBeaconLocations(updated);
    _log('BeaconLocation eklendi: ${location.id} (x:${location.x}, y:${location.y})');
    state = state.copyWith(beaconLocations: List.unmodifiable(updated));
  }

  Future<void> removeBeaconLocation(String id) async {
    final updated = state.beaconLocations.where((l) => l.id != id).toList();
    await _prefs.saveBeaconLocations(updated);
    state = state.copyWith(beaconLocations: List.unmodifiable(updated));
  }

  List<BeaconLocation> getBeaconLocations() => state.beaconLocations;

  /// Backend'den beacon lokasyonlarını çek ve state'e yükle.
  /// Admin panelinde backend'de tanımlı beacon'ları mobile aktarmak için.
  Future<void> syncBeaconLocationsFromBackend({String eventId = 'default'}) async {
    try {
      final raw = await _api.fetchBeaconLocations(eventId: eventId);
      final locations = raw
          .map((json) {
            try {
              return BeaconLocation.fromJson(json);
            } catch (e) {
              _log('⚠️ Geçersiz beacon location atlandı: $e');
              return null;
            }
          })
          .whereType<BeaconLocation>()
          .toList();
      await _prefs.saveBeaconLocations(locations);
      state = state.copyWith(beaconLocations: List.unmodifiable(locations));
      _log('✅ ${locations.length} beacon lokasyonu backend\'den senkronize edildi.');
    } catch (e) {
      _log('❌ Beacon sync hatası: $e');
    }
  }

  List<Fingerprint> getSavedFingerprints() {
    return state.knownFingerprints;
  }

  Future<void> removeFingerprint(String id) async {
    fingerprintEngine.removeFingerprintById(id);
    await _prefs.saveFingerprints(fingerprintEngine.knownFingerprints);
    state = state.copyWith(knownFingerprints: List.unmodifiable(fingerprintEngine.knownFingerprints));
  }

  void _updateLifecycleAndEvict(DateTime now) {
    const activeMs = 2000;
    const evictMs = 8000;

    final activeCutoff = now.subtract(const Duration(milliseconds: activeMs));
    final evictCutoff = now.subtract(const Duration(milliseconds: evictMs));

    final keysToRemove = <String>[];

    _rows.forEach((k, v) {
      if (v.lastSeen.isBefore(evictCutoff)) {
        keysToRemove.add(k);
      } else if (v.lastSeen.isBefore(activeCutoff)) {
        _rows[k] = v.copyWith(lifecycle: BeaconLifecycle.stale);
      } else {
        if (v.lifecycle != BeaconLifecycle.active) {
          _rows[k] = v.copyWith(lifecycle: BeaconLifecycle.active);
        }
      }
    });

    for (final k in keysToRemove) {
      _rows.remove(k);
      _filters.remove(k);
    }
  }

  static String _normalizeUuid(String raw) {
    final s = raw.trim().toUpperCase();
    final hex = s.replaceAll('-', '');
    if (hex.length != 32) return s;
    return '${hex.substring(0, 8)}-'
        '${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-'
        '${hex.substring(16, 20)}-'
        '${hex.substring(20)}';
  }

  static bool _isValidUuid(String uuid) {
    final re = RegExp(r'^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$');
    return re.hasMatch(uuid);
  }
}
