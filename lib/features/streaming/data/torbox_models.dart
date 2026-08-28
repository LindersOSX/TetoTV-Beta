class TorBoxAccount {
  const TorBoxAccount({
    required this.id,
    required this.email,
    required this.plan,
    required this.isSubscribed,
    this.premiumUntil,
  });

  final int id;
  final String email;
  final int plan;
  final bool isSubscribed;
  final DateTime? premiumUntil;

  String get planName => switch (plan) {
    1 => 'Essential',
    2 => 'Pro',
    3 => 'Standard',
    _ => 'Free',
  };

  bool get hasApiStreaming =>
      plan > 0 &&
      isSubscribed &&
      (premiumUntil == null || premiumUntil!.isAfter(DateTime.now()));

  factory TorBoxAccount.fromJson(Map<String, dynamic> json) {
    return TorBoxAccount(
      id: _asInt(json['id']),
      email: json['email'] as String? ?? 'TorBox user',
      plan: _asInt(json['plan']),
      isSubscribed: json['is_subscribed'] as bool? ?? false,
      premiumUntil: switch (json['premium_expires_at']) {
        final String value when value.isNotEmpty => DateTime.tryParse(value),
        _ => null,
      },
    );
  }
}

class TorBoxTorrent {
  const TorBoxTorrent({
    required this.id,
    required this.name,
    required this.downloadState,
    required this.progress,
    required this.downloadFinished,
    required this.cached,
    required this.files,
  });

  final int id;
  final String name;
  final String downloadState;
  final double progress;
  final bool downloadFinished;
  final bool cached;
  final List<TorBoxFile> files;

  bool get isReady => (downloadFinished || cached) && files.isNotEmpty;

  bool get isDownloadActivity {
    final value = downloadState.toLowerCase();
    return value.contains('downloading') ||
        value.contains('queued') ||
        value.contains('stalled');
  }

  bool get hasFailed {
    final value = downloadState.toLowerCase();
    return value.contains('error') ||
        value.contains('failed') ||
        value.contains('missing files');
  }

  factory TorBoxTorrent.fromJson(Map<String, dynamic> json) {
    final rawProgress = _asDouble(json['progress']);
    return TorBoxTorrent(
      id: _asInt(json['id']),
      name: json['name'] as String? ?? 'TorBox torrent',
      downloadState: json['download_state'] as String? ?? 'processing',
      progress: (rawProgress > 1 ? rawProgress / 100 : rawProgress).clamp(0, 1),
      downloadFinished: json['download_finished'] as bool? ?? false,
      cached: json['cached'] as bool? ?? false,
      files: (json['files'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(TorBoxFile.fromJson)
          .toList(growable: false),
    );
  }
}

class TorBoxFile {
  const TorBoxFile({required this.id, required this.name, required this.size});

  final int id;
  final String name;
  final int size;

  bool get isPlayable {
    final lower = name.toLowerCase();
    return const [
      '.mkv',
      '.mp4',
      '.webm',
      '.avi',
      '.mov',
      '.m4v',
    ].any(lower.endsWith);
  }

  factory TorBoxFile.fromJson(Map<String, dynamic> json) {
    return TorBoxFile(
      id: _asInt(json['id']),
      name: json['short_name'] as String? ?? json['name'] as String? ?? 'video',
      size: _asInt(json['size']),
    );
  }
}

int _asInt(Object? value) => switch (value) {
  final int number => number,
  final num number => number.toInt(),
  final String text => int.tryParse(text) ?? 0,
  _ => 0,
};

double _asDouble(Object? value) => switch (value) {
  final num number => number.toDouble(),
  final String text => double.tryParse(text) ?? 0,
  _ => 0,
};
