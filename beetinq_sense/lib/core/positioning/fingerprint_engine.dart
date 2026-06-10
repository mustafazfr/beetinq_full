import 'dart:math';

/// Bir noktanın (Stand, Kapı vb.) sinyal karakteristiğini tutar.
class Fingerprint {
  final String id;          // Örn: "stand_a_uuid"
  final String name;        // Örn: "Sony Standı"
  final Map<String, int> rssiMap; // { 'beacon_uuid_major_minor': -65, ... }
  final DateTime createdAt;

  Fingerprint({
    required this.id,
    required this.name,
    required this.rssiMap,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  // JSON serileştirme (İleride Backend için lazım olacak)
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'rssiMap': rssiMap,
    'createdAt': createdAt.toIso8601String(),
  };

  factory Fingerprint.fromJson(Map<String, dynamic> json) {
    return Fingerprint(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      rssiMap: json['rssiMap'] != null
          ? Map<String, int>.from(json['rssiMap'] as Map)
          : const {},
      // createdAt: eski diskteki JSON'da bu alan yoksa null döner → DateTime.parse(null) crash yapar.
      // Eski veriyle geriye dönük uyumluluk için null kontrolü şart.
      createdAt: json['createdAt'] != null ? DateTime.parse(json['createdAt'] as String) : DateTime.now(),
    );
  }
}

class FingerprintEngine {
  // Kaydedilmiş referans noktaları
  final List<Fingerprint> _knownFingerprints = [];

  // Veritabanı veya local storage'dan parmak izlerini yüklemek için
  void loadFingerprints(List<Fingerprint> list) {
    _knownFingerprints.clear();
    _knownFingerprints.addAll(list);
  }

  void addFingerprint(Fingerprint fp) {
    _knownFingerprints.add(fp);
  }

  /// Aynı isimde kaç fingerprint var sayar — UI'da "Sony Standı (3/3)" göstermek için
  int countByName(String name) =>
      _knownFingerprints.where((fp) => fp.name == name).length;

  /// Aynı stand adını otomatik numaralandırarak ekler.
  /// "Sony Standı" ikinci kez eklenirse adı "Sony Standı #2" olur.
  /// Bu sayede admin aynı stand için birden fazla RSSI snapshot alabilir.
  ///
  /// FIX: Önceki versiyonda "base ad" yerine tam ada bakıldığı için
  /// üçüncü kayıt geldiğinde existing==0 dönüyor ve tekrar düz ad ekleniyordu.
  /// Artık base ad (# suffix'i soyulmuş) üzerinden sayım yapılıyor.
  void addFingerprintWithAutoIndex(Fingerprint fp) {
    // Base adı hesapla: "Sony Standı #2" → "Sony Standı"
    final baseName = fp.name.replaceAll(RegExp(r'\s*#\d+$'), '');

    // Base ada sahip tüm kayıtları bul (# suffix'li olanlar dahil)
    final existingCount = _knownFingerprints
        .where((f) => f.name.replaceAll(RegExp(r'\s*#\d+$'), '') == baseName)
        .length;

    if (existingCount == 0) {
      // İlk kayıt — düz adla ekle
      _knownFingerprints.add(Fingerprint(
        id: fp.id,
        name: baseName,
        rssiMap: fp.rssiMap,
        createdAt: fp.createdAt,
      ));
    } else {
      // İkinci veya sonraki kayıt geldi
      // İlk kaydın adında # yoksa onu #1 olarak güncelle
      final firstIdx = _knownFingerprints
          .indexWhere((f) => f.name == baseName);
      if (firstIdx != -1) {
        final first = _knownFingerprints[firstIdx];
        _knownFingerprints[firstIdx] = Fingerprint(
          id: first.id,
          name: '$baseName #1',
          rssiMap: first.rssiMap,
          createdAt: first.createdAt,
        );
      }
      // Yeni kaydı sıradaki numarayla ekle
      _knownFingerprints.add(Fingerprint(
        id: fp.id,
        name: '$baseName #${existingCount + 1}',
        rssiMap: fp.rssiMap,
        createdAt: fp.createdAt,
      ));
    }
  }

  // Kayıtlı konumları dışarıya verir
  List<Fingerprint> get knownFingerprints => _knownFingerprints;

  // ID'ye göre konum siler
  void removeFingerprintById(String id) {
    _knownFingerprints.removeWhere((fp) => fp.id == id);
  }

  /// 1-NN PER LOCATION + STICKINESS (KNN ailesinin sadeleşmiş hâli)
  ///
  /// 1. Her KONUM (base ad, '#N' suffix'i soyulmuş) kendi EN İYİ (min Öklid
  ///    mesafeli) snapshot'ıyla temsil edilir.
  /// 2. Threshold altı konumlar arasında en düşük mesafeli kazanır.
  /// 3. Stickiness: mevcut konum, kazanana [stickyMargin] kadar yakın VE
  ///    mutlak olarak hâlâ iyiyse (skor < threshold/2) korunur → flicker yok.
  ///
  /// TARİHÇE: kod k=3 weighted-vote KNN olarak başladı; snapshot sayısı fazla
  /// olan stand top-K'yı domine ettiği için ("her yerde cam/kapı" bias'ı)
  /// 1-NN-per-location'a evrildi — detay aşağıdaki PER-LOCATION BEST yorumunda.
  /// [k] parametresi API geriye-uyumluluğu için duruyor, KULLANILMIYOR
  /// (dönüş değerindeki `k` alanı artık "değerlendirilen konum sayısı").
  FingerprintMatch? findNearestMatch(
    Map<String, int> currentScan, {
    double threshold = 15.0,
    int k = 3,
    String? currentLocation,
    double stickyMargin = 2.0,
  }) {
    if (_knownFingerprints.isEmpty) return null;

    // PER-LOCATION BEST (snapshot-count bias fix):
    // Eskiden global top-K aday alınıp weighted vote yapılıyordu. Sorun:
    // bir stand çok kez kaydedilmişse (örn. "kapı" 8 snapshot) top-K'yı
    // onun kopyaları dolduruyor, az kaydedilen stand (örn. "arkakoltuk" 1
    // snapshot) hiç kazanamıyordu → "her yerde cam/kapı" bias'ı.
    //
    // Çözüm: her KONUM (base ad) kendi EN İYİ (min mesafe) snapshot'ıyla
    // temsil edilir; konumlar arasında en düşük mesafeli kazanır. Böylece
    // her stand snapshot sayısından bağımsız, adil yarışır (1-NN per location).
    final Map<String, FingerprintMatch> bestPerLocation = {};
    for (final fp in _knownFingerprints) {
      final name = fp.name.replaceAll(RegExp(r'\s*#\d+$'), '');
      final score = _calculateEuclideanDistance(currentScan, fp.rssiMap);
      final existing = bestPerLocation[name];
      if (existing == null || score < existing.score) {
        bestPerLocation[name] = FingerprintMatch(fingerprint: fp, score: score);
      }
    }

    // Threshold altı konumları sırala (en yakın önce).
    final ranked = bestPerLocation.values
        .where((m) => m.score <= threshold)
        .toList()
      ..sort((a, b) => a.score.compareTo(b.score));

    if (ranked.isEmpty) return null;

    var winner = ranked.first;

    // STICKINESS (zıplama önleme): İki stand neredeyse eşit mesafedeyse her
    // tarama winner'ı değiştirip "bir cam bir kapı" flicker'ı yaratır. Mevcut
    // konum hâlâ aday VE en iyiye [stickyMargin] kadar yakınsa, konumu KORU.
    //
    // BUG FIX (BUG-5): Eskiden sadece "winner'a yakınlık" kontrol ediliyordu →
    // kullanıcı standdan gerçekten uzaklaştığında bile (mevcut konumun skoru
    // kötüleşse de winner'a göreli yakın kaldığı sürece) yanlış konuma "yapışıp"
    // kalabiliyordu. Ek koşul: mevcut konum MUTLAK olarak da hâlâ iyi olmalı
    // (eşiğin yarısı altında). Gerçekten uzaklaşıldığında (skor > threshold/2)
    // yapışma bırakılır → doğru konuma geçer. Flicker önleme korunur, yanlış
    // takılma engellenir.
    if (currentLocation != null) {
      final curBase = currentLocation.replaceAll(RegExp(r'\s*#\d+$'), '');
      for (final m in ranked) {
        final mBase = m.fingerprint.name.replaceAll(RegExp(r'\s*#\d+$'), '');
        if (mBase == curBase &&
            m.score <= winner.score + stickyMargin &&
            m.score < threshold / 2) {
          winner = m; // mevcut konuma yapış (hem yakın hem mutlak iyi)
          break;
        }
      }
    }

    return FingerprintMatch(
      fingerprint: winner.fingerprint,
      score: winner.score,
      voteCount: 1,
      // k = değerlendirilen KONUM sayısı (log/debug için).
      k: ranked.length,
    );
  }

  /// İki sinyal kümesi arasındaki normalize edilmiş mesafeyi hesaplar.
  ///
  /// Simetrik karşılaştırma: hem stored hem de live anahtarları değerlendiriliyor.
  /// Sadece stored.forEach yapılsaydı, ortamda yeni ve güçlü beacon'lar varken
  /// stored'daki tek beacon eşleşirse skor 0 çıkardı → yanlış lokasyon.
  double _calculateEuclideanDistance(Map<String, int> live, Map<String, int> stored) {
    if (stored.isEmpty) return double.infinity;

    // Tüm anahtar evrenini birleştir: stored ∪ live
    final allKeys = <String>{...stored.keys, ...live.keys};

    double sumSquares = 0;
    int matchCount = 0;

    for (final key in allKeys) {
      final storedRssi = stored[key];
      final liveRssi = live[key];

      if (storedRssi != null && liveRssi != null) {
        // Her ikisinde de var → gerçek fark
        final diff = (liveRssi - storedRssi).toDouble();
        sumSquares += diff * diff;
        matchCount++;
      } else if (storedRssi != null) {
        // Kayıtlı beacon artık duyulmuyor → eksiklik cezası
        sumSquares += 30 * 30;
      } else {
        // Live'da var ama kayıtta yok → ortamda yeni/güçlü beacon var.
        sumSquares += 20 * 20;
      }
    }

    if (matchCount == 0) return double.infinity;

    // Toplam anahtar sayısına göre normalize et
    return sqrt(sumSquares / allKeys.length);
  }
}

class FingerprintMatch {
  final Fingerprint fingerprint;
  final double score;    // En iyi adayın skoru (düşük = iyi)
  final int voteCount;  // Kaç aday bu konumu oyladı
  final int k;          // Toplam kaç aday değerlendirildi

  FingerprintMatch({
    required this.fingerprint,
    required this.score,
    this.voteCount = 1,
    this.k = 1,
  });
}
