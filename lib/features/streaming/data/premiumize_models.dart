class PremiumizeAccount {
  const PremiumizeAccount({
    required this.customerId,
    required this.limitUsed,
    required this.boosterPoints,
    this.premiumUntil,
  });

  final String customerId;
  final DateTime? premiumUntil;
  final double limitUsed;
  final double boosterPoints;

  bool get isPremium => premiumUntil?.isAfter(DateTime.now().toUtc()) == true;

  factory PremiumizeAccount.fromJson(Map<String, dynamic> json) =>
      PremiumizeAccount(
        customerId: json['customer_id']?.toString() ?? 'Premiumize user',
        premiumUntil: _unixDate(json['premium_until']),
        limitUsed: _asDouble(json['limit_used']).clamp(0, 1),
        boosterPoints: _asDouble(json['booster_points']),
      );
}

class PremiumizeFile {
  const PremiumizeFile({
    required this.name,
    required this.size,
    required this.link,
    this.id,
  });

  final String? id;
  final String name;
  final int size;
  final Uri link;

  bool get isPlayable => RegExp(
    r'\.(mkv|mp4|avi|webm|mov|m4v|ts|m2ts)$',
    caseSensitive: false,
  ).hasMatch(name);

  factory PremiumizeFile.fromJson(Map<String, dynamic> json) {
    final name = json['path']?.toString().trim().isNotEmpty == true
        ? json['path'].toString().trim()
        : json['name']?.toString().trim() ?? '';
    final link = _secureUri(json['link']);
    if (name.isEmpty || link == null) {
      throw const FormatException('Premiumize returned an invalid file.');
    }
    return PremiumizeFile(
      id: json['id']?.toString(),
      name: name,
      size: _asInt(json['size']),
      link: link,
    );
  }
}

class PremiumizeTransfer {
  const PremiumizeTransfer({
    required this.id,
    required this.name,
    required this.status,
    required this.progress,
    required this.message,
    this.folderId,
    this.fileId,
  });

  final String id;
  final String name;
  final String status;
  final double progress;
  final String message;
  final String? folderId;
  final String? fileId;

  bool get isReady => status == 'finished' || status == 'seeding';
  bool get hasFailed => status == 'error';

  factory PremiumizeTransfer.fromJson(Map<String, dynamic> json) =>
      PremiumizeTransfer(
        id: json['id']?.toString() ?? '',
        name: json['name']?.toString() ?? 'Premiumize transfer',
        status: json['status']?.toString().toLowerCase() ?? 'queued',
        progress: _asDouble(json['progress']).clamp(0, 1),
        message: json['message']?.toString() ?? '',
        folderId: _optionalString(json['folder_id']),
        fileId: _optionalString(json['file_id']),
      );
}

class PremiumizeTransferCreation {
  const PremiumizeTransferCreation({required this.id, required this.name});

  final String id;
  final String name;
}

class PremiumizeFolderEntry {
  const PremiumizeFolderEntry({
    required this.id,
    required this.name,
    required this.isFolder,
    this.size = 0,
    this.link,
  });

  final String id;
  final String name;
  final bool isFolder;
  final int size;
  final Uri? link;

  factory PremiumizeFolderEntry.fromJson(Map<String, dynamic> json) {
    final id = json['id']?.toString().trim() ?? '';
    final name = json['name']?.toString().trim() ?? '';
    final isFolder = json['type']?.toString() == 'folder';
    final link = isFolder ? null : _secureUri(json['link']);
    if (id.isEmpty || name.isEmpty || (!isFolder && link == null)) {
      throw const FormatException(
        'Premiumize returned an invalid folder entry.',
      );
    }
    return PremiumizeFolderEntry(
      id: id,
      name: name,
      isFolder: isFolder,
      size: _asInt(json['size']),
      link: link,
    );
  }
}

DateTime? _unixDate(Object? value) {
  final seconds = _asInt(value);
  if (seconds <= 0) return null;
  return DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
}

String? _optionalString(Object? value) {
  final normalized = value?.toString().trim() ?? '';
  return normalized.isEmpty ? null : normalized;
}

Uri? _secureUri(Object? value) {
  final uri = Uri.tryParse(value?.toString().trim() ?? '');
  return uri != null && uri.scheme == 'https' && uri.hasAuthority ? uri : null;
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
