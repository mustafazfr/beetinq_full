import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'server_discovery.dart';

final apiServiceProvider = Provider<ApiService>((ref) => ApiService());

class ApiService {
  // ── SUNUCU ADRESİ ──────────────────────────────────────────────────────
  //
  // Saha gününde LAN IP/port değişebilir (hotspot ↔ fakülte WiFi).
  // Uygulamayı yeniden derlemeden Ayarlar ekranından girilebilir hâle
  // getirildi (Task 2.14): SharedPreferences anahtarı `server_base_url_v1`.
  //
  // Sırayla:
  //   1. SharedPreferences'tan kullanıcı tarafından girilen tam URL
  //   2. _defaultLanIp + port (eski davranış)
  //   3. Production URL (release mode + LAN ayarsız)
  //   4. Emulator localhost
  //
  // `loadServerUrl()` uygulama açılışında main.dart tarafından çağrılır;
  // sonraki güncellemeler için `setServerUrl()` veya `clearServerUrl()`.
  //
  // Production sunucusu hazır olunca _productionUrl'i aktif edin.
  //
  static const String _defaultLanIp = '172.20.10.13';
  static const String _productionUrl = 'https://api.beetinq.com/api';
  static const String _kServerBaseUrlKey = 'server_base_url_v1';

  // HTTPS flag — backend HTTPS_ENABLED=true ise burayı da true yap.
  // Self-signed cert iOS/Android'de trust edilmiyorsa cert dosyasını
  // cihaza install etmek gerekir; saha testi için genelde HTTP yeterli.
  static const bool _useHttps = false;

  /// Runtime cache. main.dart açılışta `loadServerUrl` çağırır; sonraki
  /// HTTP istekleri bu değeri kullanır. Saha günü kullanıcı Ayarlar'dan
  /// değiştirince `setServerUrl` cache'i günceller — restart gerekmez.
  static String? _cachedBaseUrl;

  /// Kullanıcı server URL'sini elle ayarlamış mı? main.dart açılışta
  /// false ise otomatik subnet-scan discovery tetiklenir.
  static bool get hasCachedServerUrl => _cachedBaseUrl != null;

  /// Açılışta SharedPreferences'tan kullanıcı tanımlı URL'yi yükler.
  /// Yoksa default'a düşer; `_baseUrl` getter'ı senkron kalır.
  static Future<void> loadServerUrl() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kServerBaseUrlKey);
      if (raw != null && raw.trim().isNotEmpty) {
        _cachedBaseUrl = _normalizeServerUrl(raw.trim());
      } else {
        _cachedBaseUrl = null;
      }
      debugPrint('🌐 [API] base URL = ${_cachedBaseUrl ?? _fallbackBaseUrl()}');
    } catch (e) {
      debugPrint('⚠️ [API] loadServerUrl hatası: $e');
      _cachedBaseUrl = null;
    }
  }

  /// Kullanıcı Ayarlar'dan URL girer (örn. "192.168.1.42",
  /// "192.168.1.42:3000", "http://172.20.10.13:3000/api"). Hepsi normalize
  /// edilir → tam http(s)://host:port/api URL'sine dönüştürülür.
  static Future<void> setServerUrl(String? raw) async {
    final prefs = await SharedPreferences.getInstance();
    if (raw == null || raw.trim().isEmpty) {
      await prefs.remove(_kServerBaseUrlKey);
      _cachedBaseUrl = null;
    } else {
      final normalized = _normalizeServerUrl(raw.trim());
      await prefs.setString(_kServerBaseUrlKey, normalized);
      _cachedBaseUrl = normalized;
    }
  }

  /// Kullanıcının girdiği değeri tam URL'ye normalize eder:
  /// - "192.168.1.42"           → "http://192.168.1.42:3000/api"
  /// - "192.168.1.42:3001"      → "http://192.168.1.42:3001/api"
  /// - "http://x.y/api"         → olduğu gibi
  /// - "https://api.beetinq..." → olduğu gibi
  static String _normalizeServerUrl(String raw) {
    var v = raw;
    final hasScheme = v.startsWith('http://') || v.startsWith('https://');
    if (!hasScheme) {
      v = 'http://$v';
    }
    // Port yoksa :3000 ekle (sadece host:port pattern'inde değişiklik).
    final uri = Uri.tryParse(v);
    if (uri == null) return v;
    var port = uri.port;
    if (port == 0) port = 3000;
    var path = uri.path;
    if (path.isEmpty || path == '/') path = '/api';
    return Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: port == _defaultUriPortFor(uri.scheme) ? null : port,
      path: path,
    ).toString();
  }

  static int _defaultUriPortFor(String scheme) =>
      scheme == 'https' ? 443 : 80;

  static String _fallbackBaseUrl() {
    final scheme = _useHttps ? 'https' : 'http';
    if (_defaultLanIp.isNotEmpty && _defaultLanIp != 'SAHA_TEST_IP') {
      return '$scheme://$_defaultLanIp:3000/api';
    }
    if (kReleaseMode) return _productionUrl;
    if (Platform.isAndroid) return 'http://10.0.2.2:3000/api';
    return 'http://localhost:3000/api';
  }

  static String get _baseUrl => _cachedBaseUrl ?? _fallbackBaseUrl();

  /// UI'da göstermek için aktif sunucu adresi (host:port). Saha günü
  /// "hangi sunucuya bağlıyım" teşhisi için.
  static String get currentBaseUrl => _baseUrl;

  /// Backend'e ulaşılabiliyor mu? /api/discover'a kısa timeout'lu ping.
  /// Ana ekrandaki bağlantı göstergesi periyodik çağırır.
  static Future<bool> pingServer() async {
    try {
      final res = await http
          .get(Uri.parse('$_baseUrl/discover'))
          .timeout(const Duration(seconds: 3));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Otomatik keşif (Task 2.19). Cihazın IPv4 subnet'ini tarayıp
  /// `/api/discover` cevabı veren backend'i bulur ve cache + SharedPreferences'a
  /// yazar. Saha günü kullanıcı IP girmek zorunda kalmasın diye.
  ///
  /// Dönüş: bulunan URL veya null. main.dart açılışta unawaited çağırır,
  /// Settings page "Otomatik Bul" butonundan da tetiklenir.
  static Future<String?> tryAutoDiscover({
    Duration timeout = const Duration(seconds: 6),
  }) async {
    try {
      final discovery = ServerDiscovery();
      final url = await discovery.discover(overallTimeout: timeout);
      if (url == null) {
        debugPrint('🌐 [API] auto-discover: backend bulunamadı.');
        return null;
      }
      await setServerUrl(url);
      debugPrint('🌐 [API] auto-discover başarılı: $url');
      return url;
    } catch (e) {
      debugPrint('⚠️ [API] auto-discover hatası: $e');
      return null;
    }
  }

  static const String _kOfflineQueueKey = 'offline_visit_queue_v2';
  // v2 suffix: payload formatı değişti (clientEventId eklendi).
  // v1 kuyruğu varsa eski kayıtlar geçersiz değil, sadece idempotency
  // olmadan gider — yine de çalışır.

  // Contact tracing (Task 1.5.7): ayrı queue, ayrı lock.
  static const String _kContactQueueKey = 'offline_contact_queue_v1';

  static const _uuid = Uuid();

  SharedPreferences? _prefs;
  Future<SharedPreferences> get _prefsInstance async {
    _prefs ??= await SharedPreferences.getInstance();
    return _prefs!;
  }

  Future<void> _queueLock = Future<void>.value();
  Future<void> _contactQueueLock = Future<void>.value();

  Future<T> _withQueueLock<T>(Future<T> Function() fn) {
    final Future<T> result = _queueLock.then<T>((_) => fn());
    _queueLock = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  Future<T> _withContactQueueLock<T>(Future<T> Function() fn) {
    final Future<T> result = _contactQueueLock.then<T>((_) => fn());
    _contactQueueLock = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // OFFLINE QUEUE — Yardımcı Metodlar
  // ─────────────────────────────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> _loadQueue() async {
    final prefs = await _prefsInstance;
    final raw = prefs.getString(_kOfflineQueueKey);
    if (raw == null) return [];
    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      return List<Map<String, dynamic>>.from(
        decoded.map((e) => Map<String, dynamic>.from(e as Map)),
      );
    } catch (e) {
      debugPrint('⚠️ [API] Offline kuyruk JSON parse hatası, veri siliniyor: $e');
      await prefs.remove(_kOfflineQueueKey);
      return [];
    }
  }

  Future<void> _saveQueue(List<Map<String, dynamic>> queue) async {
    final prefs = await _prefsInstance;
    if (queue.isEmpty) {
      await prefs.remove(_kOfflineQueueKey);
    } else {
      await prefs.setString(_kOfflineQueueKey, jsonEncode(queue));
    }
  }

  /// Bir ziyareti kuyruğun sonuna ekler.
  Future<void> _enqueue(Map<String, dynamic> payload) {
    return _withQueueLock(() async {
      final queue = await _loadQueue();
      queue.add(payload);
      await _saveQueue(queue);
      debugPrint('📥 [API] Offline kuyruğa eklendi. Kuyruk: ${queue.length} kayıt');
    });
  }

  // ─────────────────────────────────────────────────────────────────────────
  // ANA METOD — Önce kuyruğa ekle, sonra göndermeye çalış
  // ─────────────────────────────────────────────────────────────────────────

  /// Ziyaret verisini backend'e gönderir.
  ///
  /// VERİ KAYBI ÖNLEMİ: Önce kuyruğa yazar, sonra göndermeyi dener.
  /// Gönderim sırasında app öldürülürse veri kuyrukta kalır ve bir
  /// sonraki açılışta flush edilir.
  ///
  /// IDEMPOTENCY: Her çağrıda bir uuid v4 üretilir ve payload içine
  /// gömülür. Retry'larda aynı uuid gider; backend ikinci INSERT'ü
  /// duplicate olarak reddeder (unique index).
  ///
  /// Dönüş değeri sadece "anında gönderildi mi" bilgisi; false dönse
  /// bile veri kuyrukta güvende.
  Future<bool> sendVisitEvent({
    required String deviceId,
    required String locationName,
    required DateTime enterTime,
    required DateTime exitTime,
    required int durationSeconds,
    String? positionSource,
    double? x,
    double? y,
  }) async {
    final payload = <String, dynamic>{
      'clientEventId': _uuid.v4(),
      'deviceId': deviceId,
      'locationName': locationName,
      'enteredAt': enterTime.toUtc().toIso8601String(),
      'exitedAt': exitTime.toUtc().toIso8601String(),
      'durationSeconds': durationSeconds,
      'positionSource': positionSource ?? 'unknown',
      if (x != null) 'x': x,
      if (y != null) 'y': y,
    };

    // 1) ÖNCE KUYRUĞA YAZ — hiçbir durumda veri kaybı yok.
    await _enqueue(payload);

    // 2) Sonra flush etmeyi dene. Başarılıysa kuyruktan silinir.
    //    Başarısızsa kuyrukta kalır, bir sonraki flush'ta tekrar denenir.
    try {
      await flushQueue();
      // flushQueue tamamlandı; payload hâlâ kuyrukta mı kontrol et
      final stillPending = await _isPending(payload['clientEventId'] as String);
      if (!stillPending) {
        debugPrint('✅ [API] Ziyaret gönderildi: $locationName');
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('⚠️ [API] sendVisitEvent flush hatası: $e');
      return false;
    }
  }

  /// Belirli bir clientEventId hâlâ kuyrukta mı?
  Future<bool> _isPending(String clientEventId) async {
    final queue = await _loadQueue();
    return queue.any((item) => item['clientEventId'] == clientEventId);
  }

  /// Kuyruktaki tüm bekleyen kayıtları göndermeye çalışır.
  Future<void> flushQueue() {
    return _withQueueLock(() async {
      final queue = await _loadQueue();
      if (queue.isEmpty) return;

      // STALE DATA TEMİZLEME: yalnızca PARSE EDİLEBİLEN ve 7 günden eski
      // kayıtları sil.
      // BUG FIX (Mobil R15): Eskiden exitedAt null/parse edilemeyen kayıtlar
      // da sessizce siliniyordu ("veri kaybolmaz" garantisi ihlali). Artık
      // belirsiz kayıtlar KORUNUR — gönderim denenir; gerçekten bozuksa backend
      // 400 verir ve poison-pill yolundan loglanarak temizlenir (sessiz değil).
      final cutoff = DateTime.now().subtract(const Duration(days: 7));
      final fresh = queue.where((item) {
        final raw = item['exitedAt'] as String?;
        if (raw == null) return true; // belirsiz → koru, gönderimde değerlendir
        try {
          return DateTime.parse(raw).isAfter(cutoff);
        } catch (_) {
          return true; // parse edilemiyor → koru, silme
        }
      }).toList();

      final staleCnt = queue.length - fresh.length;
      if (staleCnt > 0) {
        debugPrint('🗑️ [API] $staleCnt eski kayıt (>7 gün) kuyruktan silindi.');
      }
      if (fresh.isEmpty) {
        await _saveQueue([]);
        return;
      }

      debugPrint('🔄 [API] Offline kuyruk flush: ${fresh.length} kayıt');

      final remaining = <Map<String, dynamic>>[];

      for (int i = 0; i < fresh.length; i++) {
        final item = fresh[i];
        try {
          final sent = await _postVisit(item);
          if (sent) {
            debugPrint('✅ [API] Kuyruktan gönderildi: ${item['locationName']}');
          } else {
            // Geçici hata — bu ve sonrasını kuyrukta tut
            remaining.addAll(fresh.sublist(i));
            break;
          }
        } on _PoisonPillException catch (e) {
          debugPrint('🗑️ [API] Poison pill (${e.statusCode}), kayıt silindi: ${item['locationName']}');
        }
      }

      await _saveQueue(remaining);

      if (remaining.isEmpty) {
        debugPrint('✅ [API] Tüm kuyruk gönderildi.');
      } else {
        debugPrint('⚠️ [API] ${remaining.length} kayıt hâlâ kuyrukta.');
      }
    });
  }

  Future<int> pendingCount() async {
    return (await _loadQueue()).length;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // DÜŞÜK SEVİYE — Ham HTTP POST
  // ─────────────────────────────────────────────────────────────────────────

  /// Tek bir payload'ı /api/visit'e POST eder.
  /// true  → başarılı (2xx)
  /// false → geçici hata: ağ yok, timeout, 5xx → kuyrukta kalsın
  /// throws _PoisonPillException → kalıcı hata: 4xx → kuyruktan sil
  Future<bool> _postVisit(Map<String, dynamic> payload) async {
    try {
      final response = await http
          .post(
            Uri.parse('$_baseUrl/visit'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200 || response.statusCode == 201) {
        return true;
      } else if (response.statusCode == 409) {
        // Conflict: backend bu kaydı zaten almış (idempotency).
        // Başarılı say, kuyruktan silinsin.
        debugPrint('♻️ [API] 409 Conflict (zaten kaydedilmiş), atlanıyor.');
        return true;
      } else if (response.statusCode == 429) {
        // Rate limit — geçici hata, kuyrukta kalsın
        debugPrint('⏳ [API] 429 Rate limit, bekleniyor.');
        return false;
      } else if (response.statusCode >= 400 && response.statusCode < 500) {
        // 4xx: Verinin kendisi hatalı — yeniden göndermek işe yaramaz.
        debugPrint('🗑️ [API] Kalıcı hata ${response.statusCode}, kayıt siliniyor: ${response.body}');
        throw _PoisonPillException(response.statusCode);
      } else {
        // 5xx veya diğer: Sunucu taraflı geçici hata — kuyrukta beklesin.
        debugPrint('⚠️ [API] Sunucu hatası ${response.statusCode}: ${response.body}');
        return false;
      }
    } on _PoisonPillException {
      rethrow;
    } on SocketException catch (e) {
      debugPrint('❌ [API] Ağ hatası: $e');
      return false;
    } on HttpException catch (e) {
      debugPrint('❌ [API] HTTP hatası: $e');
      return false;
    } catch (e) {
      debugPrint('❌ [API] Bağlantı hatası: $e');
      return false;
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // DİĞER ENDPOINT'LER
  // ─────────────────────────────────────────────────────────────────────────

  /// Test/demo wipe — backend'deki tüm visit/contact/stand/beacon kayıtlarını
  /// siler. Settings page'deki "Tüm test verisini sil" butonu kullanır.
  /// resetDevices=true ise backend "uzaktan sıfırlama epoch'unu" da ilerletir;
  /// bağlı diğer telefonlar bir sonraki sync'te kendini sıfırlar.
  /// 200 başarı, başka her şey hata.
  Future<bool> wipeServerData({bool resetDevices = false}) async {
    try {
      final response = await http
          .post(
            Uri.parse('$_baseUrl/admin/wipe'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'resetDevices': resetDevices}),
          )
          .timeout(const Duration(seconds: 15));
      return response.statusCode >= 200 && response.statusCode < 300;
    } catch (e) {
      debugPrint('❌ [API] wipeServerData hatası: $e');
      return false;
    }
  }

  /// Backend'in uzaktan cihaz sıfırlama epoch'unu döndürür (ms timestamp).
  /// Erişilemezse/-hata -1 → çağıran kontrolü atlar (yanlışlıkla wipe yok).
  Future<int> fetchDeviceResetEpoch() async {
    try {
      final res = await http
          .get(Uri.parse('$_baseUrl/admin/device-reset-epoch'))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode < 200 || res.statusCode >= 300) return -1;
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final e = data['epoch'];
      return e is num ? e.toInt() : -1;
    } catch (e) {
      debugPrint('❌ [API] fetchDeviceResetEpoch hatası: $e');
      return -1;
    }
  }

  /// Beacon koordinatlarını backend'den çek.
  /// Backend endpoint: GET /api/beacons/locations?eventId=xxx
  Future<List<Map<String, dynamic>>> fetchBeaconLocations({
    String eventId = 'default',
  }) async {
    try {
      final response = await http
          .get(Uri.parse('$_baseUrl/beacons/locations?eventId=$eventId'))
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        return List<Map<String, dynamic>>.from(
          data.map((e) => Map<String, dynamic>.from(e as Map)),
        );
      } else {
        debugPrint('⚠️ [API] Beacon locations status: ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('❌ [API] Beacon koordinatları alınamadı: $e');
    }
    return [];
  }

  /// Backend'den beacon kaydını sil. id format: "UUID-major-minor".
  Future<bool> deleteBeaconLocation(String id) async {
    try {
      final encoded = Uri.encodeComponent(id);
      final response = await http
          .delete(Uri.parse('$_baseUrl/beacons/$encoded'))
          .timeout(const Duration(seconds: 10));
      // 200 başarılı, 404 da "yok zaten" → success say (idempotent silme)
      return response.statusCode == 200 || response.statusCode == 404;
    } catch (e) {
      debugPrint('❌ [API] deleteBeaconLocation hatası: $e');
      return false;
    }
  }

  /// Backend'e bir beacon konumu kaydet (admin modu).
  ///
  /// x ve y null gönderilebilir; backend bu durumda auto-grid (1m aralıklı)
  /// bir pozisyon atar. Mobilde "konum bilmiyorum, sen koy" akışı için.
  ///
  /// 409 (zaten kayıtlı) durumunda:
  ///   - x veya y verilmişse: PATCH /api/beacons/:id ile günceller
  ///     (kullanıcı "Ekle / Güncelle" butonuna sadık kal).
  ///   - x ve y null ise: zaten var, üzerine yazma — true döndür.
  Future<bool> registerBeaconLocation({
    required String uuid,
    required int major,
    required int minor,
    double? x,
    double? y,
    String? name,
    int? standId,
    String eventId = 'default',
  }) async {
    final id = '${uuid.toUpperCase()}-$major-$minor';
    try {
      final response = await http
          .post(
            Uri.parse('$_baseUrl/beacons'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'uuid': uuid.toUpperCase(),
              'major': major,
              'minor': minor,
              if (x != null) 'x': x,
              if (y != null) 'y': y,
              if (name != null) 'name': name,
              if (standId != null) 'standId': standId,
              'eventId': eventId,
            }),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode >= 200 && response.statusCode < 300) {
        return true;
      }

      // 409 = beacon zaten kayıtlı. Kullanıcı x,y verdiyse PATCH ile güncelle.
      if (response.statusCode == 409) {
        if (x == null && y == null) return true; // sadece "zaten var", boş override etme
        final encoded = Uri.encodeComponent(id);
        final patchResp = await http
            .patch(
              Uri.parse('$_baseUrl/beacons/$encoded'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                if (x != null) 'x': x,
                if (y != null) 'y': y,
              }),
            )
            .timeout(const Duration(seconds: 10));
        return patchResp.statusCode >= 200 && patchResp.statusCode < 300;
      }

      debugPrint('⚠️ [API] Beacon kaydı status ${response.statusCode}: ${response.body}');
      return false;
    } catch (e) {
      debugPrint('❌ [API] Beacon kaydı başarısız: $e');
      return false;
    }
  }

  /// Backend'e stand kaydet (idempotent: aynı isim varsa onu döndürür).
  /// Mobilden "fingerprint kaydet = stand oluştur" akışı için kullanılır.
  /// x,y null → backend auto-grid pozisyon atar.
  Future<bool> registerStand({
    required String name,
    double? x,
    double? y,
  }) async {
    try {
      final response = await http
          .post(
            Uri.parse('$_baseUrl/stands'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'name': name,
              if (x != null) 'x': x,
              if (y != null) 'y': y,
            }),
          )
          .timeout(const Duration(seconds: 10));
      return response.statusCode >= 200 && response.statusCode < 300;
    } catch (e) {
      debugPrint('❌ [API] Stand kaydı başarısız: $e');
      return false;
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // FINGERPRINT SENKRON — bir cihaz mekânı haritalar (RSSI parmak izi),
  // diğer cihazlar indirip kullanır. Beacon koordinat senkronuyla aynı mantık.
  // ─────────────────────────────────────────────────────────────────────────

  /// Fingerprint'i (RSSI parmak izi) backend'e gönderir. Aynı id ile tekrar
  /// gönderilirse backend upsert eder. true = başarılı.
  Future<bool> pushFingerprint({
    required String id,
    required String name,
    required Map<String, int> rssiMap,
    String eventId = 'default',
  }) async {
    try {
      final res = await http
          .post(
            Uri.parse('$_baseUrl/fingerprints'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'id': id,
              'name': name,
              'rssiMap': rssiMap,
              'eventId': eventId,
            }),
          )
          .timeout(const Duration(seconds: 10));
      return res.statusCode >= 200 && res.statusCode < 300;
    } catch (e) {
      debugPrint('❌ [API] pushFingerprint hatası: $e');
      return false;
    }
  }

  /// Backend'deki tüm fingerprint'leri çeker (diğer cihazların kaydettikleri
  /// dahil). Mobil bunları kendi FingerprintEngine'ine merge eder.
  ///
  /// Hata/erişilemezlik durumunda boş liste döner (mevcut çağrıların davranışı
  /// korunur). "Backend gerçekten boş mu, yoksa ulaşılamadı mı" ayrımı gereken
  /// yerler için [fetchFingerprintsOrNull] kullanılmalı.
  Future<List<Map<String, dynamic>>> fetchFingerprints({
    String eventId = 'default',
  }) async {
    return (await fetchFingerprintsOrNull(eventId: eventId)) ?? const [];
  }

  /// [fetchFingerprints]'in erişilebilirlik-farkında varyantı:
  /// - HTTP 200 → liste (boş olabilir = backend gerçekten boş)
  /// - ağ hatası / timeout / non-200 → `null` (backend'e ulaşılamadı/hata)
  ///
  /// Wipe sonrası reconciliation için kritik: "200 + boş liste" operatörün
  /// backend'i sildiği anlamına gelir; "null" sadece offline demektir ve lokal
  /// veri silinmemelidir.
  Future<List<Map<String, dynamic>>?> fetchFingerprintsOrNull({
    String eventId = 'default',
  }) async {
    try {
      final res = await http
          .get(Uri.parse('$_baseUrl/fingerprints?eventId=$eventId'))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final List<dynamic> data = jsonDecode(res.body);
        return List<Map<String, dynamic>>.from(
          data.map((e) => Map<String, dynamic>.from(e as Map)),
        );
      }
      debugPrint('⚠️ [API] fetchFingerprints status: ${res.statusCode}');
      return null;
    } catch (e) {
      debugPrint('❌ [API] fetchFingerprints hatası: $e');
      return null;
    }
  }

  /// Backend'den fingerprint sil (lokal silme ile tutarlılık için).
  Future<bool> deleteFingerprint(String id) async {
    try {
      final res = await http
          .delete(Uri.parse('$_baseUrl/fingerprints/${Uri.encodeComponent(id)}'))
          .timeout(const Duration(seconds: 10));
      return res.statusCode == 200 || res.statusCode == 404;
    } catch (e) {
      debugPrint('❌ [API] deleteFingerprint hatası: $e');
      return false;
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // CONTACT TRACING (Task 1.5.7) — visits ile aynı pattern: önce enqueue,
  // sonra flush, idempotent clientEventId. Ayrı queue anahtarı + ayrı lock.
  // ─────────────────────────────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> _loadContactQueue() async {
    final prefs = await _prefsInstance;
    final raw = prefs.getString(_kContactQueueKey);
    if (raw == null) return [];
    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      return List<Map<String, dynamic>>.from(
        decoded.map((e) => Map<String, dynamic>.from(e as Map)),
      );
    } catch (e) {
      debugPrint('⚠️ [API] Contact queue parse hatası, siliniyor: $e');
      await prefs.remove(_kContactQueueKey);
      return [];
    }
  }

  Future<void> _saveContactQueue(List<Map<String, dynamic>> queue) async {
    final prefs = await _prefsInstance;
    if (queue.isEmpty) {
      await prefs.remove(_kContactQueueKey);
    } else {
      await prefs.setString(_kContactQueueKey, jsonEncode(queue));
    }
  }

  Future<void> _enqueueContact(Map<String, dynamic> payload) {
    return _withContactQueueLock(() async {
      final queue = await _loadContactQueue();
      queue.add(payload);
      await _saveContactQueue(queue);
      debugPrint('📥 [API] Contact kuyruğa eklendi. Kuyruk: ${queue.length}');
    });
  }

  Future<bool> _isContactPending(String clientEventId) async {
    final queue = await _loadContactQueue();
    return queue.any((item) => item['clientEventId'] == clientEventId);
  }

  /// Contact event'i backend'e gönderir. Önce kuyruğa yaz, sonra flush dene.
  ///
  /// [clientEventId] verilirse idempotency anahtarı olarak kullanılır; uzun
  /// temaslarda aynı encounter birden çok kez (güncel süreyle) gönderildiğinde
  /// backend upsert ile tek kaydı günceller. Verilmezse her çağrıda yeni v4
  /// üretilir (geriye dönük uyumluluk).
  Future<bool> sendContactEvent({
    required String deviceId,
    required String seenAnonId,
    required DateTime firstSeenAt,
    required DateTime lastSeenAt,
    required int durationSeconds,
    required double avgRssi,
    required int sampleCount,
    String? clientEventId,
    String? locationName,
  }) async {
    final payload = <String, dynamic>{
      'clientEventId': clientEventId ?? _uuid.v4(),
      'deviceId': deviceId,
      'seenAnonId': seenAnonId,
      'firstSeenAt': firstSeenAt.toUtc().toIso8601String(),
      'lastSeenAt': lastSeenAt.toUtc().toIso8601String(),
      'durationSeconds': durationSeconds,
      'avgRssi': avgRssi,
      'sampleCount': sampleCount,
      // Temas anındaki stand/konum (biliniyorsa). Boşsa hiç gönderme.
      if (locationName != null && locationName.isNotEmpty)
        'locationName': locationName,
    };

    await _enqueueContact(payload);

    try {
      await flushContactQueue();
      final stillPending = await _isContactPending(
        payload['clientEventId'] as String,
      );
      if (!stillPending) {
        debugPrint('✅ [API] Contact gönderildi: $seenAnonId');
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('⚠️ [API] sendContactEvent flush hatası: $e');
      return false;
    }
  }

  Future<void> flushContactQueue() {
    return _withContactQueueLock(() async {
      final queue = await _loadContactQueue();
      if (queue.isEmpty) return;

      // Stale: 7 günden eski kayıtları sil (visit ile aynı eşik).
      final cutoff = DateTime.now().subtract(const Duration(days: 7));
      final fresh = queue.where((item) {
        final raw = item['lastSeenAt'] as String?;
        if (raw == null) return false;
        try {
          return DateTime.parse(raw).isAfter(cutoff);
        } catch (_) {
          return false;
        }
      }).toList();

      final staleCnt = queue.length - fresh.length;
      if (staleCnt > 0) {
        debugPrint('🗑️ [API] $staleCnt eski contact silindi (>7 gün).');
      }
      if (fresh.isEmpty) {
        await _saveContactQueue([]);
        return;
      }

      debugPrint('🔄 [API] Contact queue flush: ${fresh.length} kayıt');

      final remaining = <Map<String, dynamic>>[];

      for (int i = 0; i < fresh.length; i++) {
        final item = fresh[i];
        try {
          final sent = await _postContact(item);
          if (sent) {
            debugPrint('✅ [API] Contact gönderildi: ${item['seenAnonId']}');
          } else {
            remaining.addAll(fresh.sublist(i));
            break;
          }
        } on _PoisonPillException catch (e) {
          debugPrint(
            '🗑️ [API] Contact poison pill (${e.statusCode}), silindi: '
            '${item['seenAnonId']}',
          );
        }
      }

      await _saveContactQueue(remaining);
    });
  }

  Future<int> pendingContactCount() async {
    return (await _loadContactQueue()).length;
  }

  Future<bool> _postContact(Map<String, dynamic> payload) async {
    try {
      final response = await http
          .post(
            Uri.parse('$_baseUrl/contacts'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200 || response.statusCode == 201) {
        return true;
      } else if (response.statusCode == 409) {
        debugPrint('♻️ [API] Contact 409 Conflict, atlanıyor.');
        return true;
      } else if (response.statusCode == 429) {
        debugPrint('⏳ [API] Contact 429 Rate limit.');
        return false;
      } else if (response.statusCode >= 400 && response.statusCode < 500) {
        debugPrint(
          '🗑️ [API] Contact kalıcı hata ${response.statusCode}: ${response.body}',
        );
        throw _PoisonPillException(response.statusCode);
      } else {
        debugPrint(
          '⚠️ [API] Contact sunucu hatası ${response.statusCode}: ${response.body}',
        );
        return false;
      }
    } on _PoisonPillException {
      rethrow;
    } on SocketException catch (e) {
      debugPrint('❌ [API] Contact ağ hatası: $e');
      return false;
    } on HttpException catch (e) {
      debugPrint('❌ [API] Contact HTTP hatası: $e');
      return false;
    } catch (e) {
      debugPrint('❌ [API] Contact bağlantı hatası: $e');
      return false;
    }
  }
}

/// 4xx kalıcı hata sinyali. Bu exception'ı alan flushQueue kaydı kuyruktan siler.
class _PoisonPillException implements Exception {
  final int statusCode;
  const _PoisonPillException(this.statusCode);
}
