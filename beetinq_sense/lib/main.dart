import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'features/beacon/beacon_page.dart';

void main() {
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
