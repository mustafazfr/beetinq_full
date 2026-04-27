import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

final deviceIdServiceProvider = Provider<DeviceIdService>((ref) => DeviceIdService());

class DeviceIdService {
  static const _kCachedDeviceId = 'device_id_v1';

  // Uygulama boyunca tek seferlik hesaplanır, sonra bellekte tutulur
  String? _cachedId;

  /// Cihazın anonim, kalıcı ID'sini döndürür.
  ///
  /// iOS  → identifierForVendor (aynı vendor'ın uygulamaları arasında sabit)
  /// Android → androidId (fabrika ayarlarına kadar sabit)
  ///
  /// KVKK/GDPR uyumu için ham ID yerine SHA-256 hash'i kullanılır.
  /// Böylece gerçek cihaz tanımlayıcısı hiçbir yerde saklanmaz.
  Future<String> getDeviceId() async {
    // 1. Bellekte cache varsa direkt döndür
    if (_cachedId != null) return _cachedId!;

    // 2. Disk cache'i kontrol et
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_kCachedDeviceId);
    if (stored != null) {
      _cachedId = stored;
      return _cachedId!;
    }

    // 3. Platformdan raw ID al ve hashle
    final rawId = await _getRawDeviceId();
    final hashed = _sha256(rawId);

    // 4. Diske yaz ve cache'le
    await prefs.setString(_kCachedDeviceId, hashed);
    _cachedId = hashed;

    return _cachedId!;
  }

  Future<String> _getRawDeviceId() async {
    final info = DeviceInfoPlugin();
    try {
      if (Platform.isIOS) {
        final iosInfo = await info.iosInfo;
        // identifierForVendor: uygulama silinip tekrar yüklenirse değişebilir
        // ama aynı cihazda aynı vendor altında sabit kalır
        return iosInfo.identifierForVendor ?? _fallbackId();
      } else if (Platform.isAndroid) {
        final androidInfo = await info.androidInfo;
        // ANDROID_ID: factory reset'e kadar sabit, cihaza özgü kalıcı ID.
        // androidInfo.id KULLANMAYIN — o android.os.Build.ID (build string),
        // model bazlıdır, farklı cihazlarda aynı değeri üretir.
        // androidInfo.androidId bazı device_info_plus versiyonlarında tanımsız
        // olabileceğinden data map üzerinden erişmek en güvenli yol.
        final androidId = androidInfo.data['androidId'] as String?;
        return androidId ?? _fallbackId();
      } else {
        return _fallbackId();
      }
    } catch (e) {
      debugPrint('⚠️ [DeviceId] Platform ID alınamadı, fallback kullanılıyor: $e');
      return _fallbackId();
    }
  }

  /// Platform ID alınamazsa kriptografik olarak güvenli rastgele bir ID üret.
  String _fallbackId() {
    const chars = '0123456789abcdef';
    // BUG FIX: Eski kod microsecondsSinceEpoch tabanlı deterministik LCG
    // kullanıyordu — aynı anda başlayan iki cihaz aynı ID'yi üretebiliyordu.
    // Random.secure() kriptografik RNG kullanır, tahmin edilemez.
    final rng = math.Random.secure();
    final buf = StringBuffer();
    for (int i = 0; i < 32; i++) {
      buf.write(chars[rng.nextInt(chars.length)]);
    }
    return 'fallback_${buf.toString()}';
  }

  String _sha256(String input) {
    final bytes = utf8.encode(input);
    final digest = sha256.convert(bytes);
    return digest.toString();
  }
}
