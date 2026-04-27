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
}

final settingsPrefsProvider = Provider<SettingsPrefs>((ref) => SettingsPrefs());
