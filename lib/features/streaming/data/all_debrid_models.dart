class AllDebridAccount {
  const AllDebridAccount({
    required this.username,
    required this.email,
    required this.isPremium,
    this.premiumUntil,
  });

  final String username;
  final String email;
  final bool isPremium;
  final DateTime? premiumUntil;

  factory AllDebridAccount.fromJson(Map<String, dynamic> json) =>
      AllDebridAccount(
        username: json['username']?.toString() ?? 'AllDebrid user',
        email: json['email']?.toString() ?? '',
        isPremium: json['isPremium'] == true,
        premiumUntil: _unixDate(json['premiumUntil']),
      );
}

class AllDebridMagnetUpload {
  const AllDebridMagnetUpload({required this.id, required this.ready});

  final int id;
  final bool ready;
}

class AllDebridMagnetStatus {
  const AllDebridMagnetStatus({
    required this.id,
    required this.status,
    required this.statusCode,
    required this.downloaded,
    required this.size,
  });

  final int id;
  final String status;
  final int statusCode;
  final int downloaded;
  final int size;

  bool get isReady => statusCode == 4;
  bool get hasFailed => statusCode >= 5;
  double get progress => size <= 0 ? 0 : (downloaded / size).clamp(0, 1);

  factory AllDebridMagnetStatus.fromJson(Map<String, dynamic> json) =>
      AllDebridMagnetStatus(
        id: _asInt(json['id']),
        status: json['status']?.toString() ?? 'Unknown',
        statusCode: _asInt(json['statusCode']),
        downloaded: _asInt(json['downloaded']),
        size: _asInt(json['size']),
      );
}

class AllDebridTorrentFile {
  const AllDebridTorrentFile({
    required this.name,
    required this.size,
    required this.link,
  });

  final String name;
  final int size;
  final String link;

  bool get isPlayable => RegExp(
    r'\.(mkv|mp4|avi|webm|mov|m4v|ts)$',
    caseSensitive: false,
  ).hasMatch(name);
}

DateTime? _unixDate(Object? value) {
  final seconds = _asInt(value);
  if (seconds <= 0) return null;
  return DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
}

int _asInt(Object? value) => switch (value) {
  final int number => number,
  final num number => number.toInt(),
  final String text => int.tryParse(text) ?? 0,
  _ => 0,
};
