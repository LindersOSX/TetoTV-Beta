import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

bool _registered = false;

/// Adds notices for code that is compiled into TetoTV assets or an Android
/// AAR, and therefore is not discovered by Flutter's generated Dart-package
/// license registry.
void registerBundledThirdPartyLicenses({AssetBundle? bundle}) {
  if (_registered) return;
  _registered = true;
  final assets = bundle ?? rootBundle;

  LicenseRegistry.addLicense(() async* {
    for (final notice in _bundledNotices) {
      final text = await assets.loadString(notice.asset);
      yield LicenseEntryWithLineBreaks(notice.packages, text);
    }
  });
}

const _bundledNotices = <_BundledNotice>[
  _BundledNotice([
    'Android JS Runtimes bridge 0.3.6',
  ], 'assets/addon_runtime/ANDROID_JS_RUNTIMES_LICENSE.txt'),
  _BundledNotice([
    'QuickJS 2026-06-04',
  ], 'assets/addon_runtime/QUICKJS_LICENSE.txt'),
  _BundledNotice([
    'Bundled add-on JavaScript runtime packages',
  ], 'assets/addon_runtime/JS_RUNTIME_NOTICES.txt'),
  _BundledNotice([
    'Discord Social SDK bundled components 1.10.18369',
  ], 'third_party/discord_social_sdk/License-Notices.txt'),
  _BundledNotice([
    'TetoTV self-built native playback provenance',
  ], 'assets/legal/native/NATIVE_PLAYBACK_NOTICE.txt'),
  _BundledNotice([
    'media-kit libmpv Android build scripts fe8c3ac',
  ], 'assets/legal/native/LIBMPV_ANDROID_BUILD_DEFAULT_LICENSE.txt'),
  _BundledNotice([
    'media-kit Android helper 42054e5',
  ], 'assets/legal/native/MEDIA_KIT_ANDROID_HELPER_LICENSE.txt'),
  _BundledNotice([
    'gas-preprocessor ac18363 (build tool only)',
  ], 'assets/legal/native/GAS_PREPROCESSOR_NOTICE.txt'),
  _BundledNotice([
    'mpv 78d4374',
  ], 'assets/legal/native/MPV_COPYRIGHT.txt'),
  _BundledNotice([
    'mpv 78d4374 (LGPL terms)',
  ], 'assets/legal/native/MPV_LICENSE_LGPL.txt'),
  _BundledNotice([
    'FFmpeg 6.0 configuration and license summary',
  ], 'assets/legal/native/FFMPEG_LICENSE.md'),
  _BundledNotice([
    'FFmpeg 6.0 (LGPL-3.0-or-later terms)',
  ], 'assets/legal/native/LGPL-3.0.txt'),
  _BundledNotice([
    'Mbed TLS 3.4.0',
  ], 'assets/legal/native/MBEDTLS_LICENSE.txt'),
  _BundledNotice(['dav1d 1.2.0'], 'assets/legal/native/DAV1D_COPYING.txt'),
  _BundledNotice([
    'libxml2 2.10.3',
  ], 'assets/legal/native/LIBXML2_COPYRIGHT.txt'),
  _BundledNotice([
    'FreeType 2.13.0',
  ], 'assets/legal/native/FREETYPE_FTL.txt'),
  _BundledNotice([
    'FriBidi 1.0.12',
  ], 'assets/legal/native/FRIBIDI_COPYING.txt'),
  _BundledNotice([
    'HarfBuzz 7.2.0',
  ], 'assets/legal/native/HARFBUZZ_COPYING.txt'),
  _BundledNotice(['libass 0.17.1'], 'assets/legal/native/LIBASS_COPYING.txt'),
  _BundledNotice([
    'libtorrent4j 2.1.0-38',
  ], 'assets/legal/native/LIBTORRENT4J_LICENSE.txt'),
  _BundledNotice([
    'libtorrent-rasterbar a01469c',
  ], 'assets/legal/native/LIBTORRENT_RASTERBAR_LICENSE.txt'),
  _BundledNotice([
    'try_signal 105cce5',
  ], 'assets/legal/native/TRY_SIGNAL_LICENSE.txt'),
  _BundledNotice([
    'libtorrent-rasterbar bundled Ed25519 implementation',
  ], 'assets/legal/native/LIBTORRENT_ED25519_LICENSE.txt'),
  _BundledNotice(['Boost 1.89.0'], 'assets/legal/native/BOOST_LICENSE_1_0.txt'),
  _BundledNotice(['OpenSSL 3.5.2'], 'assets/legal/native/OPENSSL_LICENSE.txt'),
  _BundledNotice([
    'libdatachannel 6ab310b',
  ], 'assets/legal/native/LIBDATACHANNEL_LICENSE.txt'),
  _BundledNotice([
    'libjuice 2de3524',
  ], 'assets/legal/native/LIBJUICE_LICENSE.txt'),
  _BundledNotice([
    'usrsctp ebb18ad',
  ], 'assets/legal/native/USRSCTP_LICENSE.txt'),
  _BundledNotice(['plog e21baec'], 'assets/legal/native/PLOG_LICENSE.txt'),
  _BundledNotice([
    'Android NDK r25c runtime and toolchain notices',
  ], 'assets/legal/native/ANDROID_NDK_R25C_NOTICE.txt'),
  _BundledNotice([
    'Android NDK r25c toolchain notices',
  ], 'assets/legal/native/ANDROID_NDK_R25C_NOTICE_TOOLCHAIN.txt'),
  _BundledNotice([
    'Android NDK r28c runtime and toolchain notices',
  ], 'assets/legal/native/ANDROID_NDK_R28C_NOTICE.txt'),
  _BundledNotice([
    'Android NDK r28c toolchain notices',
  ], 'assets/legal/native/ANDROID_NDK_R28C_NOTICE_TOOLCHAIN.txt'),
  _BundledNotice([
    'Direct torrent native component provenance',
  ], 'assets/legal/native/DIRECT_TORRENT_NATIVE_NOTICE.txt'),
  _BundledNotice(['Noto Sans Regular'], 'assets/fonts/OFL.txt'),
];

class _BundledNotice {
  const _BundledNotice(this.packages, this.asset);

  final List<String> packages;
  final String asset;
}
