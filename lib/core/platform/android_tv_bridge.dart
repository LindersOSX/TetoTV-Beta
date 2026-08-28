import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class AndroidP256KeyPair {
  const AndroidP256KeyPair({
    required this.privateD,
    required this.publicX,
    required this.publicY,
  });

  final Uint8List privateD;
  final Uint8List publicX;
  final Uint8List publicY;
}

class TvDisplayMode {
  const TvDisplayMode({
    required this.id,
    required this.width,
    required this.height,
    required this.refreshRate,
  });

  final int id;
  final int width;
  final int height;
  final double refreshRate;

  factory TvDisplayMode.fromMap(Map<Object?, Object?> value) => TvDisplayMode(
    id: value['id'] as int? ?? 0,
    width: value['width'] as int? ?? 0,
    height: value['height'] as int? ?? 0,
    refreshRate: (value['refreshRate'] as num?)?.toDouble() ?? 0,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'width': width,
    'height': height,
    'refreshRate': refreshRate,
  };
}

@immutable
class ExternalVideoPlayerApp {
  const ExternalVideoPlayerApp({
    required this.packageName,
    required this.label,
  });

  final String packageName;
  final String label;

  factory ExternalVideoPlayerApp.fromMap(Map<Object?, Object?> value) {
    return ExternalVideoPlayerApp(
      packageName: value['packageName'] as String? ?? '',
      label: value['label'] as String? ?? '',
    );
  }
}

/// A verified episode-release alarm that Android can deliver while TetoTV is
/// in the background. [simulcast] represents the normal calendar airtime; it
/// must not be described as an English dub. [dub] is reserved for sources
/// which explicitly identify a dub release time.
enum EpisodeReleaseNotificationKind { simulcast, dub }

@immutable
class EpisodeReleaseNotification {
  const EpisodeReleaseNotification({
    required this.mediaId,
    required this.episode,
    required this.title,
    required this.releaseAt,
    required this.kind,
  });

  final int mediaId;
  final int episode;
  final String title;
  final DateTime releaseAt;
  final EpisodeReleaseNotificationKind kind;

  Map<String, Object> toPlatformMap() => {
    'mediaId': mediaId,
    'episode': episode,
    'title': title,
    'atMillis': releaseAt.millisecondsSinceEpoch,
    'kind': kind.name,
  };
}

class TvCodecCapability {
  const TvCodecCapability({
    required this.name,
    required this.mime,
    required this.hardware,
    this.tenBit = false,
    this.maxWidth = 0,
    this.maxHeight = 0,
  });

  final String name;
  final String mime;
  final bool hardware;
  final bool tenBit;
  final int maxWidth;
  final int maxHeight;

  factory TvCodecCapability.fromMap(Map<Object?, Object?> value) =>
      TvCodecCapability(
        name: value['name'] as String? ?? '',
        mime: value['mime'] as String? ?? '',
        hardware: value['hardware'] as bool? ?? false,
        tenBit: value['tenBit'] as bool? ?? false,
        maxWidth: value['maxWidth'] as int? ?? 0,
        maxHeight: value['maxHeight'] as int? ?? 0,
      );

  Map<String, Object?> toJson() => {
    'name': name,
    'mime': mime,
    'hardware': hardware,
    'tenBit': tenBit,
    'maxWidth': maxWidth,
    'maxHeight': maxHeight,
  };
}

class TvDeviceProfile {
  const TvDeviceProfile({
    required this.manufacturer,
    required this.model,
    required this.sdk,
    required this.abis,
    required this.displayModes,
    required this.hdrTypes,
    required this.codecs,
    required this.audioOutputs,
  });

  const TvDeviceProfile.unknown()
    : manufacturer = 'Unknown',
      model = 'Unknown',
      sdk = 0,
      abis = const [],
      displayModes = const [],
      hdrTypes = const [],
      codecs = const [],
      audioOutputs = const [];

  final String manufacturer;
  final String model;
  final int sdk;
  final List<String> abis;
  final List<TvDisplayMode> displayModes;
  final List<int> hdrTypes;
  final List<TvCodecCapability> codecs;
  final List<Map<String, Object?>> audioOutputs;

  String get key => '$manufacturer/$model/sdk$sdk'.toLowerCase();
  bool get hasHdr => hdrTypes.isNotEmpty;
  bool get hasHdmiAudio => audioOutputs.any((output) => output['hdmi'] == true);

  bool supportsCodec(String? codec) {
    final normalized = codec?.toLowerCase() ?? '';
    final mime = switch (normalized) {
      final value when value.contains('av1') => 'video/av01',
      final value when value.contains('hevc') || value.contains('h265') =>
        'video/hevc',
      final value when value.contains('h264') || value.contains('avc') =>
        'video/avc',
      final value when value.contains('vp9') => 'video/x-vnd.on2.vp9',
      _ => '',
    };
    if (mime.isEmpty) return true;
    return codecs.any((item) => item.mime == mime && item.hardware);
  }

  Map<String, Object?> toJson() => {
    'manufacturer': manufacturer,
    'model': model,
    'sdk': sdk,
    'abis': abis,
    'displayModes': displayModes.map((mode) => mode.toJson()).toList(),
    'hdrTypes': hdrTypes,
    'codecs': codecs.map((codec) => codec.toJson()).toList(),
    'audioOutputs': audioOutputs,
  };

  /// Diagnostic-safe capability projection. Android audio product names can
  /// be user-assigned (for example, a person's Bluetooth speaker name), so a
  /// support report retains only the technical fields needed to troubleshoot
  /// playback.
  Map<String, Object?> toDiagnosticsJson() => {
    'manufacturer': manufacturer,
    'model': model,
    'sdk': sdk,
    'abis': abis,
    'displayModes': displayModes.map((mode) => mode.toJson()).toList(),
    'hdrTypes': hdrTypes,
    'codecs': codecs.map((codec) => codec.toJson()).toList(),
    'audioOutputs': [
      for (final output in audioOutputs)
        {
          for (final key in const {
            'type',
            'channels',
            'sampleRates',
            'encodings',
            'hdmi',
          })
            if (output.containsKey(key)) key: output[key],
        },
    ],
  };

  factory TvDeviceProfile.fromMap(Map<Object?, Object?> value) {
    List<Map<Object?, Object?>> maps(Object? input) =>
        (input as List? ?? const [])
            .whereType<Map>()
            .map((item) => item.cast<Object?, Object?>())
            .toList(growable: false);
    return TvDeviceProfile(
      manufacturer: value['manufacturer'] as String? ?? 'Unknown',
      model: value['model'] as String? ?? 'Unknown',
      sdk: value['sdk'] as int? ?? 0,
      abis: (value['abis'] as List? ?? const []).whereType<String>().toList(),
      displayModes: maps(
        value['displayModes'],
      ).map(TvDisplayMode.fromMap).toList(growable: false),
      hdrTypes: (value['hdrTypes'] as List? ?? const [])
          .whereType<int>()
          .toList(),
      codecs: maps(
        value['codecs'],
      ).map(TvCodecCapability.fromMap).toList(growable: false),
      audioOutputs: maps(value['audioOutputs'])
          .map(
            (item) => item.map((key, value) => MapEntry(key.toString(), value)),
          )
          .toList(growable: false),
    );
  }
}

class MediaAction {
  const MediaAction(this.action, this.value);
  final String action;
  final int? value;
}

class DiscordBridgeEvent {
  const DiscordBridgeEvent(this.type, this.data);

  final String type;
  final Map<Object?, Object?> data;
}

/// A tri-state result keeps a missing or slow native bridge from being
/// mistaken for a phone. Discord may open browser OAuth only after Android
/// explicitly reports [mobile].
enum AndroidDeviceCategory { television, mobile, unknown }

class DiscordTokenBundle {
  const DiscordTokenBundle({
    required this.accessToken,
    required this.refreshToken,
    required this.tokenType,
    required this.expiresAt,
    required this.scopes,
  });

  final String accessToken;
  final String refreshToken;
  final int tokenType;
  final DateTime expiresAt;
  final String scopes;

  factory DiscordTokenBundle.fromMap(Map<Object?, Object?> value) {
    return DiscordTokenBundle(
      accessToken: value['accessToken'] as String? ?? '',
      refreshToken: value['refreshToken'] as String? ?? '',
      tokenType: (value['tokenType'] as num?)?.toInt() ?? 0,
      expiresAt: DateTime.fromMillisecondsSinceEpoch(
        (value['expiresAtMs'] as num?)?.toInt() ?? 0,
      ),
      scopes: value['scopes'] as String? ?? '',
    );
  }
}

class AppVersionInfo {
  const AppVersionInfo({required this.name, required this.code});

  const AppVersionInfo.unknown() : name = 'unknown', code = 0;

  final String name;
  final int code;

  factory AppVersionInfo.fromMap(Map<Object?, Object?> value) => AppVersionInfo(
    name: value['versionName'] as String? ?? 'unknown',
    code: (value['versionCode'] as num?)?.toInt() ?? 0,
  );
}

class LocalCrashSummaryHistory {
  const LocalCrashSummaryHistory({
    required this.summaries,
    required this.droppedOutsideWindow,
    required this.droppedForCapacity,
  });

  const LocalCrashSummaryHistory.empty()
    : summaries = const [],
      droppedOutsideWindow = 0,
      droppedForCapacity = 0;

  final List<Map<String, Object?>> summaries;
  final int droppedOutsideWindow;
  final int droppedForCapacity;

  factory LocalCrashSummaryHistory.fromMap(Map<Object?, Object?> value) {
    int count(String key) =>
        ((value[key] as num?)?.toInt() ?? 0).clamp(0, 0x7fffffff);
    return LocalCrashSummaryHistory(
      summaries: [
        for (final item in value['summaries'] as List? ?? const <Object?>[])
          if (item is Map)
            item.map((key, entry) => MapEntry(key.toString(), entry)),
      ],
      droppedOutsideWindow: count('dropped_outside_window'),
      droppedForCapacity: count('dropped_for_capacity'),
    );
  }
}

class LocalMediaDocument {
  const LocalMediaDocument({
    required this.uri,
    required this.name,
    this.mimeType,
    this.size,
    this.persistedReadPermission = false,
  });

  final Uri uri;
  final String name;
  final String? mimeType;
  final int? size;
  final bool persistedReadPermission;

  factory LocalMediaDocument.fromMap(Map<Object?, Object?> value) {
    final rawUri = value['uri'] as String? ?? '';
    final uri = Uri.tryParse(rawUri);
    if (uri == null ||
        uri.scheme != 'content' ||
        !uri.hasAuthority ||
        uri.authority.trim().isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment) {
      throw const FormatException('Android returned an invalid local video.');
    }
    return LocalMediaDocument(
      uri: uri,
      name: (value['name'] as String?)?.trim().isNotEmpty == true
          ? (value['name'] as String).trim()
          : 'Local video',
      mimeType: (value['mimeType'] as String?)?.trim(),
      size: (value['size'] as num?)?.toInt(),
      persistedReadPermission:
          value['persistedReadPermission'] as bool? ?? false,
    );
  }
}

class DirectTorrentCapability {
  const DirectTorrentCapability({
    required this.supported,
    required this.engine,
    required this.maximumFileBytes,
    required this.supportsSeeking,
    required this.temporaryStorage,
  });

  const DirectTorrentCapability.unsupported()
    : supported = false,
      engine = 'unavailable',
      maximumFileBytes = 0,
      supportsSeeking = false,
      temporaryStorage = false;

  final bool supported;
  final String engine;
  final int maximumFileBytes;
  final bool supportsSeeking;
  final bool temporaryStorage;

  factory DirectTorrentCapability.fromMap(Map<Object?, Object?> value) =>
      DirectTorrentCapability(
        supported: value['supported'] as bool? ?? false,
        engine: value['engine'] as String? ?? 'unavailable',
        maximumFileBytes: (value['maximumFileBytes'] as num?)?.toInt() ?? 0,
        supportsSeeking: value['supportsSeeking'] as bool? ?? false,
        temporaryStorage: value['temporaryStorage'] as bool? ?? false,
      );
}

class DirectTorrentNativeSession {
  const DirectTorrentNativeSession({
    required this.sessionId,
    required this.uri,
    required this.size,
    required this.mimeType,
    required this.selectedBasename,
  });

  final String sessionId;
  final Uri uri;
  final int size;
  final String mimeType;
  final String selectedBasename;

  factory DirectTorrentNativeSession.fromMap(Map<Object?, Object?> value) {
    final sessionId = (value['sessionId'] as String?)?.trim() ?? '';
    final uri = Uri.tryParse((value['url'] as String?)?.trim() ?? '');
    final validToken =
        uri != null && RegExp(r'^/[0-9a-f]{64}$').hasMatch(uri.path);
    final selectedBasename =
        (value['selectedBasename'] as String?)?.trim() ?? '';
    final validSelectedBasename =
        selectedBasename.isNotEmpty &&
        selectedBasename.length <= 512 &&
        !RegExp(r'[\\/\x00-\x1f\x7f]').hasMatch(selectedBasename);
    if (sessionId.isEmpty ||
        sessionId.length > 128 ||
        uri == null ||
        uri.scheme != 'http' ||
        uri.host != '127.0.0.1' ||
        !uri.hasPort ||
        uri.port <= 0 ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        !validToken ||
        !validSelectedBasename) {
      throw const FormatException(
        'Android returned an invalid direct torrent session.',
      );
    }
    return DirectTorrentNativeSession(
      sessionId: sessionId,
      uri: uri,
      size: (value['size'] as num?)?.toInt() ?? 0,
      mimeType: (value['mimeType'] as String?)?.trim().isNotEmpty == true
          ? (value['mimeType'] as String).trim()
          : 'application/octet-stream',
      selectedBasename: selectedBasename,
    );
  }
}

class ApkCompatibilityInfo {
  const ApkCompatibilityInfo({
    required this.compatible,
    required this.issues,
    this.issueCodes = const [],
    this.packageName,
    this.versionCode = 0,
    this.versionName,
    this.installedVersionCode = 0,
    this.installedVersionName,
    this.minSdk = 0,
    this.archiveAbis = const [],
    this.deviceAbis = const [],
    this.signerMatches = false,
  });

  final bool compatible;
  final List<String> issues;
  final List<String> issueCodes;
  final String? packageName;
  final int versionCode;
  final String? versionName;
  final int installedVersionCode;
  final String? installedVersionName;
  final int minSdk;
  final List<String> archiveAbis;
  final List<String> deviceAbis;
  final bool signerMatches;

  factory ApkCompatibilityInfo.fromMap(Map<Object?, Object?> value) =>
      ApkCompatibilityInfo(
        compatible: value['compatible'] as bool? ?? false,
        issues: (value['issues'] as List? ?? const [])
            .whereType<String>()
            .toList(growable: false),
        issueCodes: (value['issueCodes'] as List? ?? const [])
            .whereType<String>()
            .toList(growable: false),
        packageName: value['packageName'] as String?,
        versionCode: (value['versionCode'] as num?)?.toInt() ?? 0,
        versionName: value['versionName'] as String?,
        installedVersionCode:
            (value['installedVersionCode'] as num?)?.toInt() ?? 0,
        installedVersionName: value['installedVersionName'] as String?,
        minSdk: (value['minSdk'] as num?)?.toInt() ?? 0,
        archiveAbis: (value['archiveAbis'] as List? ?? const [])
            .whereType<String>()
            .toList(growable: false),
        deviceAbis: (value['deviceAbis'] as List? ?? const [])
            .whereType<String>()
            .toList(growable: false),
        signerMatches: value['signerMatches'] as bool? ?? false,
      );
}

class AndroidTvBridge {
  AndroidTvBridge._() {
    _channel.setMethodCallHandler(_handleMethod);
  }

  static final instance = AndroidTvBridge._();
  static const _channel = MethodChannel('dev.tetotv/android_tv');
  final _mediaActions = StreamController<MediaAction>.broadcast();
  final _discordEvents = StreamController<DiscordBridgeEvent>.broadcast();
  final _externalPlayerReturns = StreamController<void>.broadcast();
  TvDeviceProfile? _cachedProfile;
  AndroidDeviceCategory? _cachedDeviceCategory;

  Stream<MediaAction> get mediaActions => _mediaActions.stream;
  Stream<DiscordBridgeEvent> get discordEvents => _discordEvents.stream;
  Stream<void> get externalPlayerReturns => _externalPlayerReturns.stream;

  Future<AndroidDeviceCategory> getDeviceCategory({
    bool refresh = false,
  }) async {
    if (!refresh && _cachedDeviceCategory != null) {
      return _cachedDeviceCategory!;
    }
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return AndroidDeviceCategory.mobile;
    }
    try {
      final television = await _channel.invokeMethod<bool>('isTelevision');
      if (television == null) return AndroidDeviceCategory.unknown;
      return _cachedDeviceCategory = television
          ? AndroidDeviceCategory.television
          : AndroidDeviceCategory.mobile;
    } on PlatformException {
      return AndroidDeviceCategory.unknown;
    } on MissingPluginException {
      return AndroidDeviceCategory.unknown;
    }
  }

  Future<bool> isTelevision({bool refresh = false}) async =>
      await getDeviceCategory(refresh: refresh) ==
      AndroidDeviceCategory.television;

  Future<dynamic> _handleMethod(MethodCall call) async {
    final args = (call.arguments as Map?)?.cast<Object?, Object?>();
    switch (call.method) {
      case 'mediaAction':
        if (args == null) return;
        _mediaActions.add(
          MediaAction(args['action'] as String? ?? '', args['value'] as int?),
        );
        return;
      case 'discordConnectionState':
      case 'discordPresenceError':
        _discordEvents.add(DiscordBridgeEvent(call.method, args ?? const {}));
        return;
      case 'discordTokenExpiring':
        _discordEvents.add(DiscordBridgeEvent(call.method, const {}));
        return;
      case 'externalPlayerReturned':
        _externalPlayerReturns.add(null);
        return;
    }
  }

  Future<Map<Object?, Object?>> discordSdkInfo() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return const {'available': false, 'status': 'unsupported'};
    }
    try {
      return await _channel.invokeMapMethod<Object?, Object?>(
            'discordSdkInfo',
          ) ??
          const {'available': false, 'status': 'unavailable'};
    } on PlatformException {
      return const {'available': false, 'status': 'unavailable'};
    } on MissingPluginException {
      return const {'available': false, 'status': 'unavailable'};
    }
  }

  Future<DiscordTokenBundle> discordAuthenticate() async {
    final result = await _channel.invokeMapMethod<Object?, Object?>(
      'discordAuthenticate',
    );
    if (result == null) {
      throw PlatformException(
        code: 'DISCORD_AUTH_EMPTY',
        message: 'Discord did not return an account token.',
      );
    }
    return DiscordTokenBundle.fromMap(result);
  }

  Future<void> discordCancelAuthentication() async {
    await _channel.invokeMethod<void>('discordCancelAuthentication');
  }

  Future<DiscordTokenBundle> discordRefreshToken(String refreshToken) async {
    final result = await _channel.invokeMapMethod<Object?, Object?>(
      'discordRefreshToken',
      {'refreshToken': refreshToken},
    );
    if (result == null) {
      throw PlatformException(
        code: 'DISCORD_REFRESH_EMPTY',
        message: 'Discord did not return a refreshed token.',
      );
    }
    return DiscordTokenBundle.fromMap(result);
  }

  Future<void> discordConnect(DiscordTokenBundle token) async {
    await _channel.invokeMethod<void>('discordConnect', {
      'accessToken': token.accessToken,
      'tokenType': token.tokenType,
    });
  }

  Future<bool> discordRevoke(String token) async {
    return await _channel.invokeMethod<bool>('discordRevoke', {
          'token': token,
        }) ??
        false;
  }

  Future<void> discordDisconnect() async {
    await _channel.invokeMethod<void>('discordDisconnect');
  }

  Future<TvDeviceProfile> getDeviceProfile({bool refresh = false}) async {
    if (!refresh && _cachedProfile != null) return _cachedProfile!;
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return const TvDeviceProfile.unknown();
    }
    try {
      final result = await _channel.invokeMapMethod<Object?, Object?>(
        'getDeviceProfile',
      );
      return _cachedProfile = result == null
          ? const TvDeviceProfile.unknown()
          : TvDeviceProfile.fromMap(result);
    } on PlatformException {
      return const TvDeviceProfile.unknown();
    }
  }

  Future<AppVersionInfo> getAppVersion() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return const AppVersionInfo.unknown();
    }
    try {
      final result = await _channel.invokeMapMethod<Object?, Object?>(
        'getAppVersion',
      );
      return result == null
          ? const AppVersionInfo.unknown()
          : AppVersionInfo.fromMap(result);
    } on PlatformException {
      return const AppVersionInfo.unknown();
    }
  }

  Future<String> installApk(String path) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      throw PlatformException(
        code: 'APK_INSTALL_UNSUPPORTED',
        message: 'APK installation is only supported on Android.',
      );
    }
    return await _channel.invokeMethod<String>('installApk', {'path': path}) ??
        'launched';
  }

  Future<ApkCompatibilityInfo> inspectApk(String path) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return const ApkCompatibilityInfo(
        compatible: false,
        issues: ['APK installation is only supported on Android.'],
      );
    }
    final result = await _channel.invokeMapMethod<Object?, Object?>(
      'inspectApk',
      {'path': path},
    );
    return result == null
        ? const ApkCompatibilityInfo(
            compatible: false,
            issues: ['Android could not inspect the downloaded APK.'],
          )
        : ApkCompatibilityInfo.fromMap(result);
  }

  Future<String?> voiceSearch() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;
    final result = await _channel.invokeMethod<String>('voiceSearch');
    final query = result?.trim() ?? '';
    return query.isEmpty ? null : query;
  }

  /// Opens Android's permission-scoped document picker for one video.
  ///
  /// The returned content URI may refer to internal storage or a mounted USB
  /// provider. Android owns the picker and grants only read access to the
  /// selected document, so no broad storage permission is required.
  Future<LocalMediaDocument?> pickLocalVideo() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      throw PlatformException(
        code: 'LOCAL_MEDIA_UNSUPPORTED',
        message: 'Local media is only available on Android devices.',
      );
    }
    final value = await _channel.invokeMapMethod<Object?, Object?>(
      'pickLocalVideo',
    );
    return value == null ? null : LocalMediaDocument.fromMap(value);
  }

  /// Opens a validated provider trailer in TetoTV's private native player.
  Future<bool> playInAppTrailer({
    required String provider,
    required String videoId,
    required String title,
  }) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      throw PlatformException(
        code: 'TRAILER_UNSUPPORTED',
        message: 'In-app trailers are only available on Android devices.',
      );
    }
    if (provider.trim().isEmpty || videoId.trim().isEmpty) {
      throw ArgumentError('A validated trailer provider and ID are required.');
    }
    return await _channel.invokeMethod<bool>('playInAppTrailer', {
          'provider': provider,
          'videoId': videoId,
          'title': title,
        }) ??
        false;
  }

  /// Hands one already-resolved video to an installed Android player.
  ///
  /// Authentication headers are intentionally not accepted here. Passing a
  /// private-server credential through an Android intent would disclose it to
  /// another application. Callers must therefore expose this action only for
  /// public HTTP(S), granted content URIs, or TetoTV's private offline files.
  Future<bool> openExternalPlayer({
    Uri? uri,
    String? localPath,
    String? mediaContentType,
    String? packageName,
  }) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      throw PlatformException(
        code: 'EXTERNAL_PLAYER_UNSUPPORTED',
        message: 'External players are only available on Android devices.',
      );
    }
    if (uri == null && (localPath == null || localPath.trim().isEmpty)) {
      throw ArgumentError('A media URI or local offline path is required.');
    }
    return await _channel.invokeMethod<bool>('openExternalPlayer', {
          if (uri != null) 'uri': uri.toString(),
          'localPath': ?localPath,
          'mimeType': ?mediaContentType,
          'packageName': ?packageName,
        }) ??
        false;
  }

  /// Opens one validated public HTTPS page in the user's Android browser.
  ///
  /// This deliberately accepts no headers, cookies, or credentials. Phone
  /// setup places its short-lived code and public-key fingerprint in the URI
  /// fragment, which Android's browser intent does not send to the web server.
  Future<bool> openExternalWebPage(Uri uri) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return false;
    }
    if (uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery) {
      throw ArgumentError.value(uri, 'uri', 'A public HTTPS page is required.');
    }
    return await _channel.invokeMethod<bool>('openExternalWebPage', {
          'uri': uri.toString(),
        }) ??
        false;
  }

  /// Generates an exportable, ephemeral P-256 key pair with canonical
  /// unsigned 32-byte components.
  ///
  /// The phone-setup session persists the scalar only in Flutter secure
  /// storage so setup can resume after the app is backgrounded or restarted.
  Future<AndroidP256KeyPair> generatePhoneSetupP256KeyPair() async {
    _requireAndroidPhoneSetupCrypto();
    final value = await _channel.invokeMapMethod<Object?, Object?>(
      'generatePhoneSetupP256KeyPair',
    );
    if (value == null) {
      throw PlatformException(
        code: 'PHONE_SETUP_CRYPTO_OUTPUT',
        message: 'Android did not return P-256 key material.',
      );
    }
    return AndroidP256KeyPair(
      privateD: _fixedP256Bytes(value['d'], 'private scalar'),
      publicX: _fixedP256Bytes(value['x'], 'public X coordinate'),
      publicY: _fixedP256Bytes(value['y'], 'public Y coordinate'),
    );
  }

  /// Derives one fixed-width P-256 ECDH secret after Android validates both
  /// the restored local point and the untrusted browser point.
  Future<Uint8List> derivePhoneSetupP256SharedSecret({
    required List<int> privateD,
    required List<int> localX,
    required List<int> localY,
    required List<int> remoteX,
    required List<int> remoteY,
  }) async {
    _requireAndroidPhoneSetupCrypto();
    final arguments = <String, Uint8List>{
      'privateD': _inputP256Bytes(privateD, 'private scalar'),
      'localX': _inputP256Bytes(localX, 'local X coordinate'),
      'localY': _inputP256Bytes(localY, 'local Y coordinate'),
      'remoteX': _inputP256Bytes(remoteX, 'remote X coordinate'),
      'remoteY': _inputP256Bytes(remoteY, 'remote Y coordinate'),
    };
    final value = await _channel.invokeMethod<Uint8List>(
      'derivePhoneSetupP256SharedSecret',
      arguments,
    );
    return _fixedP256Bytes(value, 'shared secret');
  }

  void _requireAndroidPhoneSetupCrypto() {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      throw PlatformException(
        code: 'PHONE_SETUP_CRYPTO_UNSUPPORTED',
        message: 'Secure phone setup is only available on Android.',
      );
    }
  }

  Uint8List _inputP256Bytes(List<int> value, String label) {
    if (value.length != 32 || value.any((byte) => byte < 0 || byte > 0xff)) {
      throw ArgumentError.value(value, label, 'Expected exactly 32 bytes.');
    }
    return Uint8List.fromList(value);
  }

  Uint8List _fixedP256Bytes(Object? value, String label) {
    if (value is! Uint8List || value.length != 32) {
      throw PlatformException(
        code: 'PHONE_SETUP_CRYPTO_OUTPUT',
        message: 'Android returned an invalid P-256 $label.',
      );
    }
    return Uint8List.fromList(value);
  }

  /// Returns installed apps that advertise support for Android video intents.
  /// Only a display label and Android package name cross the platform channel.
  Future<List<ExternalVideoPlayerApp>> installedExternalVideoPlayers() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return const [];
    }
    final values = await _channel.invokeListMethod<Object?>(
      'listExternalPlayers',
    );
    return (values ?? const <Object?>[])
        .whereType<Map<Object?, Object?>>()
        .map(ExternalVideoPlayerApp.fromMap)
        .where(
          (app) =>
              app.packageName.trim().isNotEmpty && app.label.trim().isNotEmpty,
        )
        .toList(growable: false);
  }

  /// Starts or joins Android's privacy-safe foreground keep-alive used while
  /// TetoTV is actively saving media for offline playback.
  ///
  /// The lease ID is process-local bookkeeping only. Titles, file names,
  /// providers, URLs, and account details never cross this channel.
  Future<bool> acquireOfflineDownloadKeepAlive(String leaseId) async {
    final normalized = leaseId.trim();
    if (normalized.isEmpty || normalized.length > 96) {
      throw ArgumentError.value(leaseId, 'leaseId');
    }
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return false;
    try {
      return await _channel.invokeMethod<bool>(
            'acquireOfflineDownloadKeepAlive',
            {'leaseId': normalized},
          ) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<void> releaseOfflineDownloadKeepAlive(String leaseId) async {
    final normalized = leaseId.trim();
    if (normalized.isEmpty || normalized.length > 96) return;
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _channel.invokeMethod<void>('releaseOfflineDownloadKeepAlive', {
        'leaseId': normalized,
      });
    } on PlatformException {
      // Best effort: the non-sticky service also ends with the app process.
    } on MissingPluginException {
      // Desktop/widget hosts intentionally do not install the Android bridge.
    }
  }

  Future<DirectTorrentCapability> getDirectTorrentCapability() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return const DirectTorrentCapability.unsupported();
    }
    try {
      final value = await _channel.invokeMapMethod<Object?, Object?>(
        'getDirectTorrentCapability',
      );
      return value == null
          ? const DirectTorrentCapability.unsupported()
          : DirectTorrentCapability.fromMap(value);
    } on PlatformException {
      return const DirectTorrentCapability.unsupported();
    } on MissingPluginException {
      return const DirectTorrentCapability.unsupported();
    }
  }

  Future<DirectTorrentNativeSession> startDirectTorrent({
    required String requestId,
    required String magnet,
    required int episode,
    int? season,
    int? preferredFileIndex,
  }) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      throw PlatformException(
        code: 'DIRECT_TORRENT_UNSUPPORTED',
        message: 'Direct torrent playback is only available on Android.',
      );
    }
    final value = await _channel
        .invokeMapMethod<Object?, Object?>('startDirectTorrent', {
          'requestId': requestId,
          'magnet': magnet,
          'episode': episode,
          'season': ?season,
          'preferredFileIndex': ?preferredFileIndex,
        });
    if (value == null) {
      throw PlatformException(
        code: 'DIRECT_TORRENT_EMPTY',
        message: 'Android did not return a direct torrent session.',
      );
    }
    return DirectTorrentNativeSession.fromMap(value);
  }

  Future<bool> cancelDirectTorrentStart(String requestId) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return false;
    try {
      return await _channel.invokeMethod<bool>('cancelDirectTorrentStart', {
            'requestId': requestId,
          }) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<bool> stopDirectTorrent(String sessionId) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return false;
    try {
      return await _channel.invokeMethod<bool>('stopDirectTorrent', {
            'sessionId': sessionId,
          }) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Removes only disposable application cache and downloaded update files.
  /// Accounts, preferences, sources, history, databases, and secure storage
  /// live outside Android's cache directories and are intentionally retained.
  Future<int> clearAppCache() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      throw PlatformException(
        code: 'APP_STORAGE_UNSUPPORTED',
        message: 'Storage cleanup is only supported on Android.',
      );
    }
    return await _channel.invokeMethod<int>('clearAppCache') ?? 0;
  }

  /// Requests Android to erase this application's complete private data.
  /// A successful request terminates the process, so callers should not expect
  /// the returned Future to complete on a physical device.
  Future<void> resetApplicationData() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      throw PlatformException(
        code: 'APP_STORAGE_UNSUPPORTED',
        message: 'Reset is only supported on Android.',
      );
    }
    final accepted =
        await _channel.invokeMethod<bool>('resetApplicationData') ?? false;
    if (!accepted) {
      throw PlatformException(
        code: 'APP_RESET_REJECTED',
        message: 'Android could not start the application reset.',
      );
    }
  }

  Future<void> setAnonymousCrashReportingEnabled(bool enabled) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    await _channel.invokeMethod<void>('setAnonymousCrashReportingEnabled', {
      'enabled': enabled,
    });
  }

  Future<bool> storePendingAnonymousCrashReport(
    Map<String, Object?> report,
  ) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return false;
    return await _channel.invokeMethod<bool>(
          'storePendingAnonymousCrashReport',
          report,
        ) ??
        false;
  }

  Future<Map<String, Object?>?> getPendingAnonymousCrashReport() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;
    final value = await _channel.invokeMapMethod<Object?, Object?>(
      'getPendingAnonymousCrashReport',
    );
    return value?.map((key, value) => MapEntry(key.toString(), value));
  }

  /// Returns only the bounded, redacted crash summaries retained locally for
  /// an explicit diagnostic export. This does not enable or send anonymous
  /// crash reports.
  Future<LocalCrashSummaryHistory> getRecentLocalCrashSummaries() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return const LocalCrashSummaryHistory.empty();
    }
    final value = await _channel.invokeMapMethod<Object?, Object?>(
      'getRecentLocalCrashSummaries',
    );
    return value == null
        ? const LocalCrashSummaryHistory.empty()
        : LocalCrashSummaryHistory.fromMap(value);
  }

  Future<void> acknowledgeAnonymousCrashReport(String reportId) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    await _channel.invokeMethod<void>('acknowledgeAnonymousCrashReport', {
      'reportId': reportId,
    });
  }

  Future<void> clearPendingAnonymousCrashReports() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    await _channel.invokeMethod<void>('clearPendingAnonymousCrashReports');
  }

  Future<void> setPreferredFrameRate(double fps) async {
    if (fps <= 0 || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _channel.invokeMethod<int>('setPreferredFrameRate', {'fps': fps});
    } on PlatformException {
      // Mode switching is optional and unsupported by some Fire OS builds.
    }
  }

  Future<void> clearPreferredFrameRate() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _channel.invokeMethod<void>('clearPreferredFrameRate');
    } on PlatformException {
      // Best effort only.
    }
  }

  Future<void> updateMediaSession({
    required String title,
    required int episode,
    required Duration position,
    required Duration duration,
    required bool playing,
    String? artworkUrl,
    int seekBackSeconds = 10,
    int seekForwardSeconds = 10,
    double playbackRate = 1,
  }) async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _channel.invokeMethod<void>('updateMediaSession', {
        'title': title,
        'subtitle': 'Episode $episode',
        'episode': episode,
        'positionMs': position.inMilliseconds,
        'durationMs': duration.inMilliseconds,
        'playing': playing,
        if (artworkUrl != null && artworkUrl.isNotEmpty)
          'artworkUrl': artworkUrl,
        'seekBackMs': seekBackSeconds * 1000,
        'seekForwardMs': seekForwardSeconds * 1000,
        'playbackRate': playbackRate.clamp(.5, 2).toDouble(),
      });
    } on PlatformException {
      // Playback must continue even when a vendor MediaSession is unavailable.
    }
  }

  Future<void> clearMediaSession() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _channel.invokeMethod<void>('clearMediaSession');
    } on PlatformException {
      // System media controls are optional on some vendor TV builds.
    }
  }

  Future<void> removeWatchNext(int mediaId) async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _channel.invokeMethod<void>('removeWatchNext', {
        'mediaId': mediaId,
      });
    } on PlatformException {
      // Watch Next is optional and absent on Fire TV and some operator boxes.
    }
  }

  Future<void> publishWatchNext({
    required int mediaId,
    required int episode,
    required String title,
    required Duration position,
    required Duration duration,
    String? posterUrl,
  }) async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _channel.invokeMethod<int>('publishWatchNext', {
        'mediaId': mediaId,
        'episode': episode,
        'title': title,
        'description': 'Continue episode $episode on TetoTV',
        'posterUrl': posterUrl,
        'positionMs': position.inMilliseconds,
        'durationMs': duration.inMilliseconds,
      });
    } on PlatformException {
      // Fire TV and some operator devices do not expose the Watch Next provider.
    }
  }

  Future<bool> scheduleReminder({
    required int mediaId,
    required int episode,
    required String title,
    required DateTime airingAt,
  }) async {
    if (defaultTargetPlatform != TargetPlatform.android) return false;
    final reminderAt = airingAt.subtract(const Duration(minutes: 10));
    if (reminderAt.isBefore(DateTime.now())) return false;
    try {
      return await _channel.invokeMethod<bool>('scheduleReminder', {
            'mediaId': mediaId,
            'episode': episode,
            'title': title,
            'atMillis': reminderAt.millisecondsSinceEpoch,
          }) ??
          false;
    } on PlatformException {
      return false;
    }
  }

  /// Replaces TetoTV's automatically managed episode-release alarms.
  ///
  /// Manual ten-minute reminders use a separate PendingIntent identity and
  /// are deliberately left untouched. Passing an empty list cancels only the
  /// automatically managed release notifications.
  Future<int> syncEpisodeReleaseNotifications(
    Iterable<EpisodeReleaseNotification> notifications,
  ) async {
    if (defaultTargetPlatform != TargetPlatform.android) return 0;
    final safe = notifications
        .where(
          (item) =>
              item.mediaId > 0 &&
              item.episode > 0 &&
              item.title.trim().isNotEmpty,
        )
        .take(150)
        .map((item) => item.toPlatformMap())
        .toList(growable: false);
    try {
      return await _channel.invokeMethod<int>(
            'syncEpisodeReleaseNotifications',
            {'notifications': safe},
          ) ??
          0;
    } on PlatformException {
      return 0;
    }
  }
}
