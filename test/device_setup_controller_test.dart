import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:anime_tv/features/settings/application/device_setup_controller.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('calibration reports modern hardware capabilities', () {
    const profile = TvDeviceProfile(
      manufacturer: 'Example',
      model: 'TV',
      sdk: 35,
      abis: ['arm64-v8a'],
      displayModes: [],
      hdrTypes: [2],
      codecs: [
        TvCodecCapability(
          name: 'hardware.avc',
          mime: 'video/avc',
          hardware: true,
          maxWidth: 4096,
          maxHeight: 2160,
        ),
        TvCodecCapability(
          name: 'hardware.hevc',
          mime: 'video/hevc',
          hardware: true,
          tenBit: true,
          maxWidth: 4096,
          maxHeight: 2160,
        ),
        TvCodecCapability(
          name: 'hardware.av1',
          mime: 'video/av01',
          hardware: true,
          tenBit: true,
        ),
      ],
      audioOutputs: [
        {
          'name': 'HDMI',
          'hdmi': true,
          'channels': [2, 6, 8],
        },
      ],
    );

    final report = buildDeviceCalibrationReport(profile);
    expect(report.checks.where((item) => item.supported), hasLength(7));
    expect(report.recommendation, contains('modern AV1/HEVC'));
  });

  test('calibration recommends compatibility for missing hardware AVC', () {
    const profile = TvDeviceProfile.unknown();
    final report = buildDeviceCalibrationReport(profile);
    expect(
      report.checks.firstWhere((item) => item.label == 'H.264 / AVC').supported,
      isFalse,
    );
    expect(report.recommendation, contains('MPV'));
  });

  test(
    'unknown profiles are never persisted as an MPV recommendation',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final controller = _DeviceSetupControllerFixture();

      await controller.markCompleted();

      expect(controller.state.previouslyCompleted, isFalse);
    },
  );
}

class _DeviceSetupControllerFixture extends DeviceSetupController {
  _DeviceSetupControllerFixture() : super(const FlutterSecureStorage()) {
    state = DeviceSetupState(
      report: buildDeviceCalibrationReport(const TvDeviceProfile.unknown()),
    );
  }
}
