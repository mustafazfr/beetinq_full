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
  /// Bu temasın izlendiği stand/konum. Per-stand temas (kullanıcı tercihi):
  /// raporlayan telefon başka standa geçince encounter "rotate" edilip bu yeni
  /// stand için YENİ bir temas başlatılır. Backend'e bu locationName gider.
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

  /// Verilen zaman penceresinin (örn. son 60s) içindeki örneklerin
  /// ortalama RSSI'si ve sayısı.
  ///
  /// Sample yoğunluğundan bağımsız: low-power scan modunda dakikada 12 sample
  /// gelse de, normal modda 200 sample gelse de eşik kontrolü doğru çalışır.
  /// Önceki tarih: `rssiSamples.sublist(n - window.inSeconds)` — "1 sample/sn"
  /// varsayıyordu ve scan period değiştikçe yanlış pencere kesiyordu.
  ({double avg, int count}) recentWindow(Duration window) {
    if (samples.isEmpty) return (avg: 0, count: 0);
    final cutoff = lastSeen.subtract(window);
    int sum = 0;
    int count = 0;
    // Listeye kronolojik eklendiği için tersten yürüyüp ilk eski sample'a
    // gelince durmak yeterli (O(window) vs O(N)).
    for (int i = samples.length - 1; i >= 0; i--) {
      final s = samples[i];
      if (s.ts.isBefore(cutoff)) break;
      sum += s.rssi;
      count++;
    }
    if (count == 0) return (avg: 0, count: 0);
    return (avg: sum / count, count: count);
  }
}
