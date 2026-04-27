import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../beacon/beacon_controller.dart';
import '../beacon/device_id_service.dart';
import '../contact/contact_advertiser.dart';
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

  @override
  void initState() {
    super.initState();
    _loadInitial();
  }

  Future<void> _loadInitial() async {
    final prefs = ref.read(settingsPrefsProvider);
    final loc = await prefs.isLocationEnabled();
    final con = await prefs.isContactEnabled();
    if (!mounted) return;
    setState(() {
      _locationEnabled = loc;
      _contactEnabled = con;
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
    if (value) {
      // Opt-in: advertise'ı başlat. iOS'ta paket kısıtı nedeniyle no-op.
      try {
        final deviceId = await DeviceIdService().getDeviceId();
        await advertiser.start(deviceId);
      } catch (e) {
        debugPrint('contact advertiser start hatası: $e');
      }
    } else {
      // Opt-out: advertise'ı durdur + encounter map'ini temizle.
      // Scanner region'ı sonraki startScanning çağrısında gate ediliyor;
      // şu an ayrıca söküp takmaya gerek yok (ranging callback
      // contactEnabled=false ise event'i düşürüyor zaten).
      await advertiser.stop();
      ref.read(contactControllerProvider.notifier).reset();
    }

    if (mounted) setState(() => _busy = false);
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
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Text(
                    'Gizlilik ve Veri Toplama',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                ),
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
                    'Cihazlar arası yakınlık takibi. (Contact tracing modülü henüz aktif değil.)',
                  ),
                  value: con,
                  onChanged: _busy ? null : _toggleContact,
                ),
                if (_busy)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: LinearProgressIndicator()),
                  ),
              ],
            ),
    );
  }
}
