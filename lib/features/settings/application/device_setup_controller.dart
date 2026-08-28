import 'dart:async';

import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:anime_tv/features/auth/application/pairing_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const _calibratedDeviceKey = 'device_calibration_profile_v1';
const _calibratedAtKey = 'device_calibration_date_v1';

class CapabilityCheck {
  const CapabilityCheck({
    required this.label,
    required this.supported,
    required this.detail,
  });

  final String label;
  final bool supported;
  final String detail;
}

class DeviceCalibrationReport {
  const DeviceCalibrationReport({
    required this.profile,
    required this.checks,
    required this.recommendation,
  });

  final TvDeviceProfile profile;
  final List<CapabilityCheck> checks;
  final String recommendation;
}

DeviceCalibrationReport buildDeviceCalibrationReport(TvDeviceProfile profile) {
  List<TvCodecCapability> codec(String mime) => profile.codecs
      .where((item) => item.mime == mime && item.hardware)
      .toList(growable: false);
  final avc = codec('video/avc');
  final hevc = codec('video/hevc');
  final av1 = codec('video/av01');
  final tenBit = profile.codecs.any((item) => item.hardware && item.tenBit);
  final surround = profile.audioOutputs.any((output) {
    final channels = (output['channels'] as List? ?? const []).whereType<int>();
    return output['hdmi'] == true || channels.any((count) => count > 2);
  });
  String codecDetail(List<TvCodecCapability> matches) {
    if (matches.isEmpty) return 'No hardware decoder reported';
    final bestWidth = matches
        .map((item) => item.maxWidth)
        .fold<int>(0, (best, width) => width > best ? width : best);
    return bestWidth >= 3840
        ? 'Hardware decoder reported, up to 4K+'
        : 'Hardware decoder reported';
  }

  final checks = <CapabilityCheck>[
    CapabilityCheck(
      label: 'H.264 / AVC',
      supported: avc.isNotEmpty,
      detail: codecDetail(avc),
    ),
    CapabilityCheck(
      label: 'H.265 / HEVC',
      supported: hevc.isNotEmpty,
      detail: codecDetail(hevc),
    ),
    CapabilityCheck(
      label: 'AV1',
      supported: av1.isNotEmpty,
      detail: codecDetail(av1),
    ),
    CapabilityCheck(
      label: '10-bit video',
      supported: tenBit,
      detail: tenBit
          ? 'A hardware Main10 decoder was reported'
          : 'Compatibility player may be used for 10-bit video',
    ),
    CapabilityCheck(
      label: 'HDR output',
      supported: profile.hasHdr,
      detail: profile.hasHdr
          ? '${profile.hdrTypes.length} HDR format(s) reported by the display'
          : 'The connected display did not report HDR',
    ),
    CapabilityCheck(
      label: 'Surround audio',
      supported: surround,
      detail: surround
          ? 'HDMI or multichannel output detected'
          : 'Stereo-safe audio will be preferred',
    ),
    const CapabilityCheck(
      label: 'Anime subtitles',
      supported: true,
      detail: 'MPV/libass subtitle rendering is installed',
    ),
  ];
  final recommendation = avc.isEmpty
      ? 'Prefer MPV compatibility playback and 1080p H.264 releases.'
      : av1.isNotEmpty && tenBit && profile.hasHdr
      ? 'This device can prefer modern AV1/HEVC releases, including HDR.'
      : hevc.isNotEmpty
      ? 'Prefer H.264 or HEVC SDR releases; compatibility fallback remains enabled.'
      : 'Prefer H.264 SDR releases for the most reliable playback.';
  return DeviceCalibrationReport(
    profile: profile,
    checks: checks,
    recommendation: recommendation,
  );
}

class DeviceSetupState {
  const DeviceSetupState({
    this.loading = false,
    this.report,
    this.error,
    this.previouslyCompleted = false,
  });

  final bool loading;
  final DeviceCalibrationReport? report;
  final String? error;
  final bool previouslyCompleted;

  DeviceSetupState copyWith({
    bool? loading,
    DeviceCalibrationReport? report,
    Object? error = _unset,
    bool? previouslyCompleted,
  }) => DeviceSetupState(
    loading: loading ?? this.loading,
    report: report ?? this.report,
    error: identical(error, _unset) ? this.error : error as String?,
    previouslyCompleted: previouslyCompleted ?? this.previouslyCompleted,
  );
}

const _unset = Object();

final deviceSetupProvider =
    StateNotifierProvider<DeviceSetupController, DeviceSetupState>((ref) {
      return DeviceSetupController(ref.watch(secureStorageProvider));
    });

class DeviceSetupController extends StateNotifier<DeviceSetupState> {
  DeviceSetupController(
    this._storage, {
    Future<TvDeviceProfile> Function()? loadProfile,
  }) : _loadProfile =
           loadProfile ??
           (() => AndroidTvBridge.instance.getDeviceProfile(refresh: true)),
       super(const DeviceSetupState());

  final FlutterSecureStorage _storage;
  final Future<TvDeviceProfile> Function() _loadProfile;
  bool _persistWhenReady = false;
  Future<void>? _scheduledPersistence;

  Future<void> scan() async {
    if (state.loading) return;
    state = state.copyWith(loading: true, error: null);
    try {
      final values = await Future.wait([
        _loadProfile(),
        _storage.read(key: _calibratedDeviceKey),
      ]);
      final profile = values[0] as TvDeviceProfile;
      if (!mounted) return;
      state = DeviceSetupState(
        report: buildDeviceCalibrationReport(profile),
        previouslyCompleted: values[1] == profile.key,
      );
      _scheduleRequestedPersistence();
    } catch (error) {
      if (mounted) {
        state = DeviceSetupState(error: 'Device scan failed: $error');
      }
    }
  }

  /// Requests setup calibration persistence without waiting for a pending
  /// platform scan. The controller owns the late completion so the setup
  /// widget can be disposed safely after Finish or Set up later.
  void persistWhenReady() {
    _persistWhenReady = true;
    _scheduleRequestedPersistence();
  }

  void _scheduleRequestedPersistence() {
    final report = state.report;
    if (!_persistWhenReady ||
        report == null ||
        state.previouslyCompleted ||
        _scheduledPersistence != null ||
        !_isKnownProfile(report.profile)) {
      return;
    }
    final persistence = _persistRequestedReport();
    _scheduledPersistence = persistence;
    unawaited(persistence);
  }

  Future<void> _persistRequestedReport() async {
    try {
      await markCompleted();
    } catch (_) {
      // Setup completion must remain nonblocking. Device calibration can be
      // retried from Settings if encrypted storage is unavailable.
    } finally {
      _scheduledPersistence = null;
    }
  }

  Future<void> markCompleted() async {
    final report = state.report;
    if (report == null) return;
    // An unknown profile is returned outside Android and when the platform
    // bridge cannot identify the device, so do not persist calibration data
    // from that fallback value.
    if (!_isKnownProfile(report.profile)) {
      return;
    }
    await Future.wait([
      _storage.write(key: _calibratedDeviceKey, value: report.profile.key),
      _storage.write(
        key: _calibratedAtKey,
        value: DateTime.now().toUtc().toIso8601String(),
      ),
      TetoTvDatabase.instance.setPreferredPlayer(report.profile.key, 'mpv'),
    ]);
    if (mounted) state = state.copyWith(previouslyCompleted: true);
  }
}

bool _isKnownProfile(TvDeviceProfile profile) =>
    profile.sdk > 0 &&
    profile.manufacturer != 'Unknown' &&
    profile.model != 'Unknown';
