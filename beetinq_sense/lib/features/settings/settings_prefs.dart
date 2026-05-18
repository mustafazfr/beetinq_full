import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Kullanıcı opt-out tercihleri. KVKK uyumu için iki ayrı switch:
/// konum analizi ve temas analizi bağımsız kapatılabilir.
///
/// Anahtarlar _v1 suffix'i ile; ilerde format değişirse _v2'ye geçilir,
/// eski kullanıcıların tercihi kaybolmaz ama yeni default devreye girer.
class SettingsPrefs {
  static const _kLocationEnabledKey = 'analysis_location_enabled_v1';
  static const _kContactEnabledKey = 'analysis_contact_enabled_v1';
  // Server URL runtime ayarı (Task 2.14). Saha günü farklı ağda
  // (fakülte WiFi, hotspot vs.) backend IP'si değiştiğinde uygulamayı
  // yeniden derlemeden ayarlanabilsin diye SharedPreferences'a yazılır.
  // Boş veya null ise ApiService default'una (_lanIp:3000/api) düşer.
  static const _kServerBaseUrlKey = 'server_base_url_v1';

  // Default: true. Yeni kurulumda tarama açık; kullanıcı kapatmak isterse
  // ayarlar ekranından opt-out edebilir.
  static const _kDefaultLocationEnabled = true;
  static const _kDefaultContactEnabled = true;

  Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  Future<bool> isLocationEnabled() async {
    final sp = await _prefs;
    return sp.getBool(_kLocationEnabledKey) ?? _kDefaultLocationEnabled;
  }

  Future<void> setLocationEnabled(bool value) async {
    final sp = await _prefs;
    await sp.setBool(_kLocationEnabledKey, value);
  }

  Future<bool> isContactEnabled() async {
    final sp = await _prefs;
    return sp.getBool(_kContactEnabledKey) ?? _kDefaultContactEnabled;
  }

  Future<void> setContactEnabled(bool value) async {
    final sp = await _prefs;
    await sp.setBool(_kContactEnabledKey, value);
  }

  /// Saha gününde değişen LAN IP / port için override.
  /// Boş string veya null → ApiService default'u kullanılır.
  Future<String?> getServerBaseUrl() async {
    final sp = await _prefs;
    final v = sp.getString(_kServerBaseUrlKey);
    if (v == null || v.trim().isEmpty) return null;
    return v.trim();
  }

  Future<void> setServerBaseUrl(String? value) async {
    final sp = await _prefs;
    final clean = value?.trim();
    if (clean == null || clean.isEmpty) {
      await sp.remove(_kServerBaseUrlKey);
    } else {
      await sp.setString(_kServerBaseUrlKey, clean);
    }
  }
}

final settingsPrefsProvider = Provider<SettingsPrefs>((ref) => SettingsPrefs());
