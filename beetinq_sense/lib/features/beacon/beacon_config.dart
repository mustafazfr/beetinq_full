/// Sahadaki Pi beacon'larının yayınladığı sabit UUID. Uygulamaya gömülü —
/// yeni cihazlarda elle girilmesine gerek yok; açılışta otomatik bu UUID ile
/// tarama başlar (BeaconController.initSdk). Farklı beacon setiyle çalışılacaksa
/// burayı değiştir.
const String kDefaultBeaconUuid = 'E2C56DB5-DFFB-48D2-B060-D0F5A71096E0';

class BeaconTarget {
  final String uuid; // Uppercase + dashed (canonical)
  final int? major;  // Optional filter
  final int? minor;  // Optional filter

  const BeaconTarget({
    required this.uuid,
    this.major,
    this.minor,
  });

  Map<String, dynamic> toJson() => {
    'uuid': uuid,
    'major': major,
    'minor': minor,
  };

  static BeaconTarget fromJson(Map<String, dynamic> json) => BeaconTarget(
    uuid: (json['uuid'] as String?) ?? '',
    major: json['major'] as int?,
    minor: json['minor'] as int?,
  );
}
