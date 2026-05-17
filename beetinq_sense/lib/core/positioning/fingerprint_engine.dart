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

  /// KNN (K-Nearest Neighbors) Mantığı - K=3, Inverse-Distance Weighted Voting
  ///
  /// 1. Tüm fingerprint'lere olan Öklid mesafesini hesapla
  /// 2. En yakın K=3 tanesini al (hepsi threshold altında olmalı)
  /// 3. Her aday için 1/(score+ε) ağırlığı hesapla; aynı konum adı altında topla.
  ///    Sigma'ya eklenen ε = 0.5 (sıfıra bölme koruması + tam eşleşme aşırı
  ///    dominasyonunu yumuşatma).
  /// 4. En yüksek ağırlık toplamına sahip konum adı kazanır.
  ///
  /// Eşit oy (her birinde 1 aday) durumunda en düşük skorlu aday otomatik
  /// kazanır çünkü ağırlığı en yüksek.
  ///
  /// İyileştirme: önceki version eşit oy bazlı majority vote yapıyordu;
  /// yakın aday ile uzak aday eşit söz hakkına sahipti. Sentetik testte
  /// 1m aralıklı noktalarda %66 → ~%80+ accuracy hedefi.
  FingerprintMatch? findNearestMatch(Map<String, int> currentScan, {double threshold = 15.0, int k = 3}) {
    if (_knownFingerprints.isEmpty) return null;

    // 1. Tüm mesafeleri hesapla ve sırala
    final candidates = _knownFingerprints
        .map((fp) => FingerprintMatch(
      fingerprint: fp,
      score: _calculateEuclideanDistance(currentScan, fp.rssiMap),
    ))
        .where((m) => m.score <= threshold) // Threshold dışındakileri ele
        .toList()
      ..sort((a, b) => a.score.compareTo(b.score));

    if (candidates.isEmpty) return null;

    // 2. En yakın K tanesini al (K'dan az aday varsa hepsini al)
    final topK = candidates.take(k).toList();

    // 3. Inverse-distance weighted voting: w = 1/(score+ε).
    // ε=0.5 → score=0 olduğunda ağırlık 2 (tam dominasyon değil).
    const epsilon = 0.5;
    final Map<String, double> weightedVotes = {};
    final Map<String, int> rawVoteCount = {};
    final Map<String, double> totalScores = {};

    for (final m in topK) {
      // "#1", "#2" gibi suffix'leri soy — voting için base adı kullan.
      final name = m.fingerprint.name.replaceAll(RegExp(r'\s*#\d+$'), '');
      final w = 1.0 / (m.score + epsilon);
      weightedVotes[name] = (weightedVotes[name] ?? 0) + w;
      rawVoteCount[name] = (rawVoteCount[name] ?? 0) + 1;
      totalScores[name] = (totalScores[name] ?? 0) + m.score;
    }

    // En yüksek ağırlık toplamı kazanır; ağırlık eşitliğinde düşük toplam skor.
    String? winner;
    double maxWeight = -1;
    double winnerScore = double.infinity;

    weightedVotes.forEach((name, weight) {
      final score = totalScores[name] ?? 0;
      if (weight > maxWeight ||
          (weight == maxWeight && score < winnerScore)) {
        winner = name;
        maxWeight = weight;
        winnerScore = score;
      }
    });

    if (winner == null) return null;

    // Kazanan konumun en iyi (en düşük skorlu) fingerprint'ini döndür.
    final best = topK.firstWhere(
          (m) => m.fingerprint.name.replaceAll(RegExp(r'\s*#\d+$'), '') == winner,
    );
    return FingerprintMatch(
      fingerprint: best.fingerprint,
      score: best.score,
      voteCount: rawVoteCount[winner] ?? 1,
      k: topK.length,
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
