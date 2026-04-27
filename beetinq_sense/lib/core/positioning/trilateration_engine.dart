// lib/core/positioning/trilateration_engine.dart

import 'dart:math';

/// Fiziksel alandaki sabit beacon'ların koordinatlarını tutar.
///
/// [id] formatı MUTLAKA `BeaconRow.key` ile aynı olmalı:
///   "{UUID_UPPERCASE_DASHED}-{MAJOR}-{MINOR}"
///   Örn: "E2C56DB5-DFFB-48D2-B060-D0F5A71096E0-100-7"
///
/// Aksi hâlde trilaterasyon'da currentRssiMap lookup'ı sessizce
/// fail eder ve hiçbir beacon eşleşmez.
class BeaconLocation {
  final String id;
  final double x;
  final double y;
  final String? name;

  BeaconLocation({
    required this.id,
    required this.x,
    required this.y,
    this.name,
  });

  /// Controller'ın `BeaconRow.key` ile aynı formatta id üretir.
  /// Yeni beacon eklerken bu helper'ı kullan ki invariant bozulmasın.
  factory BeaconLocation.fromBeaconKey({
    required String uuid,
    required int major,
    required int minor,
    required double x,
    required double y,
    String? name,
  }) {
    final normalizedUuid = uuid.toUpperCase();
    return BeaconLocation(
      id: '$normalizedUuid-$major-$minor',
      x: x,
      y: y,
      name: name,
    );
  }

  /// id formatının geçerli olup olmadığını kontrol eder.
  /// UUID (dashed, 36 char) + "-MAJOR-MINOR" pattern'i.
  static bool isValidId(String id) {
    final re = RegExp(
      r'^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}-\d+-\d+$',
      caseSensitive: false,
    );
    return re.hasMatch(id);
  }

  /// Session ve visit event'lerde kullanılan konum etiketi.
  String get locationLabel {
    if (name != null && name!.isNotEmpty) return name!;
    final parts = id.split('-');
    // uuid 5 segmentli, sonrasında major-minor: toplam 7 segment beklenir.
    // Son iki segment (major-minor) okunabilir kısa label verir.
    if (parts.length >= 2) {
      return '${parts[parts.length - 2]}-${parts[parts.length - 1]}';
    }
    return parts.last;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'x': x,
        'y': y,
        if (name != null) 'name': name,
      };

  factory BeaconLocation.fromJson(Map<String, dynamic> json) {
    final id = json['id'] as String?;
    if (id == null || id.isEmpty) {
      throw FormatException('BeaconLocation id eksik: $json');
    }
    if (!isValidId(id)) {
      // Uyarı ver ama yine kabul et — backend'den gelen veri eski
      // format olabilir, ignore etmek yerine log'layıp devam etmek
      // geriye dönük uyumluluk için daha güvenli.
      // ignore: avoid_print
      print('⚠️ [BeaconLocation] id format uyarısı: "$id"');
    }
    final xRaw = json['x'];
    final yRaw = json['y'];
    if (xRaw is! num || yRaw is! num) {
      throw FormatException('BeaconLocation x/y sayı olmalı: $json');
    }
    return BeaconLocation(
      id: id,
      x: xRaw.toDouble(),
      y: yRaw.toDouble(),
      name: json['name'] as String?,
    );
  }
}

class TrilaterationEngine {
  // Ortam Sabiti (n):
  // 2.0 = Açık alan (Free space)
  // 2.5 - 3.0 = Ofis ortamı
  // 3.0+ = Çok gürültülü ortam
  static const double pathLossExponent = 2.5;

  // 1 Metredeki Referans RSSI
  static const int txPowerAt1m = -59;

  /// 1. Adım: RSSI -> Mesafe Dönüşümü (Log-Distance Model)
  double calculateDistance(double rssi) {
    // BLE'de geçerli RSSI aralığı: -100 ile -1 dBm arası.
    if (rssi >= 0 || rssi < -100) return -1.0;

    final double exponent = (txPowerAt1m - rssi) / (10 * pathLossExponent);
    return pow(10, exponent).toDouble();
  }

  /// 2. Adım: Ağırlıklı Ağırlık Merkezi (Inverse-Distance Weighted Centroid)
  Map<String, double>? calculatePosition(
    List<BeaconLocation> knownBeacons,
    Map<String, double> currentRssiMap,
  ) {
    double numeratorX = 0;
    double numeratorY = 0;
    double denominatorW = 0;
    int matchCount = 0;

    final seenIds = <String>{};

    for (var beacon in knownBeacons) {
      if (!seenIds.add(beacon.id)) continue; // duplicate → atla
      if (!currentRssiMap.containsKey(beacon.id)) continue;

      final rssi = currentRssiMap[beacon.id]!;
      final distance = calculateDistance(rssi);

      if (distance <= 0 || distance > 50.0) continue;

      final safeDistance = distance < 0.5 ? 0.5 : distance;
      final weight = 1 / (safeDistance * safeDistance);

      numeratorX += beacon.x * weight;
      numeratorY += beacon.y * weight;
      denominatorW += weight;

      matchCount++;
    }

    if (matchCount < 2 || denominatorW == 0) {
      return null;
    }

    return {
      'x': numeratorX / denominatorW,
      'y': numeratorY / denominatorW,
    };
  }
}
