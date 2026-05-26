import 'dart:async';
import 'dart:io';

import 'package:dchs_flutter_beacon/dchs_flutter_beacon.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api_service.dart';
import 'beacon_controller.dart';
import '../contact/contact_controller.dart';
import '../settings/settings_page.dart';

/// Raw Dart exception mesajlarını kullanıcının anlayabileceği kısa
/// Türkçe ifadelere çevirir (Task 3.2). Bilinmeyen hatalar olduğu
/// gibi (sadece "Exception:" prefix'i strip'lenmiş) geri döner.
String _friendlyError(String raw) {
  var m = raw.replaceFirst(RegExp(r'^Exception:\s*'), '');
  if (m.contains('BeaconInitException')) {
    return 'Beacon sistemi başlatılamadı. Bluetooth ve konum izinlerini kontrol et.';
  }
  if (m.contains('MissingPluginException')) {
    return 'Native eklenti yüklenemedi. Uygulamayı yeniden başlat.';
  }
  if (m.toLowerCase().contains('bluetooth') && m.toLowerCase().contains('off')) {
    return 'Bluetooth kapalı. Açıp tekrar dene.';
  }
  if (m.toLowerCase().contains('permission')) {
    return 'Gerekli izinler verilmedi. Ayarlardan izinleri aç.';
  }
  return m;
}

class BeaconPage extends ConsumerStatefulWidget {
  const BeaconPage({super.key});

  @override
  ConsumerState<BeaconPage> createState() => _BeaconPageState();
}

class _BeaconPageState extends ConsumerState<BeaconPage> {
  @override
  void initState() {
    super.initState();
    // UUID gömülü (kDefaultBeaconUuid): açılışta initSdk otomatik varsayılan
    // target ile taramayı başlatır. Elle UUID girişi yok.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(beaconControllerProvider.notifier).initSdk();
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(beaconControllerProvider);
    final ctrl = ref.read(beaconControllerProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Beetinq Sense'),
        actions: [
          // Manuel senkron: fingerprint + beacon koordinatlarını backend'den çek.
          IconButton(
            icon: const Icon(Icons.sync),
            tooltip: 'Senkronize Et',
            onPressed: () async {
              final messenger = ScaffoldMessenger.of(context);
              messenger.showSnackBar(const SnackBar(
                content: Text('🔄 Senkronize ediliyor…'),
                duration: Duration(seconds: 1),
              ));
              final r = await ctrl.syncAllFromBackend();
              if (!context.mounted) return;
              messenger.showSnackBar(SnackBar(
                content: Text(
                    '✅ Senkronize edildi: ${r.fingerprints} konum · ${r.beacons} beacon'),
                backgroundColor: Colors.green,
              ));
            },
          ),
          // Gizlilik ayarları (KVKK opt-out)
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Ayarlar',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsPage()),
            ),
          ),
          // Beacon koordinat yönetimi (Trilaterasyon)
          IconButton(
            icon: const Icon(Icons.settings_input_antenna),
            tooltip: 'Beacon Koordinatları',
            onPressed: () => showModalBottomSheet(
              context: context,
              isScrollControlled: true,
              builder: (ctx) => const _BeaconLocationsSheet(),
            ),
          ),
          // Kayıtlı fingerprint listesi
          IconButton(
            icon: const Icon(Icons.format_list_bulleted),
            tooltip: 'Kayıtlı Konumlar',
            onPressed: () => showModalBottomSheet(
              context: context,
              isScrollControlled: true,
              builder: (ctx) => const _FingerprintListSheet(),
            ),
          ),
          // Fingerprint kaydet
          IconButton(
            icon: const Icon(Icons.add_location_alt),
            tooltip: 'Konum Kaydet',
            onPressed: () async {
              final result = await showDialog<String>(
                context: context,
                builder: (ctx) => const _SaveFingerprintDialog(),
              );

              if (result != null && result.isNotEmpty && context.mounted) {
                final success = await ctrl.saveCurrentFingerprint(result);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(success
                          ? '✅ Kaydedildi: $result'
                          : '❌ Hata: Yeterli aktif beacon yok!'),
                      backgroundColor: success ? Colors.green : Colors.red,
                    ),
                  );
                }
              }
            },
          ),
        ],
      ),
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () => FocusScope.of(context).unfocus(),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: ListView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            children: [
              // ── SUNUCU BAĞLANTI DURUMU ────────────────────────────────
              const _ConnectionIndicator(),
              const SizedBox(height: 12),
              // ── CONTACT TRACING GÖSTERGEÇ ─────────────────────────────
              const _ContactIndicator(),
              const SizedBox(height: 12),

              // ── SİSTEM DURUMU ────────────────────────────────────────
              _Section(
                title: 'Sistem Durumu',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _StatusRow(
                              label: 'SDK',
                              ok: state.initialized,
                            ),
                            _StatusRow(
                              label: 'Bluetooth',
                              ok: state.bluetoothState == BluetoothState.stateOn,
                              value: state.bluetoothState?.toString().replaceAll('BluetoothState.', ''),
                            ),
                            _StatusRow(
                              label: 'İzin',
                              // BUG FIX: Android izni verince AuthorizationStatus.allowed
                              // döndürür (iOS'taki always/whenInUse karşılığı). Eskiden
                              // sadece always/whenInUse yeşil sayılıyordu → Android'de
                              // izin verilse de "ALLOWED" yazıp kırmızı kalıyordu.
                              ok: state.authorizationStatus == AuthorizationStatus.always ||
                                  state.authorizationStatus == AuthorizationStatus.whenInUse ||
                                  state.authorizationStatus == AuthorizationStatus.allowed,
                              value: state.authorizationStatus?.toString().replaceAll('AuthorizationStatus.', ''),
                            ),
                            // iOS arka plan ranging için Always zorunlu.
                            // WhenInUse ile çalışır ama ekran kilidi/başka uygulama
                            // anında ranging durur. Kullanıcıyı bilgilendir.
                            if (Platform.isIOS &&
                                state.authorizationStatus ==
                                    AuthorizationStatus.whenInUse)
                              const Padding(
                                padding: EdgeInsets.only(left: 20, top: 4),
                                child: Text(
                                  '⚠️ Arka plan tarama için "Her zaman" izni gerekli '
                                  '(Ayarlar → Beetinq → Konum → Her zaman).',
                                  style: TextStyle(
                                      fontSize: 11, color: Colors.orange),
                                ),
                              ),
                            // Monitoring yalnızca iOS'ta kullanılıyor (region
                            // monitoring). Android sadece sürekli ranging yapar,
                            // bu yüzden state.monitoring hep false kalır →
                            // satırı Android'de gösterme (yanıltıcı kırmızı ❌).
                            if (Platform.isIOS)
                              _StatusRow(label: 'Monitoring', ok: state.monitoring),
                            _StatusRow(label: 'Ranging', ok: state.ranging),
                            // Temas alt sistem durumları — sahada "Yayın/Tarama
                            // gerçekten çalışıyor mu?" net görünsün. Temas
                            // analizi opt-out kapalıyken ikisi de kırmızı (normal).
                            _StatusRow(label: 'Temas Yayını', ok: state.contactAdvertising),
                            _StatusRow(label: 'Temas Taraması', ok: state.contactScanning),
                          ],
                        ),
                        if (state.initialized)
                          OutlinedButton(
                            onPressed: ctrl.stop,
                            child: const Text('Durdur',
                                style: TextStyle(color: Colors.red)),
                          ),
                      ],
                    ),
                    if (state.monitoringResults.isNotEmpty) ...[
                      const Divider(height: 16),
                      ...state.monitoringResults
                          .where((e) =>
                      e.monitoringEventType == MonitoringEventType.didEnterRegion ||
                          e.monitoringEventType == MonitoringEventType.didExitRegion)
                          .map((e) {
                        final isEnter = e.monitoringEventType ==
                            MonitoringEventType.didEnterRegion;
                        return Row(
                          children: [
                            Icon(
                              isEnter ? Icons.login : Icons.logout,
                              size: 14,
                              color: isEnter ? Colors.green : Colors.red,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '${e.region.identifier} — ${isEnter ? "Giriş" : "Çıkış"}',
                              style: const TextStyle(fontSize: 12),
                            ),
                          ],
                        );
                      }),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 12),

              // ── KONUM TAHMİNİ ────────────────────────────────────────
              _Section(
                title: 'Konum',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _LocationCard(state: state),
                    if (state.currentSessionStart != null) ...[
                      const SizedBox(height: 8),
                      _DwellTime(startTime: state.currentSessionStart!),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 12),

              // ── EN YAKIN BEACON'LAR ───────────────────────────────────
              _Section(
                title: 'En Yakın Beacon\'lar',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (state.top3.isEmpty)
                      const Text('Veri bekleniyor...',
                          style: TextStyle(color: Colors.grey))
                    else
                      ...state.top3.map((b) => _BeaconTile(beacon: b, highlight: true)),
                    if (state.beacons.length > 3) ...[
                      const Divider(height: 16),
                      Text('Tüm beacon\'lar (${state.beacons.length})',
                          style: Theme.of(context).textTheme.labelMedium),
                      const SizedBox(height: 4),
                      ...state.beacons.skip(3).map((b) => _BeaconTile(beacon: b, highlight: false)),
                    ],
                  ],
                ),
              ),

              // ── HATA KARTI ───────────────────────────────────────────
              if (state.error != null) ...[
                const SizedBox(height: 12),
                _ErrorCard(
                  message: _friendlyError(state.error!),
                  errorType: state.errorType,
                  onRetry: () => ctrl.initSdk(),
                  onOpenSettings: () => ctrl.openSettings(),
                ),
              ],

              // ── OFFLINE KUYRUK BANNERI (Task 3.2) ───────────────────
              const SizedBox(height: 12),
              const _OfflineQueueBanner(),

              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}

// ── YENİ: BEACON LOKASYONLARI EKRANI (Trilaterasyon) ─────────────────────
// Çökmeyi (dependents.isEmpty) önlemek için ayrı bir StatefulWidget yapıldı.
class _BeaconLocationsSheet extends ConsumerStatefulWidget {
  const _BeaconLocationsSheet();

  @override
  ConsumerState<_BeaconLocationsSheet> createState() => _BeaconLocationsSheetState();
}

class _BeaconLocationsSheetState extends ConsumerState<_BeaconLocationsSheet> {
  late final TextEditingController idCtrl;
  late final TextEditingController nameCtrl;
  late final TextEditingController xCtrl;
  late final TextEditingController yCtrl;

  @override
  void initState() {
    super.initState();
    idCtrl = TextEditingController();
    nameCtrl = TextEditingController();
    xCtrl = TextEditingController();
    yCtrl = TextEditingController();
  }

  @override
  void dispose() {
    idCtrl.dispose();
    nameCtrl.dispose();
    xCtrl.dispose();
    yCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(beaconControllerProvider);
    final ctrl = ref.read(beaconControllerProvider.notifier);
    final locationList = state.beaconLocations;

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(context).bottom,
        left: 16, right: 16, top: 16,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Beacon Koordinatları (Trilaterasyon)',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (state.beacons.isNotEmpty) ...[
              Text('Aktif Beacon\'lardan Seç:',
                  style: Theme.of(context).textTheme.labelMedium),
              const SizedBox(height: 4),
              Wrap(
                spacing: 6,
                children: state.beacons
                    .where((b) => b.lifecycle == BeaconLifecycle.active)
                    .map((b) => ActionChip(
                  label: Text('M:${b.major} m:${b.minor}',
                      style: const TextStyle(fontSize: 11)),
                  onPressed: () {
                    idCtrl.text = b.key;
                  },
                ))
                    .toList(),
              ),
              const SizedBox(height: 8),
            ],
            TextField(
              controller: idCtrl,
              decoration: const InputDecoration(
                labelText: 'Beacon ID (uuid-major-minor)',
                hintText: 'E2C56DB5-...-1-1',
              ),
              autocorrect: false,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(
                labelText: 'Stand Adı (opsiyonel)',
                hintText: 'A Salonu, Giriş...',
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: xCtrl,
                    decoration: const InputDecoration(
                      labelText: 'X (metre, opsiyonel)',
                      hintText: 'Boşsa otomatik',
                    ),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                    // Türkçe klavyede ondalık ayraç virgül; nokta da kabul.
                    // Parse aşamasında ',' → '.' normalize edilir.
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: yCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Y (metre, opsiyonel)',
                      hintText: 'Boşsa otomatik',
                    ),
                    keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              'X ve Y boş bırakılırsa sunucu beacon\'u otomatik bir grid '
              'pozisyonuna yerleştirir. Konumu admin panelden sürükleyerek düzeltebilirsin.',
              style: TextStyle(fontSize: 11, color: Colors.grey),
            ),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              icon: const Icon(Icons.add_location),
              label: const Text('Ekle / Güncelle'),
              onPressed: () async {
                final id = idCtrl.text.trim().toUpperCase();
                // ',' → '.' normalize: Türkçe locale virgül, double.tryParse nokta bekler.
                final x = double.tryParse(xCtrl.text.trim().replaceAll(',', '.'));
                final y = double.tryParse(yCtrl.text.trim().replaceAll(',', '.'));
                if (id.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Beacon ID zorunlu.')),
                  );
                  return;
                }
                final name = nameCtrl.text.trim();
                final messenger = ScaffoldMessenger.of(context);
                try {
                  await ctrl.addBeaconLocation(
                    id: id,
                    x: x,
                    y: y,
                    name: name.isEmpty ? null : name,
                  );
                  idCtrl.clear();
                  nameCtrl.clear();
                  xCtrl.clear();
                  yCtrl.clear();
                  messenger.showSnackBar(
                    SnackBar(
                      content: Text(x == null || y == null
                          ? '✅ Eklendi (otomatik grid). Admin panelden sürükle.'
                          : '✅ Eklendi (sunucu + telefon).'),
                      backgroundColor: Colors.green,
                    ),
                  );
                } catch (e) {
                  messenger.showSnackBar(
                    SnackBar(
                      content: Text('❌ ${e.toString().replaceFirst('Exception: ', '')}'),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              },
            ),
            const Divider(),
            if (locationList.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('Henüz koordinat girilmedi.',
                    style: TextStyle(color: Colors.grey)),
              )
            else
              ...locationList.map((l) => ListTile(
                dense: true,
                title: Text(l.id, style: const TextStyle(fontSize: 11)),
                subtitle: Text('x: ${l.x}m  y: ${l.y}m'),
                trailing: IconButton(
                  icon: const Icon(Icons.delete, color: Colors.red, size: 20),
                  onPressed: () async {
                    final messenger = ScaffoldMessenger.of(context);
                    try {
                      await ctrl.removeBeaconLocation(l.id);
                    } catch (e) {
                      messenger.showSnackBar(
                        SnackBar(
                          content: Text('❌ ${e.toString().replaceFirst('Exception: ', '')}'),
                          backgroundColor: Colors.red,
                        ),
                      );
                    }
                  },
                ),
              )),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}

// ── YENİ: KAYITLI FINGERPRINT LİSTESİ EKRANI ─────────────────────────────
class _FingerprintListSheet extends ConsumerWidget {
  const _FingerprintListSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(beaconControllerProvider);
    final ctrl = ref.read(beaconControllerProvider.notifier);
    final savedList = state.knownFingerprints;

    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.6,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text('Kayıtlı Konumlar (${savedList.length})',
                style: Theme.of(context).textTheme.titleMedium),
          ),
          const Divider(height: 1),
          Expanded(
            child: savedList.isEmpty
                ? const Center(child: Text('Kayıtlı konum yok.'))
                : ListView.builder(
              itemCount: savedList.length,
              itemBuilder: (ctx, i) {
                final fp = savedList[i];
                return ListTile(
                  leading: const Icon(Icons.pin_drop, color: Colors.blue),
                  title: Text(fp.name,
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text(
                      '${fp.rssiMap.length} beacon  •  ${fp.createdAt.hour.toString().padLeft(2, '0')}:${fp.createdAt.minute.toString().padLeft(2, '0')}'),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete, color: Colors.red),
                    onPressed: () async {
                      await ctrl.removeFingerprint(fp.id);
                      if (!ctx.mounted) return;
                      ScaffoldMessenger.of(ctx).showSnackBar(
                        SnackBar(content: Text('${fp.name} silindi.')),
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ── YENİ: KONUM KAYDET (FINGERPRINT) DİALOG PENCERESİ ─────────────────────
class _SaveFingerprintDialog extends ConsumerStatefulWidget {
  const _SaveFingerprintDialog();

  @override
  ConsumerState<_SaveFingerprintDialog> createState() => _SaveFingerprintDialogState();
}

class _SaveFingerprintDialogState extends ConsumerState<_SaveFingerprintDialog> {
  late final TextEditingController textController;

  @override
  void initState() {
    super.initState();
    textController = TextEditingController();
  }

  @override
  void dispose() {
    textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(beaconControllerProvider);
    final savedNames = state.knownFingerprints
        .map((fp) => fp.name.replaceAll(RegExp(r' #\d+$'), ''))
        .toSet()
        .toList();

    return AlertDialog(
      title: const Text('Konum Kaydet'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: textController,
              decoration: const InputDecoration(
                labelText: 'Stand / Bölge İsmi',
                hintText: 'Örn: Sony Standı, Giriş...',
              ),
              autofocus: true,
            ),
            if (savedNames.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Text('Mevcut bölgeye ekle:',
                  style: TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 4),
              Wrap(
                spacing: 6,
                children: savedNames
                    .map((name) => ActionChip(
                  label: Text(name, style: const TextStyle(fontSize: 11)),
                  onPressed: () => textController.text = name,
                ))
                    .toList(),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          child: const Text('İptal'),
          onPressed: () => Navigator.pop(context, null),
        ),
        ElevatedButton(
          child: const Text('KAYDET'),
          onPressed: () => Navigator.pop(context, textController.text),
        ),
      ],
    );
  }
}

// ── KONUM KARTI ──────────────────────────────────────────────────────────
class _LocationCard extends StatelessWidget {
  final BeaconState state;
  const _LocationCard({required this.state});

  @override
  Widget build(BuildContext context) {
    final isFp = state.positionSource == 'fingerprint';
    final isTl = state.positionSource == 'trilateration';

    final bgColor = isFp
        ? Colors.green.shade100
        : isTl
        ? Colors.blue.shade50
        : Colors.grey.shade200;

    final borderColor = isFp
        ? Colors.green
        : isTl
        ? Colors.blue
        : Colors.grey.shade400;

    final label = isFp
        ? '📍 ŞU AN BURADASINIZ'
        : isTl
        ? '📡 TAHMİNİ KONUM'
        : '❓ KONUM ARANIYOR...';

    final locationText = state.detectedLocation ?? 'Bilinmeyen Bölge';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor, width: 2),
      ),
      child: Column(
        children: [
          Text(label,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: borderColor)),
          const SizedBox(height: 4),
          Text(locationText,
              style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: isFp ? Colors.black : borderColor),
              textAlign: TextAlign.center),
          if (isTl && state.trilaterationX != null && state.trilaterationY != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                'x: ${state.trilaterationX!.toStringAsFixed(2)}m  y: ${state.trilaterationY!.toStringAsFixed(2)}m',
                style: TextStyle(fontSize: 12, color: borderColor.withValues(alpha: 0.8)),
                textAlign: TextAlign.center,
              ),
            ),
          if (state.positionSource != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                isFp ? '🎯 Fingerprinting' : '📡 Trilaterasyon',
                style:
                TextStyle(fontSize: 11, color: Colors.grey.shade600),
              ),
            ),
        ],
      ),
    );
  }
}

// ── BEACON SATIRI ────────────────────────────────────────────────────────
class _BeaconTile extends StatelessWidget {
  final BeaconRow beacon;
  final bool highlight;
  const _BeaconTile({required this.beacon, required this.highlight});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: highlight ? Colors.blue.withValues(alpha: 0.08) : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        border: highlight
            ? Border.all(color: Colors.blue.shade200)
            : null,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'M:${beacon.major ?? '-'}  m:${beacon.minor ?? '-'}',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 13),
                ),
                Text(
                  beacon.uuid,
                  style: const TextStyle(fontSize: 10, color: Colors.black45),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '${beacon.filteredRssi.toStringAsFixed(1)} dBm',
                style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: _rssiColor(beacon.filteredRssi)),
              ),
              Text(
                'Ham: ${beacon.rawRssi}',
                style: const TextStyle(fontSize: 11, color: Colors.black45),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Color _rssiColor(double rssi) {
    if (rssi > -65) return Colors.green;
    if (rssi > -80) return Colors.orange;
    return Colors.red;
  }
}

// ── DURUM SATIRI ─────────────────────────────────────────────────────────
class _StatusRow extends StatelessWidget {
  final String label;
  final bool ok;
  final String? value;
  const _StatusRow({required this.label, required this.ok, this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(ok ? Icons.check_circle : Icons.cancel,
              size: 14, color: ok ? Colors.green : Colors.red),
          const SizedBox(width: 6),
          Text('$label${value != null ? ': $value' : ''}',
              style: const TextStyle(fontSize: 13)),
        ],
      ),
    );
  }
}

// ── HATA KARTI ────────────────────────────────────────────────────────────
class _ErrorCard extends StatelessWidget {
  final String message;
  final String? errorType;
  final VoidCallback onRetry;
  final VoidCallback onOpenSettings;

  const _ErrorCard({
    required this.message,
    required this.onRetry,
    required this.onOpenSettings,
    this.errorType,
  });

  @override
  Widget build(BuildContext context) {
    final isPermission = errorType == 'permission_denied';
    final isBluetooth = errorType == 'bluetooth_off';
    final isRanging = errorType == 'ranging_stopped';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isRanging ? Colors.orange.shade50 : Colors.red.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isRanging ? Colors.orange.shade300 : Colors.red.shade300,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(isRanging ? Icons.wifi_off : Icons.error_outline,
                  color: isRanging ? Colors.orange : Colors.red, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(message,
                    style: TextStyle(
                        color: isRanging
                            ? Colors.orange.shade800
                            : Colors.red.shade800,
                        fontSize: 13)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              if (isPermission)
                ElevatedButton.icon(
                  icon: const Icon(Icons.settings, size: 16),
                  label: const Text('Ayarlara Git'),
                  style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red.shade600,
                      foregroundColor: Colors.white),
                  onPressed: onOpenSettings,
                ),
              if (isBluetooth)
                ElevatedButton.icon(
                  icon: const Icon(Icons.bluetooth, size: 16),
                  label: Text(Platform.isAndroid
                      ? 'Bluetooth\'u Aç'
                      : 'Bluetooth Ayarları'),
                  style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue.shade600,
                      foregroundColor: Colors.white),
                  onPressed: onOpenSettings,
                ),
              if (!isPermission)
                OutlinedButton.icon(
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('Tekrar Dene'),
                  onPressed: onRetry,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── DWELL TIME SAYACI ────────────────────────────────────────────────────
class _DwellTime extends StatefulWidget {
  final DateTime startTime;
  const _DwellTime({required this.startTime});

  @override
  State<_DwellTime> createState() => _DwellTimeState();
}

class _DwellTimeState extends State<_DwellTime> {
  late Timer _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final elapsed = DateTime.now().difference(widget.startTime).inSeconds;
    return Text(
      'Bu bölgede: $elapsed sn',
      style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
    );
  }
}

// ── OFFLINE QUEUE BANNER (Task 3.2) ───────────────────────────────────────
/// API kuyruğunda bekleyen ziyaret/contact varsa kullanıcıyı bilgilendirir.
/// 5 saniyede bir pendingCount sorgular; sıfırsa görünmez.
class _OfflineQueueBanner extends ConsumerStatefulWidget {
  const _OfflineQueueBanner();

  @override
  ConsumerState<_OfflineQueueBanner> createState() =>
      _OfflineQueueBannerState();
}

class _OfflineQueueBannerState extends ConsumerState<_OfflineQueueBanner> {
  int _visitPending = 0;
  int _contactPending = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final api = ref.read(apiServiceProvider);
    final v = await api.pendingCount();
    final c = await api.pendingContactCount();
    if (!mounted) return;
    if (v != _visitPending || c != _contactPending) {
      setState(() {
        _visitPending = v;
        _contactPending = c;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final total = _visitPending + _contactPending;
    if (total == 0) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.amber.shade50,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.amber.shade300),
      ),
      child: Row(
        children: [
          Icon(Icons.cloud_off_outlined,
              size: 18, color: Colors.amber.shade800),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Sunucuya bağlanılamıyor — $total kayıt kuyrukta bekliyor, '
              'ağ gelince otomatik gönderilecek.',
              style: TextStyle(fontSize: 12, color: Colors.amber.shade900),
            ),
          ),
        ],
      ),
    );
  }
}

// ── CONTACT INDICATOR ─────────────────────────────────────────────────────
class _ContactIndicator extends ConsumerWidget {
  const _ContactIndicator();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(contactControllerProvider);
    if (s.activeEncounterCount == 0 && s.reportedContactCount == 0) {
      return const SizedBox.shrink();
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.deepPurple.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            const Icon(Icons.people_outline, size: 18, color: Colors.deepPurple),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Temas: ${s.activeEncounterCount} cihaz görüldü · '
                '${s.reportedContactCount} kayıtlı contact',
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── SUNUCU BAĞLANTI GÖSTERGESİ ────────────────────────────────────────────
// Periyodik /api/discover ping ile backend'e ulaşılıyor mu gösterir. Saha
// günü "bağlanamıyorum" sorununu anında teşhis etmek için.
class _ConnectionIndicator extends StatefulWidget {
  const _ConnectionIndicator();

  @override
  State<_ConnectionIndicator> createState() => _ConnectionIndicatorState();
}

class _ConnectionIndicatorState extends State<_ConnectionIndicator> {
  bool? _connected; // null = ilk kontrol
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _check();
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => _check());
  }

  Future<void> _check() async {
    final ok = await ApiService.pingServer();
    if (mounted) setState(() => _connected = ok);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // "http://192.168.1.42:3000/api" → "192.168.1.42:3000"
    final url = ApiService.currentBaseUrl
        .replaceAll(RegExp(r'^https?://'), '')
        .replaceAll('/api', '');
    final c = _connected;
    final color = c == null ? Colors.grey : (c ? Colors.green : Colors.red);
    final label = c == null
        ? 'Sunucu kontrol ediliyor…'
        : (c ? 'Sunucu bağlı' : 'Sunucuya bağlanılamıyor');
    final icon = c == null
        ? Icons.cloud_queue
        : (c ? Icons.cloud_done : Icons.cloud_off);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: color)),
                  Text(url,
                      style: const TextStyle(fontSize: 11, color: Colors.grey)),
                ],
              ),
            ),
            if (c == false)
              TextButton(
                onPressed: () => _check(),
                child: const Text('Tekrar Dene'),
              ),
          ],
        ),
      ),
    );
  }
}

// ── SECTION WRAPPER ───────────────────────────────────────────────────────
class _Section extends StatelessWidget {
  final String title;
  final Widget child;
  const _Section({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: Colors.black12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            child,
          ],
        ),
      ),
    );
  }
}