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

  // Distance cap: pathLossExponent=2.5 için 10^((-59 - (-99)) / 25) ≈ 39.8m;
  // -100'de RSSI invalidate (calculateDistance -1 döner). 80m cap güvenlik için
  // çok yüksek; pratikte tetiklenmez ama future-proof (n=2 veya tx daha güçlüyse).
  static const double _maxDistanceMeters = 80.0;

  // Adaptive EWMA: küçük değişimde smoothing, büyük değişimde responsive.
  // Hareketsizken α düşük (stabil), hızlı hareketle birlikte α yüksek (gecikme yok).
  // Eski sabit 0.3 yerine [0.15-0.6] aralığı kullanılır.
  static const double _emaAlphaMin = 0.15;
  static const double _emaAlphaMax = 0.6;
  // Adaptive eşik: raw konum-emaPos farkı 1m üstüyse maksimum alpha.
  static const double _emaJumpThreshold = 1.0;

  double? _emaX;
  double? _emaY;

  /// Konum geçmişini sıfırlar. Kullanıcı uzun süre konum alamadıysa veya
  /// scanner duraklatıldıysa controller bunu çağırarak EWMA'yı temizleyebilir;
  /// yoksa eski konuma "saplanma" görülür.
  void resetSmoothing() {
    _emaX = null;
    _emaY = null;
  }

  /// 1. Adım: RSSI -> Mesafe Dönüşümü (Log-Distance Model)
  double calculateDistance(double rssi) {
    // BLE'de geçerli RSSI aralığı: -100 ile -1 dBm arası.
    if (rssi >= 0 || rssi < -100) return -1.0;

    final double exponent = (txPowerAt1m - rssi) / (10 * pathLossExponent);
    return pow(10, exponent).toDouble();
  }

  /// 2. Adım: Weighted Linear Least Squares Trilaterasyon + outlier rejection.
  ///
  /// Daire denklemleri: (x - xᵢ)² + (y - yᵢ)² = dᵢ²
  ///
  /// Reference beacon (en güçlü RSSI'lı) seçilip diğerlerinin denkleminden
  /// çıkarılırsa kuadratik terimler düşer ve lineer sistem kalır:
  ///   2(x₀ - xᵢ)·x + 2(y₀ - yᵢ)·y = dᵢ² - d₀² + (x₀² - xᵢ²) + (y₀² - yᵢ²)
  ///
  /// İyileştirmeler (önceki düz LS'e göre):
  /// - **Weighted LS**: her satır 1/d²ᵢ ile ağırlandırılır. Yakın beacon =
  ///   güvenilir mesafe = denkleme daha çok söz hakkı. RSSI gürültüsü uzakta
  ///   mesafeyi katlandırır; bu olmadan uzak beacon LS'i bozar.
  /// - **Outlier rejection**: ≥4 beacon varken leave-one-out yaparak en kötü
  ///   residual'lı beacon atılıp tekrar hesaplanır. 5 beacon ile 1 anomali
  ///   varsa konum hassasiyeti önemli ölçüde artar.
  /// - **2-beacon fallback**: 3+ beacon yoksa weighted midpoint (1/d ağırlık)
  ///   ile yine konum döndürür; kenar/zayıf alanlarda "konum yok" yerine
  ///   yaklaşık konum tercih edilir.
  /// - **Gauss-Newton refinement**: lineer LS yalnız cebirsel hatayı (dᵢ²
  ///   farkları) minimize eder; üstüne GERÇEK geometrik residual'ı
  ///   (‖p−bᵢ‖ − dᵢ) 1/d² ağırlıkla minimize eden birkaç GN iterasyonu
  ///   eklenir. Gürültüde lineerleştirme bias'ını azaltır (sandbox σ=6:
  ///   median 1.40→1.25m, p95 3.71→3.00m). Residual artarsa LS'e geri döner.
  /// - **Adaptive EWMA**: hareketsizde α düşük (smooth), hızlı hareket
  ///   varsa α yüksek (responsive); jumpy davranış önlenir.
  Map<String, double>? calculatePosition(
    List<BeaconLocation> knownBeacons,
    Map<String, double> currentRssiMap,
  ) {
    // 1) Eşleşen beacon'ları topla, mesafelerini hesapla.
    final beacons = <BeaconLocation>[];
    final distances = <double>[];
    final rssis = <double>[];
    final seenIds = <String>{};

    for (final b in knownBeacons) {
      if (!seenIds.add(b.id)) continue; // duplicate → atla
      final rssi = currentRssiMap[b.id];
      if (rssi == null) continue;
      final d = calculateDistance(rssi);
      if (d <= 0 || d > _maxDistanceMeters) continue;
      beacons.add(b);
      distances.add(d);
      rssis.add(rssi);
    }

    // Hiç eşleşme yok → null.
    if (beacons.isEmpty) return null;

    // Tek beacon görünüyor → güvenilir konum üretemeyiz (mesafe biliniyor ama
    // yön bilinmiyor); null döndür. Controller fingerprint'e veya hysteresis'e
    // düşer.
    if (beacons.length == 1) return null;

    // 2 beacon: weighted midpoint fallback (1/d ağırlık). Tam doğru değildir
    // ama "konum yok" yerine yaklaşık konum daha iyi UX. Beacon koordinatları
    // dışına çıkamaz (convex hull bias) — fallback amacı zaten bu.
    if (beacons.length == 2) {
      final w0 = 1.0 / max(distances[0], 0.1);
      final w1 = 1.0 / max(distances[1], 0.1);
      final wSum = w0 + w1;
      final rawX = (beacons[0].x * w0 + beacons[1].x * w1) / wSum;
      final rawY = (beacons[0].y * w0 + beacons[1].y * w1) / wSum;
      return _applyEwma(rawX, rawY);
    }

    // 3) Asıl LS çözümü (lineer — başlangıç tahmini).
    final pos = _weightedLeastSquares(beacons, distances, rssis);
    if (pos == null) return null;

    // `best` ile birlikte HANGİ beacon setinin onu ürettiğini de izle; outlier
    // atılırsa Gauss-Newton da aynı (pruned) setle çalışmalı.
    Map<String, double> best = pos;
    List<BeaconLocation> refineBeacons = beacons;
    List<double> refineDist = distances;

    // 4) Outlier rejection: ≥4 beacon ve initial residual yüksekse en kötü
    // beacon'u at, tekrar hesapla. Tek pass (2. iterasyona girilmez).
    if (beacons.length >= 4) {
      final residuals = <int, double>{};
      for (int i = 0; i < beacons.length; i++) {
        final dEst =
            sqrt(pow(pos['x']! - beacons[i].x, 2) + pow(pos['y']! - beacons[i].y, 2));
        residuals[i] = (dEst - distances[i]).abs();
      }
      // Worst beacon
      int worstIdx = 0;
      double worstRes = -1;
      residuals.forEach((idx, r) {
        if (r > worstRes) {
          worstRes = r;
          worstIdx = idx;
        }
      });
      // Sadece residual büyükse (1m üstü) ve geri kalan 3+ ise dene.
      if (worstRes > 1.0 && beacons.length - 1 >= 3) {
        final prunedBeacons = <BeaconLocation>[];
        final prunedDist = <double>[];
        final prunedRssi = <double>[];
        for (int i = 0; i < beacons.length; i++) {
          if (i == worstIdx) continue;
          prunedBeacons.add(beacons[i]);
          prunedDist.add(distances[i]);
          prunedRssi.add(rssis[i]);
        }
        final prunedPos =
            _weightedLeastSquares(prunedBeacons, prunedDist, prunedRssi);
        if (prunedPos != null) {
          // Yeni residual ortalaması daha düşükse onu tercih et.
          final newMeanRes = _meanResidual(
              prunedBeacons, prunedDist, prunedPos['x']!, prunedPos['y']!);
          final oldMeanRes = _meanResidual(
              beacons, distances, pos['x']!, pos['y']!);
          if (newMeanRes < oldMeanRes) {
            best = prunedPos;
            refineBeacons = prunedBeacons;
            refineDist = prunedDist;
          }
        }
      }
    }

    // 5) Gauss-Newton refinement (non-lineer geometrik düzeltme).
    // Lineer LS, daire denklemlerini referans çıkarımıyla LİNEERLEŞTİRİR ve
    // CEBİRSEL hatayı (dᵢ² farkları) minimize eder — bu, geometrik hatadan
    // (‖p−bᵢ‖ − dᵢ) sapan, gürültüde yanlı bir çözümdür. LS sonucunu başlangıç
    // alıp gerçek geometrik residual'ı 1/d² ağırlıkla minimize eden birkaç GN
    // iterasyonu bias'ı azaltır. Güvenlik: residual artarsa LS sonucuna geri
    // dönülür (GN asla kötüleştirmez).
    best = _gaussNewtonRefine(refineBeacons, refineDist, best['x']!, best['y']!);

    // 6) Adaptive EWMA.
    return _applyEwma(best['x']!, best['y']!);
  }

  // ─────────────── Helpers ───────────────

  Map<String, double>? _weightedLeastSquares(
    List<BeaconLocation> beacons,
    List<double> distances,
    List<double> rssis,
  ) {
    // Reference: en güçlü RSSI'lı beacon → en güvenilir mesafe → kararlı çıkış.
    int refIdx = 0;
    double refRssi = rssis[0];
    for (int i = 1; i < rssis.length; i++) {
      if (rssis[i] > refRssi) {
        refRssi = rssis[i];
        refIdx = i;
      }
    }

    final refX = beacons[refIdx].x;
    final refY = beacons[refIdx].y;
    final refDistSq = distances[refIdx] * distances[refIdx];

    // Normal denklem akümülatörleri: AᵀWA · X = AᵀWb
    double sumPP = 0, sumPQ = 0, sumQQ = 0;
    double sumPR = 0, sumQR = 0;

    for (int i = 0; i < beacons.length; i++) {
      if (i == refIdx) continue;
      final p = 2 * (refX - beacons[i].x);
      final q = 2 * (refY - beacons[i].y);
      final r = distances[i] * distances[i] -
          refDistSq +
          refX * refX -
          beacons[i].x * beacons[i].x +
          refY * refY -
          beacons[i].y * beacons[i].y;
      // Weighted LS: yakın beacon = düşük mesafe = yüksek ağırlık.
      // RSSI varyansı mesafenin karesi ile büyür; 1/d² mantıklı seçim.
      final w = 1.0 / max(distances[i] * distances[i], 0.25);
      sumPP += w * p * p;
      sumPQ += w * p * q;
      sumQQ += w * q * q;
      sumPR += w * p * r;
      sumQR += w * q * r;
    }

    // 2x2 analitik invert. det küçükse beacon'lar collinear → singular.
    final det = sumPP * sumQQ - sumPQ * sumPQ;
    if (det.abs() < 1e-9) return null;

    final invDet = 1.0 / det;
    final rawX = invDet * (sumQQ * sumPR - sumPQ * sumQR);
    final rawY = invDet * (-sumPQ * sumPR + sumPP * sumQR);

    if (rawX.isNaN || rawY.isNaN || rawX.isInfinite || rawY.isInfinite) {
      return null;
    }
    return {'x': rawX, 'y': rawY};
  }

  /// Gauss-Newton ile geometrik residual minimizasyonu.
  ///
  /// Minimize edilen: f(p) = Σ wᵢ (‖p − bᵢ‖ − dᵢ)²,  wᵢ = 1/dᵢ² (LS ile aynı).
  /// Her iterasyonda Jacobian satırı Jᵢ = (p − bᵢ)/‖p − bᵢ‖; normal denklem
  /// (JᵀWJ)·Δ = −JᵀW·r çözülür (2×2 analitik invert). Beacon üzerinde
  /// (‖p−bᵢ‖≈0) Jacobian tekil olur → o satır atlanır.
  ///
  /// [x0],[y0] LS başlangıç tahmini. En fazla 6 iterasyon; adım küçülünce
  /// erken çık. Sonuç başlangıçtan daha kötü residual veriyorsa (ör. kötü
  /// koşullu geometri) LS sonucu korunur → GN asla regresyon yaratmaz.
  Map<String, double> _gaussNewtonRefine(
    List<BeaconLocation> beacons,
    List<double> distances,
    double x0,
    double y0,
  ) {
    if (beacons.length < 3) return {'x': x0, 'y': y0};

    double x = x0, y = y0;
    const maxIter = 6;
    for (int iter = 0; iter < maxIter; iter++) {
      double h00 = 0, h01 = 0, h11 = 0; // JᵀWJ
      double g0 = 0, g1 = 0; // JᵀW·r
      for (int i = 0; i < beacons.length; i++) {
        final dx = x - beacons[i].x;
        final dy = y - beacons[i].y;
        final r = sqrt(dx * dx + dy * dy);
        if (r < 1e-6) continue; // beacon üstünde — Jacobian tekil
        final jx = dx / r;
        final jy = dy / r;
        final residual = r - distances[i];
        final w = 1.0 / max(distances[i] * distances[i], 0.25);
        h00 += w * jx * jx;
        h01 += w * jx * jy;
        h11 += w * jy * jy;
        g0 += w * jx * residual;
        g1 += w * jy * residual;
      }
      final det = h00 * h11 - h01 * h01;
      if (det.abs() < 1e-12) break; // tekil → düzeltme yapma
      // Δ = −(JᵀWJ)⁻¹ · JᵀW·r
      final stepX = -(h11 * g0 - h01 * g1) / det;
      final stepY = -(-h01 * g0 + h00 * g1) / det;
      if (stepX.isNaN || stepY.isNaN || stepX.isInfinite || stepY.isInfinite) {
        break;
      }
      x += stepX;
      y += stepY;
      if (stepX.abs() + stepY.abs() < 1e-4) break; // yakınsadı
    }

    if (x.isNaN || y.isNaN || x.isInfinite || y.isInfinite) {
      return {'x': x0, 'y': y0};
    }
    // Güvenlik: GN sonucu LS başlangıcından daha kötüyse başlangıcı koru.
    final newRes = _meanResidual(beacons, distances, x, y);
    final oldRes = _meanResidual(beacons, distances, x0, y0);
    if (newRes > oldRes) return {'x': x0, 'y': y0};
    return {'x': x, 'y': y};
  }

  double _meanResidual(
    List<BeaconLocation> beacons,
    List<double> distances,
    double x,
    double y,
  ) {
    if (beacons.isEmpty) return 0;
    double sum = 0;
    for (int i = 0; i < beacons.length; i++) {
      final dEst = sqrt(pow(x - beacons[i].x, 2) + pow(y - beacons[i].y, 2));
      sum += (dEst - distances[i]).abs();
    }
    return sum / beacons.length;
  }

  Map<String, double> _applyEwma(double rawX, double rawY) {
    if (_emaX == null || _emaY == null) {
      _emaX = rawX;
      _emaY = rawY;
    } else {
      // Adaptive alpha: raw ile mevcut EWMA arasındaki sıçramayı ölç.
      final jump = sqrt(pow(rawX - _emaX!, 2) + pow(rawY - _emaY!, 2));
      // Linear ramp: 0..jumpThreshold → emaAlphaMin..emaAlphaMax.
      final t = (jump / _emaJumpThreshold).clamp(0.0, 1.0);
      final alpha = _emaAlphaMin + (_emaAlphaMax - _emaAlphaMin) * t;
      _emaX = alpha * rawX + (1 - alpha) * _emaX!;
      _emaY = alpha * rawY + (1 - alpha) * _emaY!;
    }
    return {'x': _emaX!, 'y': _emaY!};
  }
}
