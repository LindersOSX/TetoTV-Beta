import 'dart:io';

import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:anime_tv/features/auth/application/pairing_controller.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

const _legacyGithubUpdateTokenStorageKey = 'github_update_token';
const _legacyBetaUpdateAccessKeyStorageKey = 'beta_update_access_key';
const automaticUpdatesStorageKey = 'automatic_app_updates';
const lastAutomaticUpdateCheckStorageKey = 'last_automatic_update_check';
const pendingReleaseNotesVersionStorageKey = 'pending_release_notes_version';
const pendingReleaseNotesStorageKey = 'pending_release_notes';
const updateChannelStorageKey = 'app_update_channel';
const developerModeStorageKey = 'settings_developer_mode';
const tetoTvPublicReleaseRepository = 'LindersOSX/TetoTV-Public';
const tetoTvBetaReleaseRepository = 'LindersOSX/TetoTV-Beta';
const maxPublicReleaseAssetBytes = 300 * 1024 * 1024;
const maxUpdateReleaseHistory = 20;
const maxAndroidVersionCode = 2100000000;

// Public releases restarted at 1.0.0 with a higher Android versionCode. The
// pre-Public builds reached a larger user-facing SemVer (for example,
// 1.11.33), so SemVer alone incorrectly treats the first Public APK as a
// downgrade. Keep this boundary fixed: it is a one-way migration marker, not
// a general license to install older APKs.
const firstPublicReleaseVersionCode = 410001;

final appUpdateControllerProvider =
    StateNotifierProvider<AppUpdateController, AppUpdateState>((ref) {
      final bridge = AndroidTvBridge.instance;
      final storage = ref.watch(secureStorageProvider);
      final github = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 30),
          sendTimeout: const Duration(seconds: 15),
        ),
      );
      final controller = AppUpdateController(
        storage,
        GitHubAppReleaseSource(
          github,
          repository: tetoTvPublicReleaseRepository,
          releaseMajor: 1,
          channelName: 'Public',
        ),
        () async {
          final version = await bridge.getAppVersion();
          if (version.code <= 0 || version.name.contains('+')) {
            return version.name;
          }
          return '${version.name}+${version.code}';
        },
        () async => (await bridge.getDeviceProfile()).abis,
        getTemporaryDirectory,
        bridge.installApk,
        betaReleaseSource: GitHubAppReleaseSource(
          github,
          repository: tetoTvBetaReleaseRepository,
          releaseMajor: 2,
          channelName: 'Beta',
          allowPrerelease: true,
        ),
        apkInspector: bridge.inspectApk,
      );
      Future.microtask(controller.load);
      return controller;
    });

/// Whether the currently installed APK belongs to the signed 2.x Beta family.
/// This deliberately ignores the selected update channel: selecting Beta from
/// a Public APK must not activate Beta-only runtime behavior before install.
final isInstalledBetaBuildProvider = Provider<bool>(
  (ref) => installedBetaRuntimeFeaturesEnabled(
    ref.watch(appUpdateControllerProvider).currentVersion,
    isDebugBuild: kDebugMode,
  ),
);

bool installedBetaRuntimeFeaturesEnabled(
  String version, {
  required bool isDebugBuild,
}) =>
    !isDebugBuild &&
    appVersionMajor(version) == AppUpdateChannel.beta.releaseMajor;

enum AppUpdatePhase {
  idle,
  checking,
  upToDate,
  available,
  downloading,
  ready,
  installing,
  error,
}

class AppUpdateState {
  const AppUpdateState({
    this.phase = AppUpdatePhase.idle,
    this.currentVersion = '…',
    this.latestVersion,
    this.release,
    this.downloadedPath,
    this.message,
    this.progress = 0,
    this.automaticUpdates = true,
    this.updateChannel = AppUpdateChannel.public,
    this.developerMode = false,
    this.releaseHistory = const [],
    this.releaseHistoryLoading = false,
  });

  final AppUpdatePhase phase;
  final String currentVersion;
  final String? latestVersion;
  final AppReleaseInfo? release;
  final String? downloadedPath;
  final String? message;
  final double progress;
  final bool automaticUpdates;
  final AppUpdateChannel updateChannel;
  final bool developerMode;
  final List<AppReleaseInfo> releaseHistory;
  final bool releaseHistoryLoading;

  bool get isBusy =>
      phase == AppUpdatePhase.checking ||
      phase == AppUpdatePhase.downloading ||
      phase == AppUpdatePhase.installing;

  AppUpdateState copyWith({
    AppUpdatePhase? phase,
    String? currentVersion,
    Object? latestVersion = _notProvided,
    Object? release = _notProvided,
    Object? downloadedPath = _notProvided,
    Object? message = _notProvided,
    double? progress,
    bool? automaticUpdates,
    AppUpdateChannel? updateChannel,
    bool? developerMode,
    List<AppReleaseInfo>? releaseHistory,
    bool? releaseHistoryLoading,
  }) {
    return AppUpdateState(
      phase: phase ?? this.phase,
      currentVersion: currentVersion ?? this.currentVersion,
      latestVersion: identical(latestVersion, _notProvided)
          ? this.latestVersion
          : latestVersion as String?,
      release: identical(release, _notProvided)
          ? this.release
          : release as AppReleaseInfo?,
      downloadedPath: identical(downloadedPath, _notProvided)
          ? this.downloadedPath
          : downloadedPath as String?,
      message: identical(message, _notProvided)
          ? this.message
          : message as String?,
      progress: progress ?? this.progress,
      automaticUpdates: automaticUpdates ?? this.automaticUpdates,
      updateChannel: updateChannel ?? this.updateChannel,
      developerMode: developerMode ?? this.developerMode,
      releaseHistory: releaseHistory ?? this.releaseHistory,
      releaseHistoryLoading:
          releaseHistoryLoading ?? this.releaseHistoryLoading,
    );
  }
}

enum AppUpdateChannel { public, beta }

extension AppUpdateChannelLabel on AppUpdateChannel {
  String get displayName => switch (this) {
    AppUpdateChannel.public => 'Public',
    AppUpdateChannel.beta => 'Beta',
  };

  String get description => switch (this) {
    AppUpdateChannel.public => 'Stable releases from the public release page',
    AppUpdateChannel.beta => '2.x preview builds from the Beta release page',
  };

  String versionLabel(String version) =>
      this == AppUpdateChannel.beta ? '$version Beta' : version;

  int get releaseMajor => switch (this) {
    AppUpdateChannel.public => 1,
    AppUpdateChannel.beta => 2,
  };
}

/// Restores an explicit channel choice, otherwise follows the family of the
/// installed APK. This matters for a newly installed Beta APK: secure storage
/// is empty on first launch, but checking Public would offer the lower-code
/// Public build and only fail after downloading it.
AppUpdateChannel resolveAppUpdateChannel({
  required String? storedValue,
  required String installedVersion,
}) {
  for (final channel in AppUpdateChannel.values) {
    if (storedValue == channel.name) return channel;
  }
  final installedMajor = appVersionMajor(installedVersion);
  for (final channel in AppUpdateChannel.values) {
    if (installedMajor == channel.releaseMajor) return channel;
  }
  return AppUpdateChannel.public;
}

const _notProvided = Object();

class AppReleaseAsset {
  const AppReleaseAsset({
    required this.name,
    required this.apiUrl,
    required this.publicUrl,
    required this.size,
    this.sha256Digest,
  });

  final String name;
  final String apiUrl;
  final String publicUrl;
  final int size;
  final String? sha256Digest;
}

class AppReleaseInfo {
  const AppReleaseInfo({
    required this.tagName,
    required this.version,
    required this.name,
    required this.asset,
    this.notes = '',
    this.releasedAtUtc,
    this.androidVersionCode,
  });

  final String tagName;
  final String version;
  final String name;
  final AppReleaseAsset asset;
  final String notes;

  /// Android's monotonic package build number when the release publishes it.
  ///
  /// This is optional for older GitHub releases. The downloaded APK remains
  /// the final authority and is always inspected before Android's installer is
  /// opened.
  final int? androidVersionCode;

  /// The date GitHub published this release, normalized to UTC.
  ///
  /// Older or malformed API payloads can omit a trustworthy date, so this is
  /// nullable instead of substituting an epoch that would mislead the user.
  final DateTime? releasedAtUtc;
}

abstract class AppReleaseSource {
  Future<AppReleaseInfo> latest({required List<String> deviceAbis});

  Future<List<AppReleaseInfo>> history({
    required List<String> deviceAbis,
  }) async => [await latest(deviceAbis: deviceAbis)];

  Future<void> download({
    required AppReleaseInfo release,
    required String destination,
    required void Function(int received, int total) onProgress,
  });
}

class GitHubAppReleaseSource implements AppReleaseSource {
  GitHubAppReleaseSource(
    this._dio, {
    this.repository = tetoTvPublicReleaseRepository,
    this.releaseMajor = 1,
    this.channelName = 'Public',
    this.allowPrerelease = false,
  });

  final Dio _dio;
  final String repository;
  final int releaseMajor;
  final String channelName;
  final bool allowPrerelease;

  @override
  Future<AppReleaseInfo> latest({required List<String> deviceAbis}) async {
    final response = await _latestResponse();
    final data = response.data;
    if (data == null) throw StateError('GitHub returned an empty release.');
    return _parseCompletedRelease(data, deviceAbis);
  }

  @override
  Future<List<AppReleaseInfo>> history({
    required List<String> deviceAbis,
  }) async {
    final response = await _dio.get<List<dynamic>>(
      'https://api.github.com/repos/$repository/releases',
      queryParameters: const {'per_page': maxUpdateReleaseHistory},
      options: Options(headers: _headers('application/vnd.github+json')),
    );
    final data = response.data;
    if (data == null || data.length > maxUpdateReleaseHistory) {
      throw FormatException('GitHub returned invalid release history.');
    }
    final releases = <AppReleaseInfo>[];
    for (final raw in data.whereType<Map>()) {
      final item = raw.cast<String, dynamic>();
      if (item['draft'] == true ||
          (!allowPrerelease && item['prerelease'] == true)) {
        continue;
      }
      final tag = _optionalString(item['tag_name']);
      if (tag == null || appVersionMajor(tag) != releaseMajor) continue;
      releases.add(_parseCompletedRelease(item, deviceAbis));
    }
    _validateReleaseHistoryOrder(releases);
    return releases;
  }

  AppReleaseInfo _parseCompletedRelease(
    Map<String, dynamic> data,
    List<String> deviceAbis,
  ) {
    if (data['draft'] == true ||
        (!allowPrerelease && data['prerelease'] == true)) {
      throw FormatException('$channelName update is not a completed release.');
    }
    final tag = _requiredString(data['tag_name'], 'release tag');
    if (!RegExp(r'^v\d+\.\d+\.\d+$').hasMatch(tag) ||
        appVersionMajor(tag) != releaseMajor) {
      throw FormatException('$channelName update has an invalid release tag.');
    }
    final expectedAssetName = 'TetoTV-$tag-universal.apk';
    final candidates = (data['assets'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => item.cast<String, dynamic>())
        .where((item) => _isSafeApkName(item['name']))
        .toList(growable: false);
    final exact = candidates
        .where((item) => item['name'] == expectedAssetName)
        .toList(growable: false);
    if (exact.length > 1) {
      throw FormatException(
        'The latest $channelName release has duplicate canonical APKs.',
      );
    }
    final universal = candidates
        .where((item) => _isUniversalApkName(item['name']))
        .toList(growable: false);
    if (exact.isEmpty && universal.length > 1) {
      throw FormatException(
        'The latest $channelName release has ambiguous universal APKs.',
      );
    }
    final selected = exact.isNotEmpty
        ? exact
        : universal.isNotEmpty
        ? universal
        : candidates;
    final assets = selected
        .map((item) {
          final assetName = item['name'] as String? ?? '';
          final contentType = (item['content_type'] as String? ?? '')
              .toLowerCase();
          if (contentType != 'application/vnd.android.package-archive' &&
              contentType != 'application/octet-stream') {
            throw FormatException(
              '$channelName update returned an invalid APK content type.',
            );
          }
          return AppReleaseAsset(
            name: assetName,
            apiUrl: item['url'] as String? ?? '',
            publicUrl: _trustedReleaseAssetUri(
              item['browser_download_url'] as String? ?? '',
              tag,
              assetName,
            ).toString(),
            size: (item['size'] as num?)?.toInt() ?? 0,
            sha256Digest: _parseSha256Digest(item['digest']),
          );
        })
        .where(
          (asset) =>
              asset.name.isNotEmpty &&
              asset.apiUrl.isNotEmpty &&
              asset.publicUrl.isNotEmpty &&
              asset.size >= 1024 * 1024 &&
              asset.size <= maxPublicReleaseAssetBytes,
        )
        .toList(growable: false);
    if (assets.isEmpty) {
      throw StateError(
        'The latest $channelName release has no compatible signed APK attached.',
      );
    }
    if (universal.isNotEmpty && assets.length != 1) {
      throw FormatException(
        'The latest $channelName release has ambiguous universal APKs.',
      );
    }
    if (universal.isEmpty && !_hasUnambiguousAbiFallback(assets, deviceAbis)) {
      throw FormatException(
        'The latest $channelName release has ambiguous device APKs.',
      );
    }
    final asset = selectApkAsset(assets, deviceAbis);
    final notes = data['body'] as String? ?? '';
    return AppReleaseInfo(
      tagName: tag,
      version: normalizeAppVersion(tag),
      name: data['name'] as String? ?? tag,
      asset: asset,
      notes: notes,
      releasedAtUtc: _parseGitHubReleaseDate(data),
      androidVersionCode: _parseAndroidVersionCodeMetadata(notes),
    );
  }

  @override
  Future<void> download({
    required AppReleaseInfo release,
    required String destination,
    required void Function(int received, int total) onProgress,
  }) => _download(
    url: _trustedReleaseAssetUri(
      release.asset.publicUrl,
      release.tagName,
      release.asset.name,
    ).toString(),
    destination: destination,
    onProgress: onProgress,
  );

  Future<Response<Map<String, dynamic>>> _latestResponse() =>
      _dio.get<Map<String, dynamic>>(
        'https://api.github.com/repos/$repository/releases/latest',
        options: Options(headers: _headers('application/vnd.github+json')),
      );

  Uri _trustedReleaseAssetUri(String value, String tag, String assetName) {
    final repositoryParts = repository.split('/');
    if (repositoryParts.length != 2 ||
        repositoryParts.any(
          (part) => !RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(part),
        )) {
      throw FormatException('$channelName update repository is invalid.');
    }
    if (!_isSafeApkName(assetName) ||
        !RegExp(r'^v\d+\.\d+\.\d+$').hasMatch(tag) ||
        appVersionMajor(tag) != releaseMajor) {
      throw FormatException('$channelName update asset identity is invalid.');
    }
    final uri = Uri.tryParse(value);
    final expectedPath =
        '/${repositoryParts[0]}/${repositoryParts[1]}/releases/download/'
        '$tag/$assetName';
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host != 'github.com' ||
        uri.port != 443 ||
        uri.userInfo.isNotEmpty ||
        uri.path != expectedPath ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw FormatException(
        '$channelName update returned an untrusted APK download URL.',
      );
    }
    return uri;
  }

  bool _isUniversalApkName(Object? value) {
    return value is String &&
        _isSafeApkName(value) &&
        value.toLowerCase().endsWith('-universal.apk');
  }

  bool _isSafeApkName(Object? value) {
    return value is String &&
        value.length <= 160 &&
        path.basename(value) == value &&
        RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(value) &&
        value.toLowerCase().endsWith('.apk');
  }

  bool _hasUnambiguousAbiFallback(
    List<AppReleaseAsset> assets,
    List<String> deviceAbis,
  ) {
    if (assets.length == 1) return true;
    final normalizedAbis = deviceAbis.map((abi) => abi.toLowerCase());
    final markers = normalizedAbis.any((abi) => abi.contains('arm64'))
        ? const ['arm64-v8a', 'arm64']
        : normalizedAbis.any((abi) => abi.contains('armeabi'))
        ? const ['armeabi-v7a', 'fire-tv-32bit', 'arm32']
        : normalizedAbis.any((abi) => abi.contains('x86_64'))
        ? const ['x86_64']
        : const <String>[];
    if (markers.isEmpty) return false;
    return assets
            .where(
              (asset) => markers.any(
                (marker) => asset.name.toLowerCase().contains(marker),
              ),
            )
            .length ==
        1;
  }

  Future<void> _download({
    required String url,
    required String destination,
    required void Function(int received, int total) onProgress,
  }) async {
    var currentUri = Uri.parse(url);
    try {
      for (var redirectCount = 0; redirectCount <= 3; redirectCount++) {
        final response = await _dio.download(
          currentUri.toString(),
          destination,
          options: Options(
            headers: _headers('application/octet-stream'),
            followRedirects: false,
            maxRedirects: 0,
            validateStatus: (status) =>
                status == HttpStatus.ok || _isRedirectStatus(status),
            receiveTimeout: const Duration(minutes: 20),
          ),
          onReceiveProgress: onProgress,
          deleteOnError: true,
        );
        if (response.statusCode == HttpStatus.ok) return;
        if (redirectCount >= 3) {
          throw FormatException(
            '$channelName update download redirected too many times.',
          );
        }
        currentUri = _trustedGitHubAssetRedirectUri(
          response.headers.value(HttpHeaders.locationHeader),
        );
      }
      throw FormatException(
        '$channelName update download did not return an APK.',
      );
    } catch (_) {
      await _deleteUpdateFile(File(destination));
      rethrow;
    }
  }

  static bool _isRedirectStatus(int? status) =>
      status == HttpStatus.movedPermanently ||
      status == HttpStatus.found ||
      status == HttpStatus.seeOther ||
      status == HttpStatus.temporaryRedirect ||
      status == HttpStatus.permanentRedirect;

  Uri _trustedGitHubAssetRedirectUri(String? value) {
    final uri = value == null ? null : Uri.tryParse(value.trim());
    const trustedHosts = {
      'objects.githubusercontent.com',
      'release-assets.githubusercontent.com',
    };
    if (uri == null ||
        !uri.isAbsolute ||
        uri.scheme != 'https' ||
        !trustedHosts.contains(uri.host.toLowerCase()) ||
        uri.port != 443 ||
        uri.userInfo.isNotEmpty ||
        uri.path.isEmpty ||
        uri.hasFragment) {
      throw FormatException(
        '$channelName update returned an untrusted download redirect.',
      );
    }
    return uri;
  }

  static Map<String, String> _headers(String accept) => {
    'Accept': accept,
    'X-GitHub-Api-Version': '2022-11-28',
    'User-Agent': 'TetoTV-AndroidTV-Updater',
  };
}

String _requiredString(Object? value, String field) {
  final result = _optionalString(value);
  if (result == null) throw FormatException('Missing update $field.');
  return result;
}

String? _optionalString(Object? value) {
  if (value is! String) return null;
  final result = value.trim();
  return result.isEmpty ? null : result;
}

DateTime? _parseGitHubReleaseDate(Map<String, dynamic> data) {
  for (final field in const ['published_at', 'created_at']) {
    final raw = _optionalString(data[field]);
    if (raw == null) continue;
    final parsed = DateTime.tryParse(raw);
    if (parsed != null) return parsed.toUtc();
  }
  return null;
}

int? _parseAndroidVersionCodeMetadata(String notes) {
  final values = <int>{};
  final patterns = [
    RegExp(
      r'<!--\s*tetotv-android-version-code\s*:\s*([0-9]+)\s*-->',
      caseSensitive: false,
    ),
    RegExp(r'\bAndroid build code\s+`([0-9]+)`', caseSensitive: false),
  ];
  for (final pattern in patterns) {
    for (final match in pattern.allMatches(notes)) {
      final value = int.tryParse(match.group(1) ?? '');
      if (value == null || value <= 0 || value > maxAndroidVersionCode) {
        throw const FormatException(
          'The update service returned an invalid Android build code.',
        );
      }
      values.add(value);
    }
  }
  if (values.length > 1) {
    throw const FormatException(
      'The update service returned conflicting Android build codes.',
    );
  }
  return values.isEmpty ? null : values.first;
}

/// Formats an updater release date without relying on the device locale data
/// bundle, which is not guaranteed to be installed on every Android TV.
String? formatAppReleaseDate(DateTime? releasedAtUtc) {
  if (releasedAtUtc == null) return null;
  final date = releasedAtUtc.toUtc();
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${months[date.month - 1]} ${date.day}, ${date.year}';
}

/// The version/date label shared by the latest-release and history UI.
String appReleaseDisplayLabel(
  AppReleaseInfo release,
  AppUpdateChannel channel,
) {
  final version = channel.versionLabel(release.version);
  final date = formatAppReleaseDate(release.releasedAtUtc);
  return date == null ? version : '$version • $date';
}

void _validateReleaseHistoryOrder(List<AppReleaseInfo> releases) {
  final tags = <String>{};
  for (var index = 0; index < releases.length; index++) {
    final release = releases[index];
    if (!tags.add(release.tagName) ||
        (index > 0 &&
            compareAppVersions(releases[index - 1].version, release.version) <=
                0)) {
      throw FormatException(
        'The update service returned unordered or duplicate release history.',
      );
    }
  }
}

String? _parseSha256Digest(Object? value) {
  if (value == null) return null;
  final raw = _requiredString(value, 'asset digest').toLowerCase();
  final match = RegExp(r'^sha256:([0-9a-f]{64})$').firstMatch(raw);
  if (match == null) {
    throw FormatException('The update service returned an invalid APK digest.');
  }
  return match.group(1);
}

AppReleaseAsset selectApkAsset(
  List<AppReleaseAsset> assets,
  List<String> deviceAbis,
) {
  // Prefer one cross-device artifact for in-app updates. Besides avoiding
  // inaccurate ABI reports on vendor TV firmware, this lets a device move
  // safely between an older split APK and the newer universal APK.
  for (final asset in assets) {
    if (asset.name.toLowerCase().endsWith('-universal.apk')) return asset;
  }
  final normalizedAbis = deviceAbis.map((abi) => abi.toLowerCase()).toList();
  final preferredMarker = normalizedAbis.any((abi) => abi.contains('arm64'))
      ? 'arm64-v8a'
      : normalizedAbis.any((abi) => abi.contains('armeabi'))
      ? 'armeabi-v7a'
      : normalizedAbis.any((abi) => abi.contains('x86_64'))
      ? 'x86_64'
      : null;
  if (preferredMarker != null) {
    for (final asset in assets) {
      if (asset.name.toLowerCase().contains(preferredMarker)) return asset;
    }
    final aliases = switch (preferredMarker) {
      'arm64-v8a' => const ['arm64'],
      'armeabi-v7a' => const ['fire-tv-32bit', 'arm32'],
      _ => const <String>[],
    };
    for (final alias in aliases) {
      for (final asset in assets) {
        if (asset.name.toLowerCase().contains(alias)) return asset;
      }
    }
  }
  return assets.first;
}

String normalizeAppVersion(String value) {
  final match = RegExp(
    r'\d+(?:\.\d+){0,3}(?:\+[0-9A-Za-z.-]+)?',
  ).firstMatch(value);
  return match?.group(0) ?? value.trim().replaceFirst(RegExp(r'^[vV]'), '');
}

int compareAppVersions(String left, String right) {
  ({List<int> core, List<int> build}) parts(String value) {
    final normalized = normalizeAppVersion(value);
    final split = normalized.split('+');
    final core = split.first
        .split('.')
        .map((item) => int.tryParse(item) ?? 0)
        .toList(growable: false);
    final build = split.length < 2
        ? const <int>[]
        : split[1]
              .split(RegExp(r'[^0-9]+'))
              .where((item) => item.isNotEmpty)
              .map((item) => int.tryParse(item) ?? 0)
              .toList(growable: false);
    return (core: core, build: build);
  }

  int compareParts(List<int> a, List<int> b) {
    final length = a.length > b.length ? a.length : b.length;
    for (var index = 0; index < length; index++) {
      final leftPart = index < a.length ? a[index] : 0;
      final rightPart = index < b.length ? b[index] : 0;
      if (leftPart != rightPart) return leftPart.compareTo(rightPart);
    }
    return 0;
  }

  final a = parts(left);
  final b = parts(right);
  final coreResult = compareParts(a.core, b.core);
  if (coreResult != 0) return coreResult;

  // TetoTV tags may append the Android versionCode as SemVer build metadata.
  // SemVer normally ignores this suffix for precedence, but the updater must
  // distinguish two APK builds that share the same user-facing version name.
  return compareParts(a.build, b.build);
}

int? appVersionMajor(String value) {
  final normalized = normalizeAppVersion(value);
  return int.tryParse(normalized.split('.').first);
}

int? appVersionCode(String value) {
  final normalized = normalizeAppVersion(value);
  final split = normalized.split('+');
  if (split.length != 2 || !RegExp(r'^[1-9][0-9]*$').hasMatch(split[1])) {
    return null;
  }
  return int.tryParse(split[1]);
}

bool isKnownAndroidVersionDowngrade({
  required String currentVersion,
  required int? releaseVersionCode,
}) {
  final installedVersionCode = appVersionCode(currentVersion);
  return installedVersionCode != null &&
      releaseVersionCode != null &&
      releaseVersionCode > 0 &&
      releaseVersionCode < installedVersionCode;
}

String androidVersionDowngradeMessage({
  required int installedVersionCode,
  required int releaseVersionCode,
}) =>
    'Android blocks in-place downgrades: target build $releaseVersionCode is '
    'lower than installed build $installedVersionCode. Developer mode cannot '
    'bypass this rule. Use a signed channel build $installedVersionCode or '
    'newer. Uninstalling first erases TetoTV\'s local data.';

/// Decides whether the selected channel's release should be offered.
///
/// Public and Beta are two installable variants of the same signed app. Their
/// user-facing versions deliberately live in different major families (1.x
/// and 2.x), while paired builds may share the same monotonically allocated
/// Android versionCode. Crossing families is therefore an explicit channel
/// switch, not a SemVer upgrade/downgrade. Once the installed family matches
/// the selected channel, normal numeric comparison resumes so automatic checks
/// cannot repeatedly offer the already-installed counterpart.
///
/// The one exception is a signed pre-Public 1.x build whose Android
/// versionCode predates [firstPublicReleaseVersionCode]. Public versioning was
/// reset from 1.11.x to 1.0.0 while the Android code increased, so those builds
/// must use the monotonic Android code as the migration boundary. Requiring an
/// explicit numeric build suffix prevents an unknown or malformed version from
/// being treated as a migration candidate.
bool shouldOfferAppRelease({
  required String currentVersion,
  required String releaseVersion,
  required AppUpdateChannel channel,
  int? releaseVersionCode,
}) {
  final releaseMajor = appVersionMajor(releaseVersion);
  if (releaseMajor != channel.releaseMajor) return false;
  if (isKnownAndroidVersionDowngrade(
    currentVersion: currentVersion,
    releaseVersionCode: releaseVersionCode,
  )) {
    return false;
  }
  final currentMajor = appVersionMajor(currentVersion);
  final isKnownOtherChannel =
      currentMajor != null &&
      currentMajor != channel.releaseMajor &&
      AppUpdateChannel.values.any(
        (candidate) => candidate.releaseMajor == currentMajor,
      );
  if (isKnownOtherChannel) return true;
  if (channel == AppUpdateChannel.public &&
      currentMajor == AppUpdateChannel.public.releaseMajor) {
    final currentCode = appVersionCode(currentVersion);
    if (currentCode != null && currentCode < firstPublicReleaseVersionCode) {
      return true;
    }
  }
  return compareAppVersions(releaseVersion, currentVersion) > 0;
}

typedef CurrentVersionLoader = Future<String> Function();
typedef DeviceAbisLoader = Future<List<String>> Function();
typedef CacheDirectoryLoader = Future<Directory> Function();
typedef ApkInstaller = Future<String> Function(String path);
typedef ApkInspector = Future<ApkCompatibilityInfo> Function(String path);

class AppUpdateController extends StateNotifier<AppUpdateState> {
  AppUpdateController(
    this._storage,
    this._releaseSource,
    this._currentVersionLoader,
    this._deviceAbisLoader,
    this._cacheDirectoryLoader,
    this._apkInstaller, {
    AppReleaseSource? betaReleaseSource,
    this.automaticCheckInterval = const Duration(hours: 12),
    this.apkInspector,
  }) : _betaReleaseSource = betaReleaseSource ?? _releaseSource,
       super(const AppUpdateState());

  final FlutterSecureStorage _storage;
  final AppReleaseSource _releaseSource;
  final AppReleaseSource _betaReleaseSource;
  final CurrentVersionLoader _currentVersionLoader;
  final DeviceAbisLoader _deviceAbisLoader;
  final CacheDirectoryLoader _cacheDirectoryLoader;
  final ApkInstaller _apkInstaller;
  final Duration automaticCheckInterval;
  final ApkInspector? apkInspector;

  bool _loaded = false;
  Future<void>? _loadRequest;

  Future<void> load() {
    if (_loaded) return Future.value();
    final active = _loadRequest;
    if (active != null) return active;
    final request = _performLoad();
    _loadRequest = request;
    return request.whenComplete(() {
      if (identical(_loadRequest, request)) _loadRequest = null;
    });
  }

  Future<void> _performLoad() async {
    final values = await Future.wait([
      _storage.read(key: _legacyGithubUpdateTokenStorageKey),
      _storage.read(key: automaticUpdatesStorageKey),
      _storage.read(key: updateChannelStorageKey),
      _storage.read(key: developerModeStorageKey),
      _currentVersionLoader(),
    ]);
    // Older builds could store update credentials on the device. GitHub update
    // checks are anonymous now, so both legacy secrets are removed on load.
    if (values[0] != null) {
      await _storage.delete(key: _legacyGithubUpdateTokenStorageKey);
    }
    await _storage.delete(key: _legacyBetaUpdateAccessKeyStorageKey);
    final developerMode = values[3] == 'true';
    // Beta access is a normal user preference. Developer mode only unlocks
    // release history so testers can deliberately move between older and
    // newer signed builds.
    final installedVersion = values[4] ?? 'unknown';
    final updateChannel = resolveAppUpdateChannel(
      storedValue: values[2],
      installedVersion: installedVersion,
    );
    _loaded = true;
    if (!mounted) return;
    state = state.copyWith(
      currentVersion: installedVersion,
      automaticUpdates: values[1] != 'false',
      developerMode: developerMode,
      updateChannel: updateChannel,
    );
  }

  Future<void> enableDeveloperMode() async {
    await setDeveloperMode(true);
  }

  Future<void> disableDeveloperMode() async {
    await setDeveloperMode(false);
  }

  Future<void> setDeveloperMode(bool enabled) async {
    await load();
    if (state.developerMode == enabled) return;
    if (enabled) {
      await _storage.write(key: developerModeStorageKey, value: 'true');
    } else {
      await _storage.delete(key: developerModeStorageKey);
    }
    state = state.copyWith(
      developerMode: enabled,
      releaseHistory: enabled ? state.releaseHistory : const [],
      releaseHistoryLoading: false,
      message: enabled
          ? 'Developer mode enabled. Release history is now available.'
          : 'Developer mode disabled. Standard update controls remain available.',
    );
  }

  Future<void> setUpdateChannel(AppUpdateChannel channel) async {
    await load();
    if (state.isBusy || state.updateChannel == channel) return;
    await _storage.write(key: updateChannelStorageKey, value: channel.name);
    state = state.copyWith(
      updateChannel: channel,
      phase: AppUpdatePhase.idle,
      latestVersion: null,
      release: null,
      releaseHistory: const [],
      releaseHistoryLoading: false,
      downloadedPath: null,
      progress: 0,
      message: '${channel.displayName} update channel selected.',
    );
    await _refreshReleaseHistory();
  }

  Future<void> refreshReleaseHistory() async {
    await load();
    await _refreshReleaseHistory();
  }

  Future<void> _refreshReleaseHistory() async {
    if (!mounted || !state.developerMode || state.releaseHistoryLoading) return;
    state = state.copyWith(releaseHistoryLoading: true);
    try {
      final releases = await _sourceFor(
        state.updateChannel,
      ).history(deviceAbis: await _deviceAbisLoader());
      if (!mounted) return;
      if (releases.any(
        (release) =>
            appVersionMajor(release.version) !=
            state.updateChannel.releaseMajor,
      )) {
        throw FormatException(
          'The ${state.updateChannel.displayName} update service returned a '
          'release from the wrong version family.',
        );
      }
      state = state.copyWith(
        releaseHistory: releases,
        releaseHistoryLoading: false,
        message: releases.isEmpty
            ? 'No completed ${state.updateChannel.displayName} releases are available.'
            : '${releases.length} completed ${state.updateChannel.displayName} '
                  '${releases.length == 1 ? 'release' : 'releases'} available.',
      );
    } catch (error) {
      if (!mounted) return;
      state = state.copyWith(
        releaseHistory: const [],
        releaseHistoryLoading: false,
        message: 'Could not load release history: ${_safeUpdateError(error)}',
      );
    }
  }

  Future<void> installReleaseFromHistory(AppReleaseInfo release) async {
    await load();
    if (!state.developerMode || state.isBusy) return;
    AppReleaseInfo? selected;
    for (final candidate in state.releaseHistory) {
      if (candidate.tagName == release.tagName &&
          candidate.version == release.version &&
          candidate.asset.publicUrl == release.asset.publicUrl) {
        selected = candidate;
        break;
      }
    }
    if (selected == null ||
        appVersionMajor(selected.version) != state.updateChannel.releaseMajor) {
      state = state.copyWith(
        phase: AppUpdatePhase.error,
        message:
            'That release is not part of the selected update channel. Refresh the list and try again.',
      );
      return;
    }
    final downgradeMessage = _knownDowngradeMessage(selected);
    if (downgradeMessage != null) {
      state = state.copyWith(
        phase: AppUpdatePhase.error,
        latestVersion: selected.version,
        release: selected,
        downloadedPath: null,
        progress: 0,
        message: downgradeMessage,
      );
      return;
    }
    final installedVersionName = normalizeAppVersion(
      state.currentVersion,
    ).split('+').first;
    final selectedVersionName = normalizeAppVersion(
      selected.version,
    ).split('+').first;
    if (selectedVersionName == installedVersionName) {
      state = state.copyWith(
        phase: AppUpdatePhase.upToDate,
        message:
            'TetoTV ${state.updateChannel.versionLabel(selected.version)} is already installed.',
      );
      return;
    }
    await downloadUpdate(
      release: selected,
      releaseSource: _sourceFor(state.updateChannel),
      launchInstaller: true,
    );
  }

  Future<void> setAutomaticUpdates(bool enabled) async {
    await load();
    await _storage.write(
      key: automaticUpdatesStorageKey,
      value: enabled.toString(),
    );
    state = state.copyWith(
      automaticUpdates: enabled,
      message: enabled
          ? 'Automatic update checks are on.'
          : 'Automatic update checks are off.',
    );
  }

  /// Returns release notes once, after Android has successfully installed the
  /// version they belong to. Merely downloading an APK never triggers them.
  Future<String?> takeInstalledReleaseNotes() async {
    await load();
    final values = await Future.wait([
      _storage.read(key: pendingReleaseNotesVersionStorageKey),
      _storage.read(key: pendingReleaseNotesStorageKey),
    ]);
    final targetVersion = (values[0] ?? '').trim();
    final notes = (values[1] ?? '').trim();
    if (targetVersion.isEmpty || notes.isEmpty) return null;
    // A Public/Beta channel switch may intentionally target a lower SemVer
    // while keeping the same Android versionCode. Do not mistake the currently
    // installed opposite channel for a successful install of that target.
    if (appVersionMajor(state.currentVersion) !=
        appVersionMajor(targetVersion)) {
      return null;
    }
    if (compareAppVersions(state.currentVersion, targetVersion) < 0) {
      return null;
    }
    await Future.wait([
      _storage.delete(key: pendingReleaseNotesVersionStorageKey),
      _storage.delete(key: pendingReleaseNotesStorageKey),
    ]);
    return notes;
  }

  Future<void> checkForUpdates({
    bool automatic = false,
    bool launchInstaller = false,
  }) async {
    await load();
    if (state.isBusy) return;
    if (automatic) {
      if (!state.automaticUpdates) return;
      final saved = await _storage.read(key: _automaticCheckStorageKey);
      final lastCheck = DateTime.tryParse(saved ?? '');
      if (lastCheck != null) {
        final elapsed = DateTime.now().toUtc().difference(lastCheck.toUtc());
        if (!elapsed.isNegative && elapsed < automaticCheckInterval) return;
      }
    }
    state = state.copyWith(
      phase: AppUpdatePhase.checking,
      progress: 0,
      message: automatic ? null : 'Checking GitHub for updates…',
    );
    try {
      final releaseSource = _sourceFor(state.updateChannel);
      final release = await releaseSource.latest(
        deviceAbis: await _deviceAbisLoader(),
      );
      if (appVersionMajor(release.version) !=
          state.updateChannel.releaseMajor) {
        throw FormatException(
          'The ${state.updateChannel.displayName} update service returned a '
          'release from the wrong version family.',
        );
      }
      final downgradeMessage = _knownDowngradeMessage(release);
      if (downgradeMessage != null) {
        state = state.copyWith(
          phase: AppUpdatePhase.error,
          latestVersion: release.version,
          release: release,
          downloadedPath: null,
          progress: 0,
          message: downgradeMessage,
        );
        await _recordSuccessfulAutomaticCheck(automatic);
        return;
      }
      if (!shouldOfferAppRelease(
        currentVersion: state.currentVersion,
        releaseVersion: release.version,
        channel: state.updateChannel,
        releaseVersionCode: release.androidVersionCode,
      )) {
        state = state.copyWith(
          phase: AppUpdatePhase.upToDate,
          latestVersion: release.version,
          release: release,
          downloadedPath: null,
          message: 'TetoTV ${state.currentVersion} is up to date.',
        );
        await _recordSuccessfulAutomaticCheck(automatic);
        return;
      }
      state = state.copyWith(
        phase: AppUpdatePhase.available,
        latestVersion: release.version,
        release: release,
        downloadedPath: null,
        message:
            'TetoTV ${state.updateChannel.versionLabel(release.version)} '
            'is available on the '
            '${state.updateChannel.displayName} channel.',
      );
      await downloadUpdate(
        release: release,
        releaseSource: releaseSource,
        launchInstaller: launchInstaller,
      );
      if (state.phase == AppUpdatePhase.ready) {
        await _recordSuccessfulAutomaticCheck(automatic);
      }
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      state = state.copyWith(
        phase: AppUpdatePhase.error,
        message: status == 404
            ? 'No TetoTV update is available right now.'
            : 'Update check failed: ${_safeUpdateError(error)}',
      );
    } catch (error) {
      state = state.copyWith(
        phase: AppUpdatePhase.error,
        message: 'Update check failed: ${_safeUpdateError(error)}',
      );
    }
  }

  Future<void> _recordSuccessfulAutomaticCheck(bool automatic) async {
    if (!automatic) return;
    try {
      await _storage.write(
        key: _automaticCheckStorageKey,
        value: DateTime.now().toUtc().toIso8601String(),
      );
    } catch (_) {
      // A failed bookkeeping write must not turn a valid update check into an
      // error. The next launch may simply check GitHub again.
    }
  }

  Future<void> downloadUpdate({
    AppReleaseInfo? release,
    AppReleaseSource? releaseSource,
    bool launchInstaller = false,
  }) async {
    await load();
    final selected = release ?? state.release;
    if (selected == null || state.isBusy) return;
    state = state.copyWith(
      phase: AppUpdatePhase.downloading,
      progress: 0,
      message:
          'Downloading TetoTV '
          '${state.updateChannel.versionLabel(selected.version)}…',
    );
    try {
      final cache = await _cacheDirectoryLoader();
      final directory = Directory(path.join(cache.path, 'updates'));
      await directory.create(recursive: true);
      final destination = path.join(
        directory.path,
        path.basename(selected.asset.name),
      );
      var lastPercent = -1;
      await (releaseSource ?? _sourceFor(state.updateChannel)).download(
        release: selected,
        destination: destination,
        onProgress: (received, total) {
          if (total <= 0 || !mounted) return;
          final percent = ((received / total) * 100).floor().clamp(0, 100);
          if (percent == lastPercent) return;
          lastPercent = percent;
          state = state.copyWith(
            phase: AppUpdatePhase.downloading,
            progress: percent / 100,
            message:
                'Downloading TetoTV '
                '${state.updateChannel.versionLabel(selected.version)}… '
                '$percent%',
          );
        },
      );
      final file = File(destination);
      final size = await file.length();
      final expected = selected.asset.size;
      if (size < 1024 * 1024 || (expected > 0 && size != expected)) {
        await _deleteUpdateFile(file);
        throw StateError('The downloaded APK was incomplete.');
      }
      final expectedDigest = selected.asset.sha256Digest;
      if (expectedDigest != null) {
        final actualDigest = (await sha256.bind(file.openRead()).first)
            .toString()
            .toLowerCase();
        if (actualDigest != expectedDigest.toLowerCase()) {
          await _deleteUpdateFile(file);
          throw StateError('The downloaded APK failed its integrity check.');
        }
      }
      final inspection = await apkInspector?.call(destination);
      if (inspection != null) {
        if (!inspection.compatible) {
          await _deleteUpdateFile(file);
          throw StateError(_apkCompatibilityError(inspection));
        }
        if (inspection.versionName != selected.version) {
          await _deleteUpdateFile(file);
          throw StateError(
            'The downloaded APK did not match the selected release version.',
          );
        }
      }
      if (selected.notes.trim().isNotEmpty) {
        try {
          await Future.wait([
            _storage.write(
              key: pendingReleaseNotesVersionStorageKey,
              value: selected.version,
            ),
            _storage.write(
              key: pendingReleaseNotesStorageKey,
              value: selected.notes.trim(),
            ),
          ]);
        } catch (_) {
          // Release-note bookkeeping must never block a valid app update.
        }
      }
      state = state.copyWith(
        phase: AppUpdatePhase.ready,
        progress: 1,
        downloadedPath: destination,
        message:
            'TetoTV ${state.updateChannel.versionLabel(selected.version)} '
            'is ready to install.',
      );
      if (launchInstaller) await installDownloadedUpdate();
    } catch (error) {
      state = state.copyWith(
        phase: AppUpdatePhase.error,
        message: 'Update download failed: ${_safeUpdateError(error)}',
      );
    }
  }

  AppReleaseSource _sourceFor(AppUpdateChannel channel) =>
      channel == AppUpdateChannel.beta ? _betaReleaseSource : _releaseSource;

  String? _knownDowngradeMessage(AppReleaseInfo release) {
    final installedVersionCode = appVersionCode(state.currentVersion);
    final releaseVersionCode = release.androidVersionCode;
    if (installedVersionCode == null ||
        releaseVersionCode == null ||
        !isKnownAndroidVersionDowngrade(
          currentVersion: state.currentVersion,
          releaseVersionCode: releaseVersionCode,
        )) {
      return null;
    }
    return androidVersionDowngradeMessage(
      installedVersionCode: installedVersionCode,
      releaseVersionCode: releaseVersionCode,
    );
  }

  String get _automaticCheckStorageKey =>
      state.updateChannel == AppUpdateChannel.public
      ? lastAutomaticUpdateCheckStorageKey
      : '${lastAutomaticUpdateCheckStorageKey}_${state.updateChannel.name}';

  Future<void> installDownloadedUpdate() async {
    final apkPath = state.downloadedPath;
    if (apkPath == null || state.isBusy) return;
    state = state.copyWith(
      phase: AppUpdatePhase.installing,
      message: 'Opening the Android installer…',
    );
    try {
      await _apkInstaller(apkPath);
      state = state.copyWith(
        phase: AppUpdatePhase.ready,
        message: 'Approve the TetoTV update in the Android installer.',
      );
    } catch (error) {
      state = state.copyWith(
        phase: AppUpdatePhase.error,
        message: 'Could not open the Android installer: $error',
      );
    }
  }
}

String _apkCompatibilityError(ApkCompatibilityInfo inspection) {
  if (inspection.issueCodes.contains('version_downgrade')) {
    final target = inspection.versionCode;
    final installed = inspection.installedVersionCode;
    if (target > 0 && installed > 0) {
      return androidVersionDowngradeMessage(
        installedVersionCode: installed,
        releaseVersionCode: target,
      );
    }
    return 'Android blocks in-place downgrades. Developer mode can browse '
        'older releases but cannot bypass this device security rule.';
  }
  return 'This APK is not compatible: ${inspection.issues.join(' ')}';
}

String _safeUpdateError(Object error) {
  if (error is DioException) {
    final status = error.response?.statusCode;
    return status == null
        ? 'network error'
        : 'update service returned HTTP $status';
  }
  if (error is StateError || error is FormatException) {
    var message = error.toString();
    message = message
        .replaceFirst(RegExp(r'^(Bad state|FormatException):\s*'), '')
        .replaceAll(RegExp(r'github_pat_[A-Za-z0-9_]+'), '[redacted]')
        .replaceAll(
          RegExp(
            r'(authorization|token)\s*[:=]\s*[^\s,;]+',
            caseSensitive: false,
          ),
          r'$1=[redacted]',
        );
    return message.length <= 240 ? message : '${message.substring(0, 240)}…';
  }
  return 'unexpected error';
}

Future<void> _deleteUpdateFile(File file) async {
  try {
    if (await file.exists()) await file.delete();
  } catch (_) {
    // Best effort: Android's installer is never opened after validation fails.
  }
}
