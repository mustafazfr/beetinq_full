import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'beacon_config.dart';
import '../../core/positioning/fingerprint_engine.dart';
import '../../core/positioning/trilateration_engine.dart';

class BeaconPrefs {
  static const _kTargetKey = 'beacon_target_v1';
  static const _kFingerprintsKey = 'fingerprints_v1';
  static const _kBeaconLocationsKey = 'beacon_locations_v1';
  static const _sessionLocationKey = 'session_location';
  static const _sessionStartTimeKey = 'session_start_time';

  /// Wipe button (test/demo): tüm yerel veri kayıtlarını siler.
  /// KORUNAN: opt-out switch'leri (kullanıcı tercihi, test datası değil).
  static const _dataKeys = <String>[
    _kTargetKey,
    _kFingerprintsKey,
    _kBeaconLocationsKey,
    _sessionLocationKey,
    _sessionStartTimeKey,
    _sessionPositionSourceKey,
    _sessionTrilaterationXKey,
    _sessionTrilaterationYKey,
    _sessionLastSeenTimeKey,
    'offline_visit_queue_v2',
    'offline_contact_queue_v1',
  ];

  Future<void> wipeAllData() async {
    final sp = await SharedPreferences.getInstance();
    for (final k in _dataKeys) {
      await sp.remove(k);
    }
  }

  // ─── TARGET ───────────────────────────────────────────────

  Future<BeaconTarget?> loadTarget() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_kTargetKey);
    if (raw == null) return null;
    return BeaconTarget.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<void> saveTarget(BeaconTarget target) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kTargetKey, jsonEncode(target.toJson()));
  }

  // ─── SESSION ──────────────────────────────────────────────

  static const _sessionPositionSourceKey = 'session_position_source';
  static const _sessionTrilaterationXKey = 'session_trilateration_x';
  static const _sessionTrilaterationYKey = 'session_trilateration_y';
  static const _sessionLastSeenTimeKey   = 'session_last_seen_time';

  Future<void> saveCurrentSession(
      String? location,
      DateTime? startTime, {
        String? positionSource,
        double? trilaterationX,
        double? trilaterationY,
        DateTime? lastSeenTime,   // ← beacon'ın son görüldüğü zaman; stale kontrolü için
      }) async {
    final prefs = await SharedPreferences.getInstance();
    if (location == null || startTime == null) {
      await prefs.remove(_sessionLocationKey);
      await prefs.remove(_sessionStartTimeKey);
      await prefs.remove(_sessionPositionSourceKey);
      await prefs.remove(_sessionTrilaterationXKey);
      await prefs.remove(_sessionTrilaterationYKey);
      await prefs.remove(_sessionLastSeenTimeKey);
    } else {
      await prefs.setString(_sessionLocationKey, location);
      await prefs.setString(_sessionStartTimeKey, startTime.toIso8601String());
      if (positionSource != null) {
        await prefs.setString(_sessionPositionSourceKey, positionSource);
      } else {
        await prefs.remove(_sessionPositionSourceKey);
      }
      if (trilaterationX != null) {
        await prefs.setDouble(_sessionTrilaterationXKey, trilaterationX);
      } else {
        await prefs.remove(_sessionTrilaterationXKey);
      }
      if (trilaterationY != null) {
        await prefs.setDouble(_sessionTrilaterationYKey, trilaterationY);
      } else {
        await prefs.remove(_sessionTrilaterationYKey);
      }
      // lastSeenTime yoksa startTime kullan — en kötü ihtimal startTime'dan hesap yapılır
      final seen = lastSeenTime ?? startTime;
      await prefs.setString(_sessionLastSeenTimeKey, seen.toIso8601String());
    }
  }

  /// Aktif oturumu diskten siler.
  Future<void> clearCurrentSession() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_sessionLocationKey);
    await prefs.remove(_sessionStartTimeKey);
    await prefs.remove(_sessionPositionSourceKey);
    await prefs.remove(_sessionTrilaterationXKey);
    await prefs.remove(_sessionTrilaterationYKey);
    await prefs.remove(_sessionLastSeenTimeKey);
  }

  Future<Map<String, dynamic>?> loadCurrentSession() async {
    final prefs = await SharedPreferences.getInstance();
    final location = prefs.getString(_sessionLocationKey);
    final startTimeStr = prefs.getString(_sessionStartTimeKey);
    if (location != null && startTimeStr != null) {
      return {
        'location': location,
        'startTime': DateTime.tryParse(startTimeStr),
        'positionSource': prefs.getString(_sessionPositionSourceKey),
        'trilaterationX': prefs.getDouble(_sessionTrilaterationXKey),
        'trilaterationY': prefs.getDouble(_sessionTrilaterationYKey),
        'lastSeenTime': DateTime.tryParse(
          prefs.getString(_sessionLastSeenTimeKey) ?? startTimeStr,
        ),
      };
    }
    return null;
  }

  // ─── FINGERPRINTS ─────────────────────────────────────────

  Future<void> saveFingerprints(List<Fingerprint> fingerprints) async {
    final prefs = await SharedPreferences.getInstance();
    final jsonList = fingerprints.map((fp) => fp.toJson()).toList();
    await prefs.setString(_kFingerprintsKey, jsonEncode(jsonList));
  }

  Future<List<Fingerprint>> loadFingerprints() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kFingerprintsKey);
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => Fingerprint.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('⚠️ [BeaconPrefs] Fingerprint JSON parse hatası, veri siliniyor: $e');
      await prefs.remove(_kFingerprintsKey);
      return [];
    }
  }

  // ─── BEACON LOCATIONS (Trilaterasyon için) ────────────────

  Future<void> saveBeaconLocations(List<BeaconLocation> locations) async {
    final prefs = await SharedPreferences.getInstance();
    final jsonList = locations.map((l) => l.toJson()).toList();
    await prefs.setString(_kBeaconLocationsKey, jsonEncode(jsonList));
  }

  Future<List<BeaconLocation>> loadBeaconLocations() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kBeaconLocationsKey);
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => BeaconLocation.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('⚠️ [BeaconPrefs] BeaconLocations JSON parse hatası, veri siliniyor: $e');
      await prefs.remove(_kBeaconLocationsKey);
      return [];
    }
  }
}
