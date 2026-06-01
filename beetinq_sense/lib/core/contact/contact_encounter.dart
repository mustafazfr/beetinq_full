/// Tek RSSI ölçümü: değer + ölçüm zamanı.
///
/// Encounter aggregation timestamp-aware (Task 2.13): "son N saniye" eşik
/// kontrolü gerçek zaman penceresinden hesaplanır, sample yoğunluğundan
/// (low-power mode 5sn/sample vs normal mode 300ms/sample) bağımsız.
class RssiSample {
  final int rssi;
  final DateTime ts;
  const RssiSample(this.rssi, this.ts);
}

/// Karşılaşılan bir cihazın RAM'de tutulan encounter kaydı.
/// anonId = decodeAnonId(major, minor); major/minor collision olursa
/// iki cihaz aynı encounter'ı paylaşır (kabul edilen risk — Task 1.5.2 notu).
class ContactEncounter {
  final String seenAnonId;
  /// Bu encounter için sabit idempotency anahtarı. Re-report'larda (uzun
  /// temas süre güncellemesi) aynı değer gider; backend upsert ile tek kaydı
  /// günceller. Encounter ilk oluştuğunda controller bir uuid v4 atar.
  final String? clientEventId;
  final DateTime firstSeen;
  DateTime lastSeen;
  final List<RssiSample> samples;
  bool reportedAsContact;
  /// Bu encounter en son ne zaman API'ye raporlandı. Re-report aralığı
  /// (kContactReReportIntervalSeconds) buna göre ölçülür. null = hiç gönderilmedi.
  DateTime? lastReportedAt;
  /// Bu temasın başladığı stand/konum. TASARIM (kullanıcı kararı): temas "tek
  /// sürekli temas" — raporlayan telefon başka standa geçse de encounter
  /// BÖLÜNMEZ (per-stand rotate KALDIRILDI). locationName, encounter ilk
  /// oluştuğunda atanır ve sabit kalır; backend'e bu değer gider.
  String? locationName;

  ContactEncounter({
    required this.seenAnonId,
    required this.firstSeen,
    required this.lastSeen,
    this.clientEventId,
    List<RssiSample>? samples,
    this.reportedAsContact = false,
    this.lastReportedAt,
    this.locationName,
  }) : samples = samples ?? <RssiSample>[];

  Duration get duration => lastSeen.difference(firstSeen);
  int get sampleCount => samples.length;

  double get avgRssi {
    if (samples.isEmpty) return 0;
    final sum = samples.fold<int>(0, (a, b) => a + b.rssi);
    return sum / samples.length;
  }

  /// Verilen zaman penceresinin (örn. son 10s) içindeki örneklerin
  /// ortalama + MEDYAN RSSI'si ve örnek sayısı.
  ///
  /// Medyan, tek bir uç okumanın (iPhone'un sık verdiği zayıf/sıçramalı RSSI)
  /// eşik kararlarını (tetik > -80 / evict <= -85) sallamasını engeller — bu
  /// yüzden controller kararları `avg` yerine `median` üzerinden alır. `avg`
  /// hâlâ döner (backend'e raporlanan ortalama RSSI için kullanılıyor).
  ///
  /// Sample yoğunluğundan bağımsız: low-power scan modunda dakikada 12 sample
  /// gelse de, normal modda 200 sample gelse de eşik kontrolü doğru çalışır.
  ({double avg, double median, int count}) recentWindow(Duration window) {
    if (samples.isEmpty) return (avg: 0, median: 0, count: 0);
    final cutoff = lastSeen.subtract(window);
    final inWindow = <int>[];
    // Listeye kronolojik eklendiği için tersten yürüyüp ilk eski sample'a
    // gelince durmak yeterli (O(window) vs O(N)).
    for (int i = samples.length - 1; i >= 0; i--) {
      final s = samples[i];
      if (s.ts.isBefore(cutoff)) break;
      inWindow.add(s.rssi);
    }
    if (inWindow.isEmpty) return (avg: 0, median: 0, count: 0);
    final sum = inWindow.fold<int>(0, (a, b) => a + b);
    final sorted = List<int>.from(inWindow)..sort();
    final mid = sorted.length ~/ 2;
    final median = sorted.length.isOdd
        ? sorted[mid].toDouble()
        : (sorted[mid - 1] + sorted[mid]) / 2.0;
    return (avg: sum / inWindow.length, median: median, count: inWindow.length);
  }
}
