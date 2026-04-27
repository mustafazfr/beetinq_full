/// Karşılaşılan bir cihazın RAM'de tutulan encounter kaydı.
/// anonId = decodeAnonId(major, minor); major/minor collision olursa
/// iki cihaz aynı encounter'ı paylaşır (kabul edilen risk — Task 1.5.2 notu).
class ContactEncounter {
  final String seenAnonId;
  final DateTime firstSeen;
  DateTime lastSeen;
  final List<int> rssiSamples;
  bool reportedAsContact;

  ContactEncounter({
    required this.seenAnonId,
    required this.firstSeen,
    required this.lastSeen,
    List<int>? rssiSamples,
    this.reportedAsContact = false,
  }) : rssiSamples = rssiSamples ?? <int>[];

  Duration get duration => lastSeen.difference(firstSeen);
  int get sampleCount => rssiSamples.length;

  double get avgRssi {
    if (rssiSamples.isEmpty) return 0;
    final sum = rssiSamples.fold<int>(0, (a, b) => a + b);
    return sum / rssiSamples.length;
  }

  /// Son [window] süresi içindeki RSSI örneklerinin ortalaması. Son örneklem
  /// sayısı da döndürülür — tetikleme mantığı için gerekli.
  /// Notu: örnekler zamanstampsız tutulduğu için window yaklaşık olarak
  /// son N örnekle hesaplanır (N = window saniye × ~1 örnek/saniye).
  ({double avg, int count}) recentWindow(Duration window) {
    if (rssiSamples.isEmpty) return (avg: 0, count: 0);
    final n = window.inSeconds.clamp(1, rssiSamples.length);
    final tail = rssiSamples.sublist(rssiSamples.length - n);
    final sum = tail.fold<int>(0, (a, b) => a + b);
    return (avg: sum / tail.length, count: tail.length);
  }
}
