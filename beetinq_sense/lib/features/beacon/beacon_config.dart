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
