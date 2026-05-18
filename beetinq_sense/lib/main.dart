import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'features/beacon/api_service.dart';
import 'features/beacon/beacon_page.dart';

Future<void> main() async {
  // SharedPreferences read için binding init şart.
  WidgetsFlutterBinding.ensureInitialized();
  // Runtime server URL: SharedPreferences'tan yükle. Kullanıcı saha günü
  // Ayarlar'dan değiştirebilir; yoksa ApiService default'a düşer.
  await ApiService.loadServerUrl();
  runApp(const ProviderScope(child: BeetinqSenseApp()));
}

class BeetinqSenseApp extends StatelessWidget {
  const BeetinqSenseApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Beetinq Sense',
      theme: ThemeData(
        colorSchemeSeed: Colors.blue,
        useMaterial3: true,
      ),
      home: const BeaconPage(),
    );
  }
}
