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
    'libtorrent4j 2.1.0-38',
  ], 'assets/legal/native/LIBTORRENT4J_LICENSE.txt'),
  _BundledNotice([
    'libtorrent-rasterbar a01469c',
  ], 'assets/legal/native/LIBTORRENT_RASTERBAR_LICENSE.txt'),
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
  _BundledNotice([
    'libsrtp a566a9c',
  ], 'assets/legal/native/LIBSRTP_LICENSE.txt'),
  _BundledNotice(['plog e21baec'], 'assets/legal/native/PLOG_LICENSE.txt'),
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
