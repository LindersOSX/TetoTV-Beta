#!/usr/bin/env bash
set -euo pipefail

# Builds every open-source native playback input shipped by TetoTV instead of
# consuming the upstream projects' prebuilt Android JARs. The build is Linux
# only because both upstream native build systems target the Linux Android NDK.

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
readonly OUTPUT_DIR="${1:-${REPO_ROOT}/build/native-playback/outputs}"
readonly WORK_DIR="${TETOTV_NATIVE_WORK_DIR:-${REPO_ROOT}/build/native-playback/work}"
readonly DOWNLOAD_DIR="${TETOTV_NATIVE_DOWNLOAD_DIR:-${REPO_ROOT}/build/native-playback/downloads}"
readonly JOBS="${TETOTV_NATIVE_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"
readonly SOURCE_DATE_EPOCH="1704067200"

readonly NDK25_ARCHIVE="android-ndk-r25c-linux.zip"
readonly NDK25_URL="https://dl.google.com/android/repository/${NDK25_ARCHIVE}"
readonly NDK25_SIZE="531118193"
readonly NDK25_SHA256="769ee342ea75f80619d985c2da990c48b3d8eaf45f48783a2d48870d04b46108"
readonly NDK28_ARCHIVE="android-ndk-r28c-linux.zip"
readonly NDK28_URL="https://dl.google.com/android/repository/${NDK28_ARCHIVE}"
readonly NDK28_SIZE="722261334"
readonly NDK28_SHA256="dfb20d396df28ca02a8c708314b814a4d961dc9074f9a161932746f815aa552f"
readonly NDK28_RANDOM_HEADER_BEFORE_SHA256="310c7cbd6fa288018045b2e342dd9b923f10df0bef74781fa503289441015f4f"
readonly NDK28_RANDOM_HEADER_AFTER_SHA256="8f04b9ea185b8bc15a96fc9c5b44d53033e29c38743cdaae87ff320b0eb6bbd5"
readonly USRSCTP_CMAKE_BEFORE_SHA256="becfaaa3599cf33bcff377ef55964b3eddefad92026d65d55590d452a3a4ef83"
readonly USRSCTP_CMAKE_AFTER_SHA256="476716234275c5559caff8db319e47e8809eae001eaf8dc39c51a2824bc396b0"

readonly BOOST_ARCHIVE="boost_1_89_0.tar.gz"
readonly BOOST_URL="https://archives.boost.io/release/1.89.0/source/${BOOST_ARCHIVE}"
readonly BOOST_SIZE="190099283"
readonly BOOST_SHA256="9de758db755e8330a01d995b0a24d09798048400ac25c03fc5ea9be364b13c93"
readonly OPENSSL_ARCHIVE="openssl-3.5.2.tar.gz"
readonly OPENSSL_URL="https://github.com/openssl/openssl/releases/download/openssl-3.5.2/${OPENSSL_ARCHIVE}"
readonly OPENSSL_SIZE="53180161"
readonly OPENSSL_SHA256="c53a47e5e441c930c3928cf7bf6fb00e5d129b630e0aa873b08258656e7345ec"
readonly FFMPEG_DASH_PATCH_SHA256="625b8c09f356fcf60850a18856736d9b96055674102177d4faf739f50bd8dd7d"
readonly FFMPEG_HLS_PATCH_SHA256="a8f5445db1e2d0fec936b1b885d98fbd07d3d989b951b8b60c20a29d6f49edfd"
readonly MPV_JNI_PATCH_SHA256="7184d1b1d52c2877b623fad23ad5cacf0e528311c15f64376fcf68de44602259"

export LC_ALL=C
export LANG=C
export TZ=UTC
export SOURCE_DATE_EPOCH
export ZERO_AR_DATE=1
export PYTHONHASHSEED=0

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'Missing required command: %s\n' "$1" >&2
    exit 1
  }
}

for command_name in git curl sha256sum stat unzip tar cmake meson ninja \
  autoconf automake libtoolize make pkg-config nasm java javac jar jq; do
  require_command "${command_name}"
done

mkdir -p "${OUTPUT_DIR}" "${WORK_DIR}" "${DOWNLOAD_DIR}"

download_verified() {
  local url="$1"
  local expected_size="$2"
  local expected_sha256="$3"
  local destination="$4"
  if [[ ! -f "${destination}" ]]; then
    local partial="${destination}.partial"
    rm -f -- "${partial}"
    curl --fail --location --retry 3 --proto '=https' --tlsv1.2 \
      --output "${partial}" "${url}"
    mv -- "${partial}" "${destination}"
  fi
  [[ "$(stat -c '%s' "${destination}")" == "${expected_size}" ]] || {
    printf 'Size mismatch for %s\n' "${destination}" >&2
    exit 1
  }
  printf '%s  %s\n' "${expected_sha256}" "${destination}" |
    sha256sum --check --strict
}

verify_sha256() {
  local path="$1"
  local expected_sha256="$2"
  printf '%s  %s\n' "${expected_sha256}" "${path}" |
    sha256sum --check --strict
}

checkout_exact() {
  local repository="$1"
  local revision="$2"
  local destination="$3"
  if [[ ! -d "${destination}/.git" ]]; then
    rm -rf -- "${destination}"
    git init --quiet "${destination}"
    git -C "${destination}" remote add origin "${repository}"
  fi
  if ! git -C "${destination}" cat-file -e "${revision}^{commit}" 2>/dev/null; then
    git -C "${destination}" fetch --quiet --depth 1 origin "${revision}"
  fi
  git -C "${destination}" checkout --quiet --detach "${revision}"
  git -C "${destination}" reset --quiet --hard "${revision}"
  [[ "$(git -C "${destination}" rev-parse HEAD)" == "${revision}" ]] || {
    printf 'Revision mismatch in %s\n' "${destination}" >&2
    exit 1
  }
}

extract_once() {
  local archive="$1"
  local marker="$2"
  local destination="$3"
  if [[ -f "${marker}" ]]; then return 0; fi
  rm -rf -- "${destination}"
  mkdir -p "${destination}"
  case "${archive}" in
    *.zip) unzip -q "${archive}" -d "${destination}" ;;
    *.tar.gz) tar -xzf "${archive}" -C "${destination}" ;;
    *) printf 'Unsupported archive: %s\n' "${archive}" >&2; exit 1 ;;
  esac
  touch "${marker}"
}

download_verified "${NDK25_URL}" "${NDK25_SIZE}" "${NDK25_SHA256}" \
  "${DOWNLOAD_DIR}/${NDK25_ARCHIVE}"
download_verified "${NDK28_URL}" "${NDK28_SIZE}" "${NDK28_SHA256}" \
  "${DOWNLOAD_DIR}/${NDK28_ARCHIVE}"
download_verified "${BOOST_URL}" "${BOOST_SIZE}" "${BOOST_SHA256}" \
  "${DOWNLOAD_DIR}/${BOOST_ARCHIVE}"
download_verified "${OPENSSL_URL}" "${OPENSSL_SIZE}" "${OPENSSL_SHA256}" \
  "${DOWNLOAD_DIR}/${OPENSSL_ARCHIVE}"

extract_once "${DOWNLOAD_DIR}/${NDK25_ARCHIVE}" \
  "${WORK_DIR}/.ndk25-extracted" "${WORK_DIR}/ndk25"
extract_once "${DOWNLOAD_DIR}/${NDK28_ARCHIVE}" \
  "${WORK_DIR}/.ndk28-extracted" "${WORK_DIR}/ndk28"
readonly NDK25="${WORK_DIR}/ndk25/android-ndk-r25c"
readonly NDK28="${WORK_DIR}/ndk28/android-ndk-r28c"

# libtorrent4j 2.1.0-38's upstream Android build deliberately backports the
# random(2) declaration to its API-24 floor before compiling with NDK r28c.
# Reproduce that exact, reviewable toolchain delta and fail if Google's header
# no longer has the expected declaration instead of silently applying a broad
# replacement to an unknown NDK.
readonly NDK28_RANDOM_HEADER="${NDK28}/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include/sys/random.h"
random_header_sha256="$(sha256sum "${NDK28_RANDOM_HEADER}" | cut -d' ' -f1)"
if [[ "${random_header_sha256}" == "${NDK28_RANDOM_HEADER_BEFORE_SHA256}" ]]; then
  # Match libtorrent4j's API-floor patch exactly: the availability guard,
  # annotation, and adjacent guard comment all move together from 28 to 24.
  sed -i 's/28/24/g' "${NDK28_RANDOM_HEADER}"
  random_header_sha256="$(sha256sum "${NDK28_RANDOM_HEADER}" | cut -d' ' -f1)"
fi
if [[ "${random_header_sha256}" != "${NDK28_RANDOM_HEADER_AFTER_SHA256}" ]]; then
  printf 'Unexpected NDK r28c sys/random.h digest after API-24 patch: %s\n' \
    "${random_header_sha256}" >&2
  exit 1
fi

build_libmpv() {
  local root="${WORK_DIR}/libmpv"
  local build_repo="${root}/libmpv-android-video-build"
  local scripts="${build_repo}/buildscripts"
  local deps="${scripts}/deps"

  checkout_exact https://github.com/media-kit/libmpv-android-video-build.git \
    fe8c3ac1a91c09aa6fb1deccbc833f1bafa54768 "${build_repo}"
  mkdir -p "${deps}" "${scripts}/sdk/android-sdk-linux/ndk" \
    "${scripts}/sdk/bin"

  checkout_exact https://github.com/Mbed-TLS/mbedtls.git \
    1873d3bfc2da771672bd8e7e8f41f57e0af77f33 "${deps}/mbedtls"
  checkout_exact https://code.videolan.org/videolan/dav1d.git \
    676a864a11af2c0522e1f992e770589543894686 "${deps}/dav1d"
  checkout_exact https://gitlab.gnome.org/GNOME/libxml2.git \
    f507d167f1755b7eaea09fb1a44d29aab828b6d1 "${deps}/libxml2"
  checkout_exact https://github.com/FFmpeg/FFmpeg.git \
    ea3d24bbe3c58b171e55fe2151fc7ffaca3ab3d2 "${deps}/ffmpeg"
  checkout_exact https://gitlab.freedesktop.org/freetype/freetype.git \
    de8b92dd7ec634e9e2b25ef534c54a3537555c11 "${deps}/freetype"
  checkout_exact https://github.com/fribidi/fribidi.git \
    6428d8469e536bcbb6e12c7b79ba6659371c435a "${deps}/fribidi"
  checkout_exact https://github.com/harfbuzz/harfbuzz.git \
    a321c4fee56b15247c10f9aa3db7e7ccb3b8173b "${deps}/harfbuzz"
  checkout_exact https://github.com/libass/libass.git \
    e8ad72accd3a84268275a9385beb701c9284e5b3 "${deps}/libass"
  checkout_exact https://github.com/mpv-player/mpv.git \
    78d43740f52db817d98bcf24fb30a76ab6fa13ff "${deps}/mpv"
  checkout_exact https://github.com/media-kit/media-kit-android-helper.git \
    42054e5d479f39ccbb0ae604862e2bcaf59b74c2 \
    "${deps}/media-kit-android-helper"
  checkout_exact https://github.com/FFmpeg/gas-preprocessor.git \
    ac1836309c2e77023c228b7184485597286289d3 \
    "${root}/gas-preprocessor"

  ln -sfn "${NDK25}" \
    "${scripts}/sdk/android-sdk-linux/ndk/25.2.9519653"
  ln -sfn "${root}/gas-preprocessor/gas-preprocessor.pl" \
    "${scripts}/sdk/bin/gas-preprocessor.pl"
  chmod +x "${scripts}/sdk/bin/gas-preprocessor.pl"
  cp -- "${scripts}/flavors/default.sh" "${scripts}/scripts/ffmpeg.sh"
  # Upstream invokes sudo only to chmod files from its own checkout. A
  # hermetic build must never pause for elevation, so perform the same chmod as
  # the current user and remove that unnecessary sudo from the pinned script.
  sed -i 's/sudo chmod +x/chmod +x/g' "${scripts}/build.sh"
  find "${scripts}" -type f -name '*.sh' -exec chmod +x {} +

  printf '%s  %s\n' "${FFMPEG_DASH_PATCH_SHA256}" \
    "${scripts}/patches/ffmpeg/dash_base_url_escape.patch" |
    sha256sum --check --strict
  printf '%s  %s\n' "${FFMPEG_HLS_PATCH_SHA256}" \
    "${scripts}/patches/ffmpeg/hls_mp4_seek.patch" |
    sha256sum --check --strict
  printf '%s  %s\n' "${MPV_JNI_PATCH_SHA256}" \
    "${scripts}/patches/mpv/mpv_lavc_set_java_vm.patch" |
    sha256sum --check --strict

  (
    cd "${scripts}"
    ./patch.sh
    cores="${JOBS}" ./build.sh --arch armv7l mpv
    cores="${JOBS}" ./build.sh --arch arm64 mpv
  )

  local strip="${NDK25}/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip"
  local helper_source="${deps}/media-kit-android-helper/app/src/main/cpp"
  local abi
  for abi in armeabi-v7a arm64-v8a; do
    "${strip}" --strip-all \
      "${scripts}/prefix/${abi}/usr/local/lib/libmpv.so"
    local helper_build="${root}/helper-${abi}"
    rm -rf -- "${helper_build}"
    cmake -S "${helper_source}" -B "${helper_build}" -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_TOOLCHAIN_FILE="${NDK25}/build/cmake/android.toolchain.cmake" \
      -DANDROID_ABI="${abi}" -DANDROID_PLATFORM=android-21 \
      -DANDROID_STL=c++_static
    cmake --build "${helper_build}" --parallel "${JOBS}"

    local stage="${root}/jar-${abi}"
    rm -rf -- "${stage}"
    mkdir -p "${stage}/lib/${abi}"
    cp -- "${scripts}/prefix/${abi}/usr/local/lib/libmpv.so" \
      "${stage}/lib/${abi}/libmpv.so"
    cp -- "${helper_build}/libmediakitandroidhelper.so" \
      "${stage}/lib/${abi}/libmediakitandroidhelper.so"
    (
      cd "${stage}"
      jar --create --file "${OUTPUT_DIR}/default-${abi}.jar" \
        --date=2000-01-01T00:00:00Z -C "${stage}" lib
    )
  done
}

populate_libtorrent_submodules() {
  local libtorrent="$1"
  local datachannel="${libtorrent}/deps/libdatachannel"
  # libtorrent's build files always compile deps/try_signal. Git archives do
  # not populate that gitlink, so pin it explicitly rather than depending on
  # ambient submodule state or an incomplete source snapshot.
  checkout_exact https://github.com/arvidn/try_signal.git \
    105cce59972f925a33aa6b1c3109e4cd3caf583d \
    "${libtorrent}/deps/try_signal"
  checkout_exact https://github.com/paullouisageneau/libdatachannel.git \
    6ab310b5887eab78cf0c0767a8ced2ebff8c7479 "${datachannel}"
  checkout_exact https://github.com/paullouisageneau/libjuice.git \
    2de35247f0b15fa385406f3e2020d0e3d4d5cfcc \
    "${datachannel}/deps/libjuice"
  checkout_exact https://github.com/sctplab/usrsctp.git \
    ebb18adac6501bad4501b1f6dccb67a1c85cc299 \
    "${datachannel}/deps/usrsctp"
  local usrsctp_cmake="${datachannel}/deps/usrsctp/CMakeLists.txt"
  verify_sha256 "${usrsctp_cmake}" "${USRSCTP_CMAKE_BEFORE_SHA256}"
  # CMake 4 removed compatibility with policies older than 3.5. The pinned
  # usrsctp source declares 3.0 even though this configuration is compatible
  # with 3.5, so apply the smallest auditable source-build compatibility patch.
  sed -i \
    's/cmake_minimum_required(VERSION 3.0)/cmake_minimum_required(VERSION 3.5)/' \
    "${usrsctp_cmake}"
  verify_sha256 "${usrsctp_cmake}" "${USRSCTP_CMAKE_AFTER_SHA256}"
  checkout_exact https://github.com/SergiusTheBest/plog.git \
    e21baecd4753f14da64ede979c5a19302618b752 \
    "${datachannel}/deps/plog"
}

build_libtorrent4j_abi() {
  local source_root="$1"
  local abi="$2"
  local openssl_target="$3"
  local compiler_prefix="$4"
  local boost_toolset="$5"
  local boost_config="$6"

  local toolchain="${NDK28}/toolchains/llvm/prebuilt/linux-x86_64"
  local arch_root="${WORK_DIR}/libtorrent4j-build/${abi}"
  local boost_root="${arch_root}/boost"
  local openssl_root="${arch_root}/openssl"
  rm -rf -- "${arch_root}"
  mkdir -p "${arch_root}"
  tar -xzf "${DOWNLOAD_DIR}/${BOOST_ARCHIVE}" -C "${arch_root}"
  mv -- "${arch_root}/boost_1_89_0" "${boost_root}"
  (
    cd "${boost_root}"
    ./bootstrap.sh
  )

  tar -xzf "${DOWNLOAD_DIR}/${OPENSSL_ARCHIVE}" -C "${arch_root}"
  local openssl_source="${arch_root}/openssl-3.5.2"
  (
    cd "${openssl_source}"
    export CC="${toolchain}/bin/${compiler_prefix}24-clang"
    export AR="${toolchain}/bin/llvm-ar"
    export LD="${toolchain}/bin/ld"
    export RANLIB="${toolchain}/bin/llvm-ranlib"
    local arch_flags
    if [[ "${abi}" == "armeabi-v7a" ]]; then
      arch_flags='-march=armv7-a -mfpu=neon'
    else
      arch_flags='-march=armv8-a+crypto'
    fi
    ./Configure "${openssl_target}" no-deprecated no-shared no-makedepend \
      no-static-engine no-stdio no-posix-io no-threads no-ui-console no-zlib \
      no-zlib-dynamic -fno-strict-aliasing -fvisibility=hidden -O3 \
      ${arch_flags} -fPIC --prefix="${openssl_root}"
    make -j"${JOBS}"
    make install_sw
  )

  local source_copy="${arch_root}/libtorrent4j"
  cp -a -- "${source_root}" "${source_copy}"
  export ANDROID_TOOLCHAIN="${toolchain}"
  export BOOST_ROOT="${boost_root}"
  export OPENSSL_ROOT="${openssl_root}"
  export LIBTORRENT_ROOT="${source_copy}/swig/deps/libtorrent"
  export CXX="${toolchain}/bin/${compiler_prefix}24-clang++"
  export CC="${toolchain}/bin/${compiler_prefix}24-clang"
  export AR="${toolchain}/bin/llvm-ar"
  export LD="${toolchain}/bin/ld"
  export RANLIB="${toolchain}/bin/llvm-ranlib"
  local -a page_size_linkflags=()
  if [[ "${abi}" == "armeabi-v7a" ]]; then
    # NDK r28's ARMv7 linker default is still 4 KiB. Keep the already-compliant
    # ARM64 output unchanged while making this ELF loadable on 16 KiB devices.
    page_size_linkflags=(
      "linkflags=-Wl,-z,common-page-size=16384 -Wl,-z,max-page-size=16384"
    )
  fi
  (
    cd "${source_copy}/swig"
    "${boost_root}/b2" -j"${JOBS}" \
      --user-config="config/${boost_config}" variant=release \
      toolset="${boost_toolset}" target-os=android \
      location="bin/release/android/${abi}" \
      "${page_size_linkflags[@]}"
  )
  "${toolchain}/bin/llvm-strip" --strip-unneeded -x \
    "${source_copy}/swig/bin/release/android/${abi}/libtorrent4j.so"
  cp -- "${source_copy}/swig/bin/release/android/${abi}/libtorrent4j.so" \
    "${WORK_DIR}/libtorrent4j-combined/swig/bin/release/android/${abi}/libtorrent4j.so"
}

build_libtorrent4j() {
  local root="${WORK_DIR}/libtorrent4j-combined"
  checkout_exact https://github.com/aldenml/libtorrent4j.git \
    09ffd391d4ef12e668cc032bffcbab47d9e2d5cb "${root}"
  checkout_exact https://github.com/arvidn/libtorrent.git \
    a01469c8d1f88dd83bed458ffccffab2727b9d2a \
    "${root}/swig/deps/libtorrent"
  populate_libtorrent_submodules "${root}/swig/deps/libtorrent"

  mkdir -p "${root}/swig/bin/release/android/armeabi-v7a" \
    "${root}/swig/bin/release/android/arm64-v8a"
  build_libtorrent4j_abi "${root}" armeabi-v7a linux-armv4 \
    armv7a-linux-androideabi clang-linux-arm android-arm-config.jam
  build_libtorrent4j_abi "${root}" arm64-v8a linux-aarch64 \
    aarch64-linux-android clang-arm64 android-arm64-config.jam

  # The Java wrapper has no runtime Java dependencies. Compile and package it
  # directly so the release does not depend on an unverified Gradle download,
  # and give every JAR entry a fixed timestamp.
  local java_build="${WORK_DIR}/libtorrent4j-java"
  rm -rf -- "${java_build}"
  mkdir -p "${java_build}/classes"
  find "${root}/src/main/java" -type f -name '*.java' | LC_ALL=C sort \
    > "${java_build}/sources.list"
  javac --release 8 -encoding UTF-8 -d "${java_build}/classes" \
    @"${java_build}/sources.list"
  jar --create --file "${OUTPUT_DIR}/libtorrent4j-2.1.0-38.jar" \
    --date=2000-01-01T00:00:00Z -C "${java_build}/classes" .

  local abi artifact stage
  for abi in armeabi-v7a arm64-v8a; do
    if [[ "${abi}" == "armeabi-v7a" ]]; then
      artifact="libtorrent4j-android-arm-2.1.0-38.jar"
    else
      artifact="libtorrent4j-android-arm64-2.1.0-38.jar"
    fi
    stage="${WORK_DIR}/libtorrent4j-jar-${abi}"
    rm -rf -- "${stage}"
    mkdir -p "${stage}/lib/${abi}"
    cp -- "${root}/swig/bin/release/android/${abi}/libtorrent4j.so" \
      "${stage}/lib/${abi}/libtorrent4j.so"
    jar --create --file "${OUTPUT_DIR}/${artifact}" \
      --date=2000-01-01T00:00:00Z -C "${stage}" lib
  done
}

rm -f -- "${OUTPUT_DIR}/NATIVE_BUILD_PROVENANCE.json" \
  "${OUTPUT_DIR}/SHA256SUMS"
if [[ "${TETOTV_NATIVE_SKIP_LIBMPV:-0}" == "1" ]]; then
  for artifact in default-arm64-v8a.jar default-armeabi-v7a.jar; do
    [[ -s "${OUTPUT_DIR}/${artifact}" ]] || {
      printf 'Cannot skip libmpv; missing prior output: %s\n' "${artifact}" >&2
      exit 1
    }
  done
else
  rm -f -- "${OUTPUT_DIR}/default-arm64-v8a.jar" \
    "${OUTPUT_DIR}/default-armeabi-v7a.jar"
  build_libmpv
fi

if [[ "${TETOTV_NATIVE_SKIP_LIBTORRENT4J:-0}" == "1" ]]; then
  for artifact in libtorrent4j-2.1.0-38.jar \
    libtorrent4j-android-arm-2.1.0-38.jar \
    libtorrent4j-android-arm64-2.1.0-38.jar; do
    [[ -s "${OUTPUT_DIR}/${artifact}" ]] || {
      printf 'Cannot skip libtorrent4j; missing prior output: %s\n' \
        "${artifact}" >&2
      exit 1
    }
  done
else
  rm -f -- "${OUTPUT_DIR}/libtorrent4j-2.1.0-38.jar" \
    "${OUTPUT_DIR}/libtorrent4j-android-arm-2.1.0-38.jar" \
    "${OUTPUT_DIR}/libtorrent4j-android-arm64-2.1.0-38.jar"
  build_libtorrent4j
fi

(
  cd "${OUTPUT_DIR}"
  sha256sum -- *.jar | sort -k2 > SHA256SUMS
)

jq -n \
  --arg buildScriptSha256 "$(sha256sum "${BASH_SOURCE[0]}" | cut -d' ' -f1)" \
  --arg ndk25Sha256 "${NDK25_SHA256}" \
  --arg ndk28Sha256 "${NDK28_SHA256}" \
  --arg host "$(uname -a)" \
  --arg cmake "$(cmake --version | head -n1)" \
  --arg meson "$(meson --version)" \
  --arg java "$(java -version 2>&1 | head -n1)" \
  --rawfile outputs "${OUTPUT_DIR}/SHA256SUMS" \
  '{schemaVersion: 1, selfBuilt: true, sourceDateEpoch: 1704067200,
    buildScriptSha256: $buildScriptSha256,
    toolchains: {androidNdk25cSha256: $ndk25Sha256,
      androidNdk28cSha256: $ndk28Sha256},
    host: {kernel: $host, cmake: $cmake, meson: $meson, java: $java},
    outputChecksums: ($outputs | split("\n") | map(select(length > 0)))}' \
  > "${OUTPUT_DIR}/NATIVE_BUILD_PROVENANCE.json"

printf 'Self-built native playback artifacts:\n'
cat "${OUTPUT_DIR}/SHA256SUMS"
