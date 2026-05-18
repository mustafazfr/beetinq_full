import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../beacon/api_service.dart';
import '../beacon/beacon_controller.dart';
import '../beacon/device_id_service.dart';
import '../contact/contact_advertiser.dart';
import '../contact/contact_ble_scanner.dart';
import '../contact/contact_controller.dart';
import 'settings_prefs.dart';

/// Ayarlar ekranı. İki bağımsız switch ile kullanıcı konum ve temas
/// analizini ayrı ayrı kapatabilir (KVKK opt-out).
///
/// Konum switch'i kapandığında BeaconController.stop() çağrılır —
/// bu metod aktif session'ı API'ye flush'lar, sonra tarayıcıyı durdurur.
/// Açıldığında initSdk() çağrılır; kayıtlı target varsa tarama
/// otomatik başlar (guard startScanning içinde).
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  bool? _locationEnabled;
  bool? _contactEnabled;
  bool _busy = false;

  // Server URL ayarı (Task 2.14): saha günü hotspot/WiFi değiştiğinde
  // uygulamayı tekrar derlemeden ayarlanabilir.
  final TextEditingController _serverUrlCtrl = TextEditingController();
  bool _serverUrlDirty = false;
  // Otomatik keşif (Task 2.19): subnet scan in-flight göstergesi.
  bool _discovering = false;

  // Battery optimization status (Task 2.15): Android'de "whitelist" muafiyeti.
  // iOS'ta görünmez. permission_handler ile sorgulanır.
  bool? _batteryWhitelisted;

  @override
  void initState() {
    super.initState();
    _loadInitial();
  }

  @override
  void dispose() {
    _serverUrlCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadInitial() async {
    final prefs = ref.read(settingsPrefsProvider);
    final loc = await prefs.isLocationEnabled();
    final con = await prefs.isContactEnabled();
    final url = await prefs.getServerBaseUrl();

    // Battery whitelist sadece Android'de anlamlı; iOS'ta status sorgusu
    // unknown/denied dönebilir, yine de UI gizleyeceğiz.
    bool? battery;
    if (Platform.isAndroid) {
      final status = await Permission.ignoreBatteryOptimizations.status;
      battery = status.isGranted;
    }

    if (!mounted) return;
    setState(() {
      _locationEnabled = loc;
      _contactEnabled = con;
      _serverUrlCtrl.text = url ?? '';
      _serverUrlDirty = false;
      _batteryWhitelisted = battery;
    });
  }

  Future<void> _toggleLocation(bool value) async {
    if (_busy) return;
    setState(() => _busy = true);

    final prefs = ref.read(settingsPrefsProvider);
    await prefs.setLocationEnabled(value);
    setState(() => _locationEnabled = value);

    final ctrl = ref.read(beaconControllerProvider.notifier);
    if (value) {
      // Opt-in: SDK'yı yeniden başlat. Hedef kayıtlıysa tarama kendiliğinden döner.
      await ctrl.initSdk();
    } else {
      // Opt-out: stop() aktif session'ı önce API'ye gönderir, sonra tarayıcıyı durdurur.
      await ctrl.stop();
    }

    if (mounted) setState(() => _busy = false);
  }

  Future<void> _toggleContact(bool value) async {
    if (_busy) return;
    setState(() => _busy = true);

    final prefs = ref.read(settingsPrefsProvider);
    await prefs.setContactEnabled(value);
    setState(() => _contactEnabled = value);

    ref.read(beaconControllerProvider.notifier).setContactEnabledCache(value);

    final advertiser = ref.read(contactAdvertiserProvider);
    final scanner = ref.read(contactBleScannerProvider);
    if (value) {
      // Opt-in: advertise'ı + flutter_blue_plus scanner'ı başlat.
      // Android = iBeacon advertise, iOS = service UUID + local name (Task 2.18).
      try {
        final deviceId = await DeviceIdService().getDeviceId();
        await advertiser.start(deviceId);
        await scanner.start(
          selfDeviceIdHash: deviceId,
          onEncounter: (anonId, rssi, now) {
            ref
                .read(contactControllerProvider.notifier)
                .onEncounterEvent(anonId, rssi, now);
          },
        );
      } catch (e) {
        debugPrint('contact advertiser/scanner start hatası: $e');
      }
    } else {
      // Opt-out: advertise'ı + scanner'ı durdur + encounter map'ini temizle.
      // Ranging callback'i opt-out flag'ini hem _contactEnabledCache hem
      // scanner cache üzerinden anında görür → event'ler düşürülür.
      await advertiser.stop();
      await scanner.stop();
      ref.read(contactControllerProvider.notifier).reset();
    }

    if (mounted) setState(() => _busy = false);
  }

  /// Subnet scan ile backend'i bul. Bulunursa hem text field'ı doldurur
  /// hem de cache + SharedPreferences'a yazar. Bulamazsa snackbar uyarısı.
  Future<void> _autoDiscoverServer() async {
    if (_discovering || _busy) return;
    setState(() => _discovering = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final url = await ApiService.tryAutoDiscover();
      if (!mounted) return;
      if (url != null) {
        // Settings prefs'i de senkronize tut.
        await ref.read(settingsPrefsProvider).setServerBaseUrl(url);
        setState(() {
          _serverUrlCtrl.text = url;
          _serverUrlDirty = false;
          _discovering = false;
        });
        messenger.showSnackBar(
          SnackBar(
            content: Text('🌐 Backend bulundu: $url'),
            backgroundColor: Colors.green,
          ),
        );
      } else {
        setState(() => _discovering = false);
        messenger.showSnackBar(
          const SnackBar(
            content: Text(
              'Backend ağda bulunamadı. Aynı WiFi/hotspot\'ta olduğunu '
              'doğrula veya IP\'yi elle gir.',
            ),
            backgroundColor: Colors.orange,
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _discovering = false);
      messenger.showSnackBar(
        SnackBar(content: Text('Otomatik keşif hatası: $e')),
      );
    }
  }

  Future<void> _saveServerUrl() async {
    if (_busy) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);

    final raw = _serverUrlCtrl.text.trim();
    try {
      // Hem ApiService static cache hem de SettingsPrefs anahtarı güncellenir.
      // ApiService.setServerUrl SharedPreferences yazıyor; SettingsPrefs ayrı
      // tutmaya gerek yok, ama future-proof olarak da yazıyoruz.
      await ApiService.setServerUrl(raw.isEmpty ? null : raw);
      await ref.read(settingsPrefsProvider).setServerBaseUrl(
            raw.isEmpty ? null : raw,
          );
      if (!mounted) return;
      setState(() {
        _serverUrlDirty = false;
        _busy = false;
      });
      messenger.showSnackBar(
        SnackBar(
          content: Text(raw.isEmpty
              ? '🌐 Sunucu adresi varsayılana döndü.'
              : '🌐 Sunucu adresi kaydedildi.'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      messenger.showSnackBar(
        SnackBar(content: Text('❌ Sunucu adresi kaydedilemedi: $e')),
      );
    }
  }

  /// Mevcut kullanıcıya pil optimizasyonu muafiyeti diyaloğu açar.
  /// Android'in OS settings'ine yönlendirir. iOS'ta no-op (buton zaten gizli).
  Future<void> _requestBatteryWhitelist() async {
    if (_busy) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final status = await Permission.ignoreBatteryOptimizations.request();
      if (!mounted) return;
      setState(() {
        _batteryWhitelisted = status.isGranted;
        _busy = false;
      });
      messenger.showSnackBar(
        SnackBar(
          content: Text(status.isGranted
              ? '✅ Pil optimizasyonu kapatıldı.'
              : '⚠️ Pil optimizasyonu açık. Arka plan ölme riski var.'),
          backgroundColor: status.isGranted ? Colors.green : Colors.orange,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      messenger.showSnackBar(
        SnackBar(content: Text('Pil ayarı hatası: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = _locationEnabled;
    final con = _contactEnabled;
    final loaded = loc != null && con != null;

    return Scaffold(
      appBar: AppBar(title: const Text('Ayarlar')),
      body: !loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                const _SectionHeader('Gizlilik ve Veri Toplama'),
                Card(
                  margin: const EdgeInsets.symmetric(horizontal: 12),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      'KVKK kapsamında konum ve temas analizi istediğin zaman '
                      'kapatabilirsin. Kapattığında o ana kadar toplanan ziyaret '
                      'verisi sunucuya gönderilir; ardından yeni veri toplanmaz. '
                      'Sunucudaki kayıtlar 14 gün sonra otomatik silinir.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  title: const Text('Konum Analizi'),
                  subtitle: const Text(
                    'Stand ziyaretleri ve dwell time ölçümü. Kapattığında beacon taraması durur.',
                  ),
                  value: loc,
                  onChanged: _busy ? null : _toggleLocation,
                ),
                const Divider(height: 0),
                SwitchListTile(
                  title: const Text('Temas Analizi'),
                  subtitle: const Text(
                    'Cihazlar arası yakınlık takibi. iOS\'ta sadece scanner olarak çalışır.',
                  ),
                  value: con,
                  onChanged: _busy ? null : _toggleContact,
                ),

                // ── Sistem Ayarları ────────────────────────────────────
                const _SectionHeader('Sistem Ayarları'),
                Card(
                  margin: const EdgeInsets.symmetric(horizontal: 12),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Sunucu Adresi',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Colors.blue.shade900,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Saha günü WiFi/hotspot değişirse "Otomatik Bul" butonuna '
                          'bas veya buraya yeni IP/URL yaz. Boş bırakırsan uygulama '
                          'varsayılan adrese (geliştirici LAN IP\'si) düşer.',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.blue.shade900,
                          ),
                        ),
                        const SizedBox(height: 10),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: _discovering || _busy
                                ? null
                                : _autoDiscoverServer,
                            icon: _discovering
                                ? const SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2),
                                  )
                                : const Icon(Icons.search, size: 16),
                            label: Text(_discovering
                                ? 'Ağ taranıyor…'
                                : '🔍 Otomatik Bul (subnet scan)'),
                          ),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: _serverUrlCtrl,
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            isDense: true,
                            labelText: 'IP veya URL',
                            hintText: '192.168.1.42  ·  192.168.1.42:3000  ·  https://api.example.com/api',
                          ),
                          keyboardType: TextInputType.url,
                          inputFormatters: [
                            // Boşluk önleyici filtre.
                            FilteringTextInputFormatter.deny(RegExp(r'\s')),
                          ],
                          autocorrect: false,
                          onChanged: (_) {
                            if (!_serverUrlDirty) {
                              setState(() => _serverUrlDirty = true);
                            }
                          },
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            ElevatedButton.icon(
                              icon: const Icon(Icons.save_outlined, size: 16),
                              label: const Text('Kaydet'),
                              onPressed: _busy || !_serverUrlDirty
                                  ? null
                                  : _saveServerUrl,
                            ),
                            const SizedBox(width: 8),
                            TextButton(
                              onPressed: _busy
                                  ? null
                                  : () {
                                      setState(() {
                                        _serverUrlCtrl.clear();
                                        _serverUrlDirty = true;
                                      });
                                    },
                              child: const Text('Temizle'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),

                if (Platform.isAndroid) ...[
                  const SizedBox(height: 8),
                  Card(
                    margin: const EdgeInsets.symmetric(horizontal: 12),
                    color: _batteryWhitelisted == true
                        ? Colors.green.shade50
                        : Colors.orange.shade50,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                _batteryWhitelisted == true
                                    ? Icons.battery_full
                                    : Icons.battery_alert,
                                color: _batteryWhitelisted == true
                                    ? Colors.green.shade700
                                    : Colors.orange.shade800,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                'Pil Optimizasyonu',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: _batteryWhitelisted == true
                                      ? Colors.green.shade900
                                      : Colors.orange.shade900,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            _batteryWhitelisted == true
                                ? 'Uygulama pil optimizasyonundan muaf. Arka plan tarama '
                                    'kesintisiz çalışır.'
                                : 'Bazı cihazlar (Xiaomi, Huawei, Samsung) pil optimizasyonu '
                                    'açıkken arka plan tarayıcıyı sessizce öldürür. Saha '
                                    'günü kesintisiz tarama için muafiyet ver.',
                            style: TextStyle(
                              fontSize: 12,
                              color: _batteryWhitelisted == true
                                  ? Colors.green.shade900
                                  : Colors.orange.shade900,
                            ),
                          ),
                          const SizedBox(height: 10),
                          if (_batteryWhitelisted != true)
                            SizedBox(
                              width: double.infinity,
                              child: ElevatedButton.icon(
                                onPressed:
                                    _busy ? null : _requestBatteryWhitelist,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.orange.shade700,
                                  foregroundColor: Colors.white,
                                ),
                                icon: const Icon(Icons.power_settings_new),
                                label: const Text(
                                    'Pil optimizasyonunu kapat'),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],

                if (_busy)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: LinearProgressIndicator()),
                  ),

                // ── Test Araçları ──────────────────────────────────────
                const _SectionHeader('Test Araçları'),
                Card(
                  margin: const EdgeInsets.symmetric(horizontal: 12),
                  color: Colors.red.shade50,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Tüm test verisini sil',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Colors.red.shade900,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Bu telefondaki: kayıtlı UUID, fingerprint snapshot\'ları, '
                          'beacon koordinatları, aktif session, offline kuyruklar.\n'
                          'Sunucudaki: tüm visit, contact, stand, beacon kayıtları.\n\n'
                          'Geri alınamaz.',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.red.shade900,
                          ),
                        ),
                        const SizedBox(height: 10),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed: _busy ? null : _wipeAll,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.red.shade600,
                              foregroundColor: Colors.white,
                            ),
                            icon: const Icon(Icons.delete_forever),
                            label: const Text('Hepsini Sıfırla'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),
              ],
            ),
    );
  }

  Future<void> _wipeAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Emin misin?'),
        content: const Text(
          'Telefon ve sunucudaki tüm test verileri silinecek. '
          'Bu işlem GERİ ALINAMAZ.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('İptal'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Evet, sil'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);

    // 1) Sunucu wipe — fail olsa da local'e devam et
    final api = ref.read(apiServiceProvider);
    final serverOk = await api.wipeServerData();

    // 2) Local wipe (controller state + SharedPreferences)
    // NOT: SharedPreferences key'ler arasında server_base_url_v1 KORUNMUYOR —
    // BeaconPrefs.wipeAllData liste sadece DATA anahtarlarını siliyor (server URL
    // kullanıcı tercihi, test datası değil). Eski davranış korundu.
    await ref.read(beaconControllerProvider.notifier).wipeAndReset();

    if (!mounted) return;
    setState(() => _busy = false);

    messenger.showSnackBar(
      SnackBar(
        content: Text(serverOk
            ? '✅ Tüm veriler silindi (telefon + sunucu)'
            : '⚠️ Telefon temizlendi, sunucuya ulaşılamadı (ağı kontrol et).'),
        backgroundColor: serverOk ? Colors.green : Colors.orange,
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String label;
  const _SectionHeader(this.label);
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

