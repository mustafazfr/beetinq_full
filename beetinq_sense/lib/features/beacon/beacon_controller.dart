import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:dchs_flutter_beacon/dchs_flutter_beacon.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:uuid/uuid.dart';

import '../../core/contact/contact_config.dart';
import '../../core/filters/rssi_filter.dart';
import '../contact/contact_advertiser.dart';
import '../contact/contact_ble_scanner.dart';
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
  // Temas tracing alt sistem durumları — sahada "Yayın/Tarama gerçekten
  // çalışıyor mu?" göstergesi için. opt-out kapalıyken false; advertiser/
  // scanner başarıyla başlamışsa true.
  final bool contactAdvertising;
  final bool contactScanning;
  // Temas yayını başarısızsa okunabilir sebep (örn "Bu cihaz BLE yayın
  // DESTEKLEMİYOR"). UI bunu Temas Yayını satırının altında gösterir.
  final String? contactError;
  // TEŞHİS: ranging'de görülen ham contact iBeacon sayısı (guard öncesi).
  final int contactRawSeen;

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
    this.contactAdvertising = false,
    this.contactScanning = false,
    this.contactError,
    this.contactRawSeen = 0,
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
        contactAdvertising: false,
        contactScanning: false,
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
    bool? contactAdvertising,
    bool? contactScanning,
    Object? contactError = clearValue,
    int? contactRawSeen,
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
      contactAdvertising: contactAdvertising ?? this.contactAdvertising,
      contactScanning: contactScanning ?? this.contactScanning,
      contactError: identical(contactError, clearValue) ? this.contactError : contactError as String?,
      contactRawSeen: contactRawSeen ?? this.contactRawSeen,
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
  // İzin değişimi stream'i — iOS'ta CLLocationManager iznini async callback
  // ile bildirir; plugin'in requestAuthorization Future'ı dialog tam kapanmadan
  // dönüyor → ilk açılışta getAuthorizationStatus() eski (notDetermined) değeri
  // okuyor, tikler boş kalıyor. Bu stream izin değişince state'i tazeler ve
  // gerekirse initSdk'yı yeniden tetikler → uygulama yeniden başlatmaya gerek yok.
  StreamSubscription<AuthorizationStatus>? _authSub;

  // Aggregation storage
  final Map<String, BeaconRow> _rows = {};
  final Map<String, RssiFilter> _filters = {};

  // Aggregated beacon list
  List<BeaconRow> _top3Stable = const [];
  static const double _swapHysteresisDb = 3.0;

  bool _initInProgress = false;
  // BUG FIX (Mobil R6): initSdk sürerken (yavaş cihaz, ilk açılış) Bluetooth
  // toggle veya izin değişimi listener'ı tekrar initSdk çağırırsa eski kod
  // sessizce no-op dönüyordu → SDK yarı-init durumda donabiliyordu. Bu flag,
  // "init sürerken bir reinit isteği geldi" durumunu kaydeder; mevcut init
  // bitince finally bloğu bir kez daha initSdk çalıştırır.
  bool _pendingReinit = false;

  // Contact tracing opt-out cache (Task 1.5.8): ranging callback sync
  // olduğu için SharedPreferences'a her event'te async çağrı yerine
  // mutable cache. Settings page toggle edince [setContactEnabledCache]
  // ile güncellenir.
  bool _contactEnabledCache = true;
  // BUG FIX (Mobil R4 — iOS scope/KVKK): iOS'ta uygulama arka plana
  // geçince advertiser+scanner durduruluyor ama dchs_flutter_beacon ranging
  // (Always izniyle) arka planda contact iBeacon görmeye devam edebilir →
  // arka planda contact event raporlanabilirdi (scope ihlali: "iOS'ta arka
  // planda contact YOK"). Bu flag ile iOS'ta yalnızca ön planda contact
  // event işlenir. Android'de arka plan contact SCOPE İÇİNDE → her zaman true.
  bool _appInForeground = true;
  // TEŞHİS: ranging'de contact UUID iBeacon ham görülme sayısı (guard öncesi).
  // UI'da "Ham temas sinyali: N" olarak gösterilir — cross-platform contact
  // sorununda hangi katmanın sustuğunu (yayın yok mu / guard mı) ayırt eder.
  int _contactRawSeen = 0;
  // Self-contact guard: cihazın kendi iBeacon yayınını ranging'de görmesi
  // halinde (bazı Android cihazlar kendi advertisement'ını tarar) kendisiyle
  // "contact" kaydı oluşturmasını engeller. initSdk'da kendi deviceId'sinden
  // hesaplanır. flutter_blue_plus scanner'da zaten self-skip var; bu, iBeacon
  // ranging tarafının karşılığı.
  String? _selfContactAnonId;
  // BUG FIX: Watchdog reentrancy guard. Watchdog restart sırasında
  // tekrar tetiklenirse iki paralel startDeviceRanging çalışmaz.
  bool _isRestartingRanging = false;

  Timer? _statusPollTimer;
  Timer? _rangingWatchdogTimer;
  Timer? _scanPowerTimer;
  // Periyodik fingerprint/beacon senkronu: ikinci telefon, birinci telefon
  // yeni stand kaydederken restart olmadan güncellensin (30 sn'de bir).
  Timer? _syncTimer;

  // Task 3.3: adaptif scan period. 10 dk aktivite yoksa düşük güç moduna
  // geç. [_lastBeaconActivity] target veya contact beacon görüldüğünde
  // güncellenir.
  DateTime? _lastBeaconActivity;
  bool _isLowPowerMode = false;
  static const _scanIdleThreshold = Duration(minutes: 10);
  DateTime? _lastRangingEvent;
  DateTime? _lastValidBeaconTime;

  // HYSTERESIS: Sinyal kopmalarında "ping-pong" etkisini önler.
  // _locationLossCount: beacon GÖRÜNÜYOR ama eşleşme yok (gerçek taşınma)
  // durumundaki kısa event toleransı. Sinyal tamamen kesilince (beacon yok)
  // bunun yerine süre bazlı _locationGracePeriod kullanılır (aşağıda).
  int _locationLossCount = 0;
  static const int _locationLossThreshold = 5;

  // Sinyal kesintisi (hiç aktif beacon görünmüyor) durumunda konumu SÜRE bazlı
  // koru: son geçerli beacon'dan bu kadar süre geçmedikçe oturum kapanmaz.
  // Event sayısı (~1.5sn) yerine süre kullanmak, "aynı yerde dururken BLE
  // sinyali titreyince sahte yeni ziyaret üretme" ping-pong'unu önler.
  // Watchdog restart'ından (15sn) uzun seçildi ki restart oturumu öldürmesin.
  static const Duration _locationGracePeriod = Duration(seconds: 30);

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
    // İlk lifecycle state'i flutter'dan oku: lifecycle event'i hiç gelmeden de
    // doğru başlangıç değeri (örn Xcode'dan Run sonrası iOS bazen resumed
    // event'ini geç tetikler veya hiç tetiklemez).
    final initial = WidgetsBinding.instance.lifecycleState;
    if (Platform.isIOS && initial != null) {
      _appInForeground = initial != AppLifecycleState.paused &&
                         initial != AppLifecycleState.detached &&
                         initial != AppLifecycleState.hidden;
    }
    ref.onDispose(() {
      WidgetsBinding.instance.removeObserver(this);
      _statusPollTimer?.cancel();
      _statusPollTimer = null;
      _rangingWatchdogTimer?.cancel();
      _rangingWatchdogTimer = null;
      _syncTimer?.cancel();
      _syncTimer = null;
      // BUG FIX (Mobil R7): _scanPowerTimer onDispose'da temizlenmiyordu →
      // provider dispose/hot-reload sonrası orphan timer tick atıp dispose'lu
      // notifier'a erişmeye çalışıyordu.
      _scanPowerTimer?.cancel();
      _scanPowerTimer = null;
      _rangingSub?.cancel();
      _rangingSub = null;
      _monitoringSub?.cancel();
      _monitoringSub = null;
      _btStateSub?.cancel();
      _btStateSub = null;
      _authSub?.cancel();
      _authSub = null;
    });
    return BeaconState.initial();
  }

  // Parametre bilerek `lifecycle` — `state` olsaydı Notifier'ın `state`
  // getter'ını gölgeler ve metot içindeki state.detectedLocation vb. bozulur.
  @override
  // ignore: avoid_renaming_method_parameters
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    // BUG FIX: iOS lifecycle akışı active → inactive → paused → inactive →
    // resumed sırasıyla gider; bazen resumed hiç gelmez veya kullanıcı kısa
    // bir geçişte yalnızca `inactive` görür. Eski kod sadece resumed'da true
    // yapıyordu → bir kez paused'tan sonra `inactive` durumunda takılırsa
    // _appInForeground sonsuza kadar false kalıyordu → iPhone contact
    // event'lerini hiç işlemiyordu ("0 contact" rağmen Android iPhone'u
    // görüyor). Yeni: paused/detached/hidden değilse foreground sayılır.
    if (Platform.isIOS) {
      _appInForeground = lifecycle != AppLifecycleState.paused &&
                         lifecycle != AppLifecycleState.detached &&
                         lifecycle != AppLifecycleState.hidden;
    }

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
        ref.read(contactBleScannerProvider).stop();
        // iOS arka planda contact yok → UI göstergelerini düşür.
        state = state.copyWith(
          contactAdvertising: false,
          contactScanning: false,
        );
      }
    }

    if (lifecycle == AppLifecycleState.resumed) {
      // _appInForeground zaten üstte ayarlandı. Burada sadece iOS resumed'da
      // advertiser+scanner restart edilir (paused'da durdurulmuştu).
      if (Platform.isIOS) {
        _restartContactAdvertiserIfEnabled();
      }
    }
  }

  /// iOS resumed → advertiser ve scanner'ı opt-in durumuna göre yeniden başlat.
  Future<void> _restartContactAdvertiserIfEnabled() async {
    try {
      final enabled = await SettingsPrefs().isContactEnabled();
      if (!enabled) return;
      final reporterDeviceId = await _deviceId.getDeviceId();
      final advOk = await ref
          .read(contactAdvertiserProvider)
          .start(reporterDeviceId);
      // Scanner foreground'a dönünce yeniden başlatılır (paused'da
      // flutter_blue_plus iOS'ta delayed scan yapıyor olabilir).
      final scanOk = await ref.read(contactBleScannerProvider).start(
            selfDeviceIdHash: reporterDeviceId,
            onEncounter: (anonId, rssi, now) {
              ref
                  .read(contactControllerProvider.notifier)
                  .onEncounterEvent(anonId, rssi, now);
              _lastBeaconActivity = now;
            },
          );
      state = state.copyWith(
        contactAdvertising: advOk,
        contactScanning: scanOk,
      );
    } catch (e) {
      _log('contact advertiser/scanner resume hatası: $e');
    }
  }

  void _log(String msg) {
    debugPrint('[BeaconController] $msg');
  }

  /// Settings page opt-out toggle'ı burayı çağırır; ranging callback
  /// değişikliği anında görür. startScanning tekrar çağrılmasına gerek yok.
  ///
  /// Cross-platform scanner (Task 2.18): aynı cache flag'i flutter_blue_plus
  /// scanner'ına da forward edilir, böylece iOS yayınlarını da event olarak
  /// düşürür/sayar.
  void setContactEnabledCache(bool enabled) {
    _contactEnabledCache = enabled;
    ref.read(contactBleScannerProvider).setContactEnabledCache(enabled);
    // Opt-out kapatıldıysa state göstergelerini de düşür (settings_page
    // advertiser/scanner.stop'u kendisi çağırıyor; biz sadece UI sync).
    if (!enabled) {
      state = state.copyWith(
        contactAdvertising: false,
        contactScanning: false,
      );
    }
  }

  /// Settings opt-in sonrası advertiser/scanner start sonuçlarını UI
  /// göstergelerine yansıtmak için.
  void setContactSubsystemState({
    required bool advertising,
    required bool scanning,
  }) {
    state = state.copyWith(
      contactAdvertising: advertising,
      contactScanning: scanning,
    );
  }

  /// "Tüm test verisini sil" butonu çağırır. Mevcut session save EDİLMEZ
  /// (kullanıcı test datasını siliyor zaten). Sıralı:
  /// 1. Subscription'ları, timer'ları durdur
  /// 2. Advertiser stop, contact map reset
  /// 3. SharedPreferences data anahtarlarını sil
  /// 4. State'i initial'e döndür
  /// 5. Foreground service durdur
  Future<void> wipeAndReset() async {
    _log('🗑️ wipeAndReset()');

    _statusPollTimer?.cancel();
    _statusPollTimer = null;
    _rangingWatchdogTimer?.cancel();
    _rangingWatchdogTimer = null;
    _scanPowerTimer?.cancel();
    _scanPowerTimer = null;
    _syncTimer?.cancel();
    _syncTimer = null;
    _btStateSub?.cancel();
    _btStateSub = null;
    _authSub?.cancel();
    _authSub = null;

    await _rangingSub?.cancel();
    _rangingSub = null;
    await _monitoringSub?.cancel();
    _monitoringSub = null;

    await ref.read(contactAdvertiserProvider).stop();
    await ref.read(contactBleScannerProvider).stop();
    ref.read(contactControllerProvider.notifier).reset();

    _rows.clear();
    _filters.clear();
    _top3Stable = const [];
    _lastValidBeaconTime = null;
    _lastBeaconActivity = null;
    _isLowPowerMode = false;
    _locationLossCount = 0;
    _initInProgress = false;
    _isRestartingRanging = false;
    _selfContactAnonId = null;

    await _prefs.wipeAllData();

    try {
      await _service.stopForegroundService();
      await _service.stopAll();
    } catch (e) {
      _log('wipe stopAll uyarı: $e');
    }

    state = BeaconState.initial();

    // BUG FIX (Mobil R5): wipeAndReset _btStateSub ve _authSub'ı cancel'lıyor;
    // eskiden hiç restore edilmiyordu → kullanıcı uygulamayı kapatmazsa wipe
    // sonrası Bluetooth toggle veya izin değişimi event'leri yutuluyor, UI
    // "sistem hazır değil"de takılı kalıyordu. initSdk hem listener'ları
    // tekrar bağlar hem target kayıtlıysa taramayı baştan başlatır.
    await initSdk();
  }

  /// Contact tracing beacon'ları için callback (Task 1.5.5).
  /// ContactController encounter map'ini günceller, eşik aşılırsa
  /// API tetiklemesi 1.5.7'deki hook üzerinden yapılır.
  void _onContactBeacon(int major, int minor, int rssi, DateTime now) {
    final anonId = decodeAnonId(major, minor);
    // Self-contact guard: kendi yayınımızı gördüysek sayma.
    if (_selfContactAnonId != null && anonId == _selfContactAnonId) return;
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
    if (_initInProgress) {
      // Halihazırda init çalışıyor — bittiğinde bir kez daha çalışsın (R6).
      _pendingReinit = true;
      return;
    }
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

      // İzin değişimi stream'i: iOS'ta requestAuthorization Future'ı dialog
      // tam kapanmadan döndüğü için ilk açılışta auth=notDetermined kalabiliyor
      // (tikler boş). Plugin gerçek izni `locationManagerDidChangeAuthorization`
      // ile sonra bildirir → bu listener state'i tazeler ve gerekirse initSdk'yı
      // yeniden tetikler. _initInProgress guard'ı reentrancy'yi engeller.
      // Bluetooth listener'ı ile aynı pattern.
      await _authSub?.cancel();
      _authSub = _service.authorizationStatusChanged().listen((newAuth) {
        if (newAuth == state.authorizationStatus) return;
        state = state.copyWith(authorizationStatus: newAuth);
        final granted = newAuth == AuthorizationStatus.always ||
            newAuth == AuthorizationStatus.whenInUse;
        if (granted &&
            state.errorType == 'permission_denied') {
          // Önceki turda izin reddedildi diye hata kartı vardı → temizle.
          state = state.copyWith(error: null, errorType: null);
        }
        // Yeni izin verildiyse ve SDK hâlâ initialize değilse / tarama
        // başlamamışsa initSdk'yı yeniden çalıştır → tikler dolar.
        if (granted && (!state.initialized || !state.ranging)) {
          _log('🔓 İzin verildi (auth=$newAuth) — initSdk yeniden tetikleniyor');
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
      // UUID gömülü (kDefaultBeaconUuid): kayıtlı target yoksa varsayılanla
      // başla ve diske yaz. Yeni cihazlarda UUID elle girilmez, tarama otomatik
      // başlar. (Mobil UUID giriş alanı kaldırıldı.)
      if (target == null) {
        target = const BeaconTarget(uuid: kDefaultBeaconUuid);
        await _prefs.saveTarget(target);
        _log('🎯 Varsayılan beacon UUID gömülü olarak ayarlandı: $kDefaultBeaconUuid');
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

      // Target her zaman dolu (kayıtlı yoksa varsayılan UUID gömülü) →
      // tarama otomatik başlar.
      _log('Beacon UUID hazır. Taramalar otomatik başlatılıyor...');
      await startScanning();

      // Kuyrukta bekleyenleri göndermeyi dene
      _api.flushQueue().ignore();
      _api.flushContactQueue().ignore();

      // Backend'deki beacon koordinatlarını local cache'e indir.
      // Kullanıcı admin panelinde değiştirdiyse mobil otomatik güncellensin.
      // Fail ise local cache (varsa) kullanılmaya devam eder.
      syncBeaconLocationsFromBackend().ignore();

      // Backend'deki fingerprint'leri (başka cihazların kaydettikleri dahil)
      // indir + lokal engine ile birleştir. Bir cihaz mekânı haritalar, hepsi
      // fingerprint konumlama yapabilir.
      syncFingerprintsFromBackend().ignore();

      // Periyodik senkron: ikinci telefon canlı güncellensin (30 sn).
      _startPeriodicSync();

      // Contact tracing (Task 1.5.7): eşik aşıldığında API'ye gönderilsin.
      final reporterDeviceId = await _deviceId.getDeviceId();

      // Self-contact guard: kendi yayınımızın anonId'sini hesapla (iBeacon
      // ranging kendi advertisement'ını görürse atlanır).
      try {
        final ids = encodeDeviceId(reporterDeviceId);
        _selfContactAnonId = decodeAnonId(ids.major, ids.minor);
      } catch (e) {
        _selfContactAnonId = null;
        _log('⚠️ Self-contact anonId hesaplanamadı: $e');
      }

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
            // Re-report'larda sabit anahtar → backend upsert ile tek kayıt güncellenir.
            clientEventId: encounter.clientEventId,
            // Per-stand: encounter'ın izlendiği stand (rotate'da güncellenir).
            // Encounter konumu yoksa o anki konuma düş (geriye uyum).
            locationName: encounter.locationName ?? state.detectedLocation,
          ).ignore();
        },
      );

      // Contact tracing (Task 1.5.8): advertiser'ı opt-in durumuna göre başlat.
      // Android = iBeacon, iOS = service UUID + local name (Task 2.18).
      // Paralel olarak flutter_blue_plus scanner başlatılır → iOS cihazların
      // service UUID yayınlarını yakalar (mevcut ranging zaten iBeacon yakalar).
      final contactEnabled = await SettingsPrefs().isContactEnabled();
      if (contactEnabled) {
        // Sonuçları state'e yansıt → UI "Temas Yayını / Taraması" göstergeleri.
        // unawaited bırakmak yerine await: kullanıcı sahada gerçekten çalışıyor
        // mu görsün, silent fail olmasın.
        final advOk = await ref
            .read(contactAdvertiserProvider)
            .start(reporterDeviceId);
        final scanOk = await ref.read(contactBleScannerProvider).start(
              selfDeviceIdHash: reporterDeviceId,
              onEncounter: (anonId, rssi, now) {
                ref
                    .read(contactControllerProvider.notifier)
                    .onEncounterEvent(anonId, rssi, now);
                _lastBeaconActivity = now;
              },
            );
        state = state.copyWith(
          contactAdvertising: advOk,
          contactScanning: scanOk,
          // Yayın başarısızsa sebebini UI'ya taşı (advertiser'dan oku).
          contactError: advOk
              ? null
              : ref.read(contactAdvertiserProvider).lastError,
        );
      } else {
        state = state.copyWith(
          contactAdvertising: false,
          contactScanning: false,
          contactError: null,
        );
      }
    } catch (e, st) {
      _log('initSdk ERROR: $e\n$st');
      state = state.copyWith(error: e.toString());
    } finally {
      _initInProgress = false;
      // Init sürerken bir reinit isteği geldiyse (R6) şimdi bir kez çalıştır.
      // Tek seferlik: _pendingReinit sıfırlanır, sonsuz döngü olmaz.
      if (_pendingReinit) {
        _pendingReinit = false;
        _log('🔁 Bekleyen reinit isteği işleniyor');
        Future(() async => initSdk());
      }
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

      // iOS background contact tarama için ayrı region monitoring (Task 2.13).
      // Region monitoring iOS tarafından OS-level sürdürülür: ekran kapalı,
      // app background hatta swipe-killed olsa bile region'a giriş/çıkışta
      // sistem uygulamayı uyandırır ve ranging penceresi açılır.
      // Aksi halde iOS'ta contact scan sadece app foreground'da çalışırdı.
      final contactRegions = _service.buildIosRegions(
        identifier: 'ContactTrace-$kContactTracingUuid',
        uuid: kContactTracingUuid,
      );
      final allRegions = [...regions, ...contactRegions];

      _monitoringSub?.cancel();
      _monitoringSub = _service.startMonitoring(allRegions).listen((result) {
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

            // BUG FIX (iOS sinyal kalitesi): iOS CoreLocation, beacon'u gördüğü
            // ama o döngüde sinyal gücünü ölçemediği durumda rssi=0 döndürür
            // (bazen pozitif de). BLE RSSI her zaman NEGATİFtir (-1..-100).
            // Bu geçersiz okumalar median+Kalman filtresine girerse 0 dBm "çok
            // güçlü sinyal" gibi algılanıp filtreyi bozuyor → fingerprint/
            // trilaterasyon yanlışlanıyor (Android'de görülmez, hep negatif).
            // Geçersiz okumayı tüm akış için (target + contact) atla.
            if (raw >= 0) continue;

            // Contact tracing UUID'si: _rows'a düşmez, ayrı akışa gider.
            // (Aggregation Task 1.5.5'te ContactController'da yapılacak.)
            // R4: iOS'ta yalnızca ön planda işle (_appInForeground); arka
            // planda Always izniyle gelen contact iBeacon'ları sayma → scope.
            if (uuid == contactUuidUpper) {
              // TEŞHİS: guard'lardan ÖNCE ham görülme sayacı. UI'da gösterilir.
              // >0 ise iPhone ranging Android iBeacon'unu GÖRÜYOR demek; encounter
              // yine de oluşmuyorsa sorun guard'larda. 0 ise hiç görülmüyor
              // (Android yaymıyor / region sorunu).
              _contactRawSeen++;
              if (_contactEnabledCache && _appInForeground) {
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
              // medianWindow=5: 3 örnekli median tek-iki spike'ı geçirir;
              // 5 örnekli daha sağlam (gecikme +~200ms ihmal edilebilir).
              return RssiFilter(
                medianWindow: 5,
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

          final match = fingerprintEngine.findNearestMatch(
            currentFingerprint,
            threshold: 15.0,
            // Mevcut konuma yapışkanlık → near-tie flicker'ı azaltır.
            currentLocation: state.detectedLocation,
          );

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

          // HYSTERESIS — "ping-pong" (aynı yerde dururken sahte yeni ziyaret) önleme.
          // İki kayıp türü ayrılır:
          //   1) Sinyal kesintisi (hiç aktif beacon yok): SÜRE bazlı grace ile
          //      konumu koru. Son geçerli beacon'dan _locationGracePeriod (30sn)
          //      geçmedikçe oturum kapanmaz → kısa BLE kesintilerinde tek uzun
          //      ziyaret üretilir. Watchdog restart'ı (15sn) bunu öldürmez.
          //   2) Gerçek taşınma (beacon var ama fingerprint/TL eşleşmesi yok):
          //      kısa event toleransı (_locationLossThreshold) ile hızlı bırak.
          if (bestMatchName == null && state.detectedLocation != null) {
            final bool noActiveBeacons = top3.isEmpty;
            final Duration gap = _lastValidBeaconTime != null
                ? now.difference(_lastValidBeaconTime!)
                : Duration.zero;

            bool keepLocation;
            if (noActiveBeacons) {
              // Sinyal kesintisi → süre bazlı koru.
              // BUG FIX (Mobil R17): eskiden _locationLossCount'a dokunulmu-
              // yordu; sinyal kesintisi ile sonradan gelen "beacon var, eşleş-
              // me yok" event'leri karışıp sayaç hatalı birikiyordu (önceden
              // 2 eşleşmesiz event + sonradan kesinti + sonra 3 eşleşmesiz →
              // 5 sayar, oysa olaylar bağımsız). Kesinti dalında sayacı sıfırla.
              _locationLossCount = 0;
              keepLocation = gap < _locationGracePeriod;
              _log(keepLocation
                  ? '⚡ Sinyal kesintisi (${gap.inSeconds}sn/${_locationGracePeriod.inSeconds}sn), konum korunuyor: ${state.detectedLocation}'
                  : '📵 Sinyal kaybı onaylandı (${gap.inSeconds}sn beacon görünmüyor)');
            } else {
              // Beacon var ama eşleşme yok (taşınma) → kısa event toleransı
              _locationLossCount++;
              keepLocation = _locationLossCount < _locationLossThreshold;
              _log(keepLocation
                  ? '⚡ Geçici eşleşme kaybı ($_locationLossCount/$_locationLossThreshold), konum korunuyor: ${state.detectedLocation}'
                  : '📵 Konum değişimi onaylandı ($_locationLossThreshold ardışık eşleşmesiz event)');
            }

            if (keepLocation) {
              bestMatchName = state.detectedLocation;
              trilaterationX ??= state.trilaterationX;
              trilaterationY ??= state.trilaterationY;
              positionSource ??= state.positionSource;
            } else {
              _locationLossCount = 0;
            }
          } else {
            _locationLossCount = 0;
          }

          // Konum değişti mi?
          if (state.detectedLocation != bestMatchName) {
            // Per-stand temas: yeni standda aktif encounter'lar yeni temas
            // açsın (kullanıcı tercihi). bestMatchName null ise konum kaybı,
            // onLocationChanged null geçer → encounter'lar konumsuz kalır.
            ref
                .read(contactControllerProvider.notifier)
                .onLocationChanged(bestMatchName);

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
            contactRawSeen: _contactRawSeen, // teşhis sayacı
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
            // BUG FIX (Mobil R1): watchdog süresince (15sn) _lastValidBeaconTime
            // güncellenmediği için grace (30sn) hızla doluyor; restart sonrası
            // bir-iki gecikmeli pakette session sahte olarak kapanıyordu. Restart
            // grace timer'ı = "restart sonrası yine veri yok" süresi olmalı, yoksa
            // dururken bile sinyal kesintisi + watchdog kombinasyonu visit bölüyor.
            _lastValidBeaconTime = DateTime.now();
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

    // Contact tracing (Task 1.5.8): advertiser ve scanner'ı her koşulda kapat;
    // opt-out ile tetiklenmeyen stop'larda da BLE pilini boşaltmamak için.
    await ref.read(contactAdvertiserProvider).stop();
    await ref.read(contactBleScannerProvider).stop();
    ref.read(contactControllerProvider.notifier).reset();

    _statusPollTimer?.cancel();
    _statusPollTimer = null;
    _rangingWatchdogTimer?.cancel();
    _rangingWatchdogTimer = null;
    _scanPowerTimer?.cancel();
    _scanPowerTimer = null;
    _syncTimer?.cancel();
    _syncTimer = null;
    _isLowPowerMode = false;
    _lastBeaconActivity = null;
    _btStateSub?.cancel();
    _btStateSub = null;
    _authSub?.cancel();
    _authSub = null;
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
      contactAdvertising: false,
      contactScanning: false,
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
      // BUG FIX (Backend R3): id eskiden millisecondsSinceEpoch idi → iki
      // cihaz aynı milisaniyede "Konum Kaydet" yaparsa aynı id üretip backend
      // upsert'inde birbirini eziyordu (sessiz veri kaybı). UUID v4 ile global
      // benzersiz. Mevcut kayıtlar eski id'lerini korur (migration gerekmez).
      id: const Uuid().v4(),
      name: name,
      rssiMap: rssiSnapshot,
    );
    fingerprintEngine.addFingerprintWithAutoIndex(fp);

    await _prefs.saveFingerprints(fingerprintEngine.knownFingerprints);

    _log('Fingerprint Kaydedildi: "$name" (${rssiSnapshot.length} beacon ile)');
    state = state.copyWith(knownFingerprints: List.unmodifiable(fingerprintEngine.knownFingerprints));

    // Backend'e stand olarak da kaydet — mental model: fingerprint = stand.
    // Idempotent: aynı isimle ikinci çağrı backend'de mevcut'u döndürür,
    // duplicate oluşturmaz. Backend offline ise sessizce false döner;
    // fingerprint zaten lokal kaydedildi, demoyu bozmaz.
    // Fire-and-forget: fingerprint UX'ini bekletmemek için unawaited.
    unawaited(_registerStandFromFingerprint(name));
    // RSSI parmak izini de backend'e gönder → diğer cihazlar indirip kullanır
    // (radio map paylaşımı).
    //
    // BUG FIX (Mobil R2): Eskiden orijinal `fp` (base isim, suffix YOK)
    // push ediliyordu. Ama engine aynı base'e ikinci kayıt gelince mevcut
    // kaydı "#1"e çevirip yenisini "#2" yapıyor. Base isim push edilince
    // backend suffix'siz kayıtlar tutuyor, sonraki sync lokaldeki "#1/#2"yi
    // suffix'siz isimle ezip listede iki özdeş isim bırakıyordu. Çözüm: aynı
    // base'e ait TÜM engine kayıtlarını (güncel suffix'li isimleriyle) push et
    // → backend ile lokal isimler tutarlı kalır. Push upsert (id bazlı).
    final baseName = name.replaceAll(RegExp(r'\s*#\d+$'), '');
    final toPush = fingerprintEngine.knownFingerprints
        .where((f) => f.name.replaceAll(RegExp(r'\s*#\d+$'), '') == baseName)
        .toList();
    for (final f in toPush) {
      unawaited(_pushFingerprintToBackend(f));
    }
    return true;
  }

  Future<void> _pushFingerprintToBackend(Fingerprint fp) async {
    try {
      final ok = await _api.pushFingerprint(
        id: fp.id,
        name: fp.name,
        rssiMap: fp.rssiMap,
      );
      _log(ok
          ? '✅ Fingerprint backend\'e push edildi: "${fp.name}"'
          : '⚠️ Fingerprint push başarısız: "${fp.name}" (lokal kaydedildi)');
    } catch (e) {
      _log('⚠️ Fingerprint push exception: $e');
    }
  }

  /// Manuel "Senkronize Et" — beacon koordinatları + fingerprint'leri backend'den
  /// bir kerede çeker. UI butonu çağırır; restart beklemeden günceller.
  /// Dönüş: {fingerprints, beacons} güncel sayıları (snackbar için).
  Future<({int fingerprints, int beacons})> syncAllFromBackend() async {
    await syncBeaconLocationsFromBackend();
    await syncFingerprintsFromBackend();
    return (
      fingerprints: state.knownFingerprints.length,
      beacons: state.beaconLocations.length,
    );
  }

  /// Periyodik arka plan senkronu (30 sn). İkinci telefon, birinci telefon
  /// haritalarken otomatik güncellensin diye. initSdk başlatır.
  /// Ayrıca uzaktan-sıfırlama epoch'unu kontrol eder (admin panelden
  /// "Sunucu + Telefonları Sıfırla" → bu telefon kendini siler).
  void _startPeriodicSync() {
    _syncTimer?.cancel();
    _syncTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      syncFingerprintsFromBackend().ignore();
      syncBeaconLocationsFromBackend().ignore();
      _checkRemoteReset().ignore();
    });
  }

  /// Uzaktan sıfırlama sinyali kontrolü. Admin panelden "Sunucu + Telefonları
  /// Sıfırla" basılınca backend `deviceResetEpoch` ilerletilir. Bu telefon,
  /// sakladığı son uygulanan epoch'tan büyük bir değer görünce yerel verisini
  /// tamamen siler ([wipeAndReset]).
  ///
  /// İlk kurulumda (`getLastWipeEpoch` null) gelen epoch BASELINE olarak
  /// kaydedilir; eski wipe'ları tetiklemez. Backend erişilemezse (-1) atlanır
  /// → offline'da yanlışlıkla silme yok.
  Future<void> _checkRemoteReset() async {
    final epoch = await _api.fetchDeviceResetEpoch();
    if (epoch < 0) return; // backend erişilemedi
    final prefs = SettingsPrefs();
    final lastApplied = await prefs.getLastWipeEpoch();
    if (lastApplied == null) {
      // Baseline: ilk görülen epoch'u uygulanmış say — kurulumdan önceki
      // wipe'lar bu telefonu etkilemez.
      await prefs.setLastWipeEpoch(epoch);
      return;
    }
    if (epoch > lastApplied) {
      _log('🧹 Uzaktan sıfırlama sinyali (epoch $epoch > $lastApplied) — telefon sıfırlanıyor');
      // Önce kaydet: wipeAndReset SettingsPrefs'e dokunmasa da, fail durumunda
      // tekrar tekrar tetiklenmesin diye epoch'u idempotent biçimde işaretle.
      await prefs.setLastWipeEpoch(epoch);
      await wipeAndReset();
    }
  }

  /// Backend'deki fingerprint'leri çekip lokal engine ile birleştirir.
  /// Merge: id'ye göre dedup, backend kaydı authoritative (en güncel).
  /// "Bir cihaz haritalar, hepsi kullanır" akışının indirme tarafı.
  ///
  /// WIPE RECONCILIATION (Görev 1): Operatör admin panelden "tüm verileri sil"
  /// yaptığında backend boşalır ama mobil hâlâ "asd" gibi eski fingerprint'leri
  /// diskte tutar ve ranging/queue üzerinden backend'e geri basabilir. Burada
  /// backend'e GERÇEKTEN ulaşıldı (HTTP 200) VE boş döndü VE lokalde fingerprint
  /// VARSA, bunu "backend silindi" sinyali kabul edip lokal fingerprint'leri +
  /// açık oturumu temizleriz. Böylece otomatik geri-yazma kesilir. Kullanıcı
  /// kasıtlı "Konum Kaydet" yaparsa grace penceresi devreye girer (silinmez).
  ///
  /// Güvenlik: offline/hata `null` döner (boş liste DEĞİL) → lokal veri korunur.
  Future<void> syncFingerprintsFromBackend({String eventId = 'default'}) async {
    try {
      final raw = await _api.fetchFingerprintsOrNull(eventId: eventId);
      // null = backend'e ulaşılamadı → lokal veriye dokunma.
      if (raw == null) return;

      // Backend boş → indirilecek bir şey yok, lokal veriye DOKUNMA.
      // ÖNEMLİ (regresyon fix'i): Eskiden burada _reconcileWipedBackend ile
      // tüm yerel fingerprint'ler siliniyordu. Bu, server-only wipe sonrası
      // (push gecikmesi/başarısızlığı durumunda) kullanıcının kalibrasyonunu
      // 30sn'lik periyodik sync'te yok ediyordu → "fingerprint hep yanlış".
      // Telefon fingerprint'in KAYNAĞIDIR; backend sadece paylaşım katmanı.
      // Kasıtlı tam sıfırlama "Sunucu + Telefonları Sıfırla" ile yapılır.
      if (raw.isEmpty) return;
      final remote = <Fingerprint>[];
      for (final j in raw) {
        try {
          remote.add(Fingerprint.fromJson(j));
        } catch (e) {
          _log('⚠️ Geçersiz fingerprint atlandı: $e');
        }
      }
      if (remote.isEmpty) return;

      final byId = <String, Fingerprint>{};
      for (final f in fingerprintEngine.knownFingerprints) {
        byId[f.id] = f;
      }
      for (final f in remote) {
        byId[f.id] = f; // backend güncel kabul edilir
      }
      final merged = byId.values.toList();
      fingerprintEngine.loadFingerprints(merged);
      await _prefs.saveFingerprints(merged);
      state = state.copyWith(knownFingerprints: List.unmodifiable(merged));
      _log('✅ ${remote.length} fingerprint backend\'den indirildi (toplam ${merged.length}).');
    } catch (e) {
      _log('❌ Fingerprint sync hatası: $e');
    }
  }

  Future<void> _registerStandFromFingerprint(String name) async {
    try {
      // Stand konumu normalde admin panelden drag-drop ile verilir; backend
      // artık rastgele konum atamıyor. Yine de fingerprint anında bir
      // trilaterasyon konumu biliniyorsa başlangıç tahmini olarak gönderilir
      // (admin sonra haritada düzeltebilir). Konum yoksa null gider → backend
      // stand'ı "yerleştirilmemiş" olarak kaydeder.
      final ok = await _api.registerStand(
        name: name,
        x: state.trilaterationX,
        y: state.trilaterationY,
      );
      if (ok) {
        _log('✅ Stand backend\'e kaydedildi (fingerprint→stand): "$name"');
      } else {
        _log('⚠️ Stand backend kaydı başarısız: "$name" (fingerprint lokal kaydedildi)');
      }
    } catch (e) {
      _log('⚠️ Stand backend kaydı exception: $e');
    }
  }

  // --- Admin: BeaconLocation Yönetimi ---
  //
  // Tek kaynak: backend. Mobilde yapılan ekle/sil işlemleri önce backend'e
  // yansır, başarılıysa local cache (SharedPreferences + state) güncellenir.
  // Backend fail ise exception fırlatılır → UI snackbar ile kullanıcıyı bilgilendirir.

  /// Beacon ekle/güncelle. x,y null verilirse backend auto-grid (1m aralıklı)
  /// pozisyon atar; admin panelden drag-drop ile düzeltilir. Başarılı POST
  /// sonrası backend'den lokal cache sync edilir, böylece backend'in atadığı
  /// gerçek (x,y) lokale yansır.
  Future<void> addBeaconLocation({
    required String id,
    double? x,
    double? y,
    String? name,
  }) async {
    final parts = id.split('-');
    if (parts.length < 7) {
      throw Exception('Beacon id formatı geçersiz: $id');
    }
    final uuid = parts.sublist(0, 5).join('-');
    final major = int.tryParse(parts[5]) ?? 0;
    final minor = int.tryParse(parts[6]) ?? 0;

    final ok = await _api.registerBeaconLocation(
      uuid: uuid,
      major: major,
      minor: minor,
      x: x,
      y: y,
      name: name,
    );
    if (!ok) {
      throw Exception(
        'Sunucuya kaydedilemedi. Ağı veya backend\'i kontrol et.',
      );
    }
    // Backend auto-grid uyguladıysa lokal cache'i tazele
    await syncBeaconLocationsFromBackend();
    _log('BeaconLocation eklendi: $id (x:${x ?? "auto"}, y:${y ?? "auto"})');
  }

  Future<void> removeBeaconLocation(String id) async {
    final ok = await _api.deleteBeaconLocation(id);
    if (!ok) {
      throw Exception('Sunucudan silinemedi. Ağı kontrol et.');
    }
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
    // Backend'den de sil — diğer cihazlar bir sonraki sync'te güncellenir.
    unawaited(_api.deleteFingerprint(id));
  }

  void _updateLifecycleAndEvict(DateTime now) {
    // iOS CoreLocation ~1Hz ranges ama geçersiz (rssi=0) okumalar atlandıktan
    // sonra geçerli okuma pratikte ~5sn'de bir gelebiliyor. activeMs=2000 ise
    // beacon okumalar arası "stale" olup fingerprint match'ten düşüyordu (KNN
    // sadece active beacon kullanır) → iOS'ta konum tutmuyordu. iOS'ta pencereyi
    // genişlet ki yavaş okumalar arası beacon'lar "active" kalsın. Android hızlı
    // okuduğu için (~300ms) tuned 2sn değerine DOKUNULMAZ.
    final activeMs = Platform.isIOS ? 6000 : 2000;
    final evictMs = Platform.isIOS ? 12000 : 8000;

    final activeCutoff = now.subtract(Duration(milliseconds: activeMs));
    final evictCutoff = now.subtract(Duration(milliseconds: evictMs));

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
