class RealDebridAccount {
  const RealDebridAccount({
    required this.id,
    required this.username,
    required this.type,
    this.premiumUntil,
  });

  final int id;
  final String username;
  final String type;
  final DateTime? premiumUntil;

  bool get isPremium =>
      type.toLowerCase() == 'premium' &&
      (premiumUntil == null || premiumUntil!.isAfter(DateTime.now()));

  factory RealDebridAccount.fromJson(Map<String, dynamic> json) {
    return RealDebridAccount(
      id: json['id'] as int,
      username: json['username'] as String,
      type: json['type'] as String? ?? 'unknown',
      premiumUntil: switch (json['expiration']) {
        final String value when value.isNotEmpty => DateTime.tryParse(value),
        _ => null,
      },
    );
  }
}

class RealDebridTorrentFile {
  const RealDebridTorrentFile({
    required this.id,
    required this.path,
    required this.bytes,
    required this.selected,
  });

  final int id;
  final String path;
  final int bytes;
  final bool selected;

  bool get isPlayable {
    final lower = path.toLowerCase();
    return const ['.mkv', '.mp4', '.webm', '.avi', '.m4v'].any(lower.endsWith);
  }

  factory RealDebridTorrentFile.fromJson(Map<String, dynamic> json) {
    return RealDebridTorrentFile(
      id: json['id'] as int,
      path: json['path'] as String,
      bytes: json['bytes'] as int? ?? 0,
      selected: (json['selected'] as int?) == 1,
    );
  }
}

class RealDebridTorrentInfo {
  const RealDebridTorrentInfo({
    required this.id,
    required this.filename,
    required this.status,
    required this.progress,
    required this.files,
    required this.links,
    this.hash,
  });

  final String id;
  final String? hash;
  final String filename;
  final String status;
  final double progress;
  final List<RealDebridTorrentFile> files;
  final List<String> links;

  bool get isDownloaded => status == 'downloaded';
  bool get needsFileSelection => status == 'waiting_files_selection';
  bool get isDownloadActivity => const {
    'queued',
    'downloading',
    'compressing',
    'uploading',
  }.contains(status);
  bool get hasFailed =>
      const {'magnet_error', 'error', 'virus', 'dead'}.contains(status);

  factory RealDebridTorrentInfo.fromJson(Map<String, dynamic> json) {
    final files = (json['files'] as List<dynamic>? ?? const [])
        .cast<Map<String, dynamic>>()
        .map(RealDebridTorrentFile.fromJson)
        .toList(growable: false);
    return RealDebridTorrentInfo(
      id: json['id'] as String,
      hash: switch (json['hash']) {
        final String value when value.trim().isNotEmpty =>
          value.trim().toLowerCase(),
        _ => null,
      },
      filename: json['filename'] as String? ?? 'Torrent',
      status: json['status'] as String? ?? 'unknown',
      progress: (json['progress'] as num? ?? 0).toDouble(),
      files: files,
      links: (json['links'] as List<dynamic>? ?? const [])
          .cast<String>()
          .toList(growable: false),
    );
  }
}

class RealDebridUnrestrictedLink {
  const RealDebridUnrestrictedLink({
    required this.download,
    required this.filename,
    this.mimeType,
    this.filesize,
  });

  final Uri download;
  final String filename;
  final String? mimeType;
  final int? filesize;

  factory RealDebridUnrestrictedLink.fromJson(Map<String, dynamic> json) {
    return RealDebridUnrestrictedLink(
      download: Uri.parse(json['download'] as String),
      filename: json['filename'] as String? ?? 'Video',
      mimeType: json['mimeType'] as String?,
      filesize: json['filesize'] as int?,
    );
  }
}
