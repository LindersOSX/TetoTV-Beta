# Build and sideload on Windows

These commands assume PowerShell.

## 1. Install the host tools

Install Git and Android Studio:

```powershell
winget install --exact --id Git.Git
winget install --exact --id Google.AndroidStudio
```

Open Android Studio once. In **More Actions > SDK Manager**, install:

- the current stable Android SDK Platform;
- Android SDK Build-Tools;
- Android SDK Platform-Tools;
- Android SDK Command-line Tools (latest);
- Android Emulator.

In **Device Manager**, install a current Android TV or Google TV system image
and create a 1080p TV virtual device.

Install Flutter stable into a user-owned tools directory:

```powershell
$flutterRoot = "$env:LOCALAPPDATA\Programs\flutter"
git clone --branch stable https://github.com/flutter/flutter.git $flutterRoot
$env:Path += ";$flutterRoot\bin"
[Environment]::SetEnvironmentVariable(
  "Path",
  [Environment]::GetEnvironmentVariable("Path", "User") + ";$flutterRoot\bin",
  "User"
)
```

Point Flutter at the standard Android SDK location, accept the licenses, and
verify everything:

```powershell
flutter config --android-sdk "$env:LOCALAPPDATA\Android\Sdk"
flutter doctor --android-licenses
flutter doctor -v
```

Every Android item in `flutter doctor` should be green before continuing.

## Configure release signing

Before the first distributed release, create a unique protected signing key:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\tool\setup_release_signing.ps1
```

The script writes an ignored `android\key.properties` file and stores the
PKCS#12 keystore outside the repository under the current Windows profile. It
does not print the generated password. Back up both files separately in
encrypted offline storage. Losing the key prevents future sideloaded APKs from
updating existing installations; replacing it requires uninstalling the old
app first.

`-ReplaceExisting` is deliberately required when an old local configuration
exists. Use it only before public distribution or as part of an intentional
signing-key migration.

## 2. Initialize this project from scratch

This repository is already initialized. These are the exact commands that
created its base project and dependencies:

```powershell
New-Item -ItemType Directory -Path "C:\dev\anime_tv"
Set-Location "C:\dev\anime_tv"

flutter create `
  --platforms=android `
  --org=dev.animetv `
  --project-name=anime_tv `
  .

flutter pub add `
  media_kit `
  media_kit_video `
  media_kit_libs_android_video `
  flutter_riverpod `
  go_router `
  dio `
  flutter_secure_storage `
  qr_flutter `
  cached_network_image
```

`dev.animetv.anime_tv` is TetoTV's historical production application ID. Do
not change it, its Kotlin package/directory, or the namespace for a distributed
update: Android requires the same package ID and production signer as the
installed release.

The checked-in TV manifest already declares:

```xml
<uses-feature
    android:name="android.software.leanback"
    android:required="false" />
<uses-feature
    android:name="android.hardware.touchscreen"
    android:required="false" />
```

Its main activity includes:

```xml
<category android:name="android.intent.category.LAUNCHER" />
<category android:name="android.intent.category.LEANBACK_LAUNCHER" />
```

It also supplies `android:banner`, Internet permission, landscape orientation,
and no fake-touch requirement.

## 3. Analyze and test

From the repository root:

```powershell
flutter pub get
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
```

## 4. Run on an Android TV emulator

The command-line equivalent of Android Studio's Device Manager is:

```powershell
$sdk = "$env:LOCALAPPDATA\Android\Sdk"

& "$sdk\cmdline-tools\latest\bin\sdkmanager.bat" `
  "platform-tools" `
  "emulator" `
  "system-images;android-36;google-tv;x86_64"

"no" | & "$sdk\cmdline-tools\latest\bin\avdmanager.bat" create avd `
  --name TetoTV_API36 `
  --package "system-images;android-36;google-tv;x86_64" `
  --device "tv_1080p"

& "$sdk\emulator\emulator.exe" -avd TetoTV_API36
```

The emulator command opens a visible, interactive Google TV window. Start the
TV AVD there or in Android Studio, then:

```powershell
flutter devices
flutter run -d <device-id>
```

Use keyboard arrows as the D-pad, Enter as the center button, and Escape as
Back. The home screen should show a bright focus outline and scale effect.

## 5. Build the first sideloadable APK

Build a debug APK:

```powershell
flutter build apk --debug
```

Output:

```text
build\app\outputs\flutter-apk\app-debug.apk
```

Install it on the running emulator or connected TV:

```powershell
adb install -r .\build\app\outputs\flutter-apk\app-debug.apk
```

Launch it explicitly if needed:

```powershell
adb shell am start -n dev.animetv.anime_tv/.MainActivity
```

For an Nvidia Shield or Google TV device, enable Developer Options and network
debugging. On devices that expose wireless pairing:

```powershell
adb pair <tv-ip>:<pairing-port>
adb connect <tv-ip>:<debug-port>
adb devices
adb install -r .\build\app\outputs\flutter-apk\app-debug.apk
```

## 6. Release-sized APKs

Create a private upload key outside the repository:

```powershell
keytool -genkeypair -v `
  -keystore "C:\secure\anime-tv-upload.jks" `
  -alias upload `
  -keyalg RSA `
  -keysize 2048 `
  -validity 10000
```

Copy `android\key.properties.example` to `android\key.properties`, replace all
values, and keep the real properties and keystore outside source control. Back
up both files securely before installing the first distributed build. The
release task intentionally fails without them, and Android cannot update an
installed app signed by a different key. Public releases use one universal ARM
APK containing both supported application ABIs.

Public and Beta updates use anonymous GitHub requests. No Beta key, GitHub
token, update-proxy URL, or update-specific Dart define is required. Every
published APK uses the production signing identity. No Public APK is currently
published. Beta 2.0.40 uses Android build code `410017`. Flutter reuses
`app-release.apk`, so copy and rename the Beta artifact immediately after the
build:

```powershell
New-Item -ItemType Directory -Force .\build\fire-tv | Out-Null

# Beta 2.0.40
flutter build apk --release --target-platform android-arm,android-arm64 `
  --build-name 2.0.40 --build-number 410017 --no-tree-shake-icons
Copy-Item .\build\app\outputs\flutter-apk\app-release.apk `
  .\build\fire-tv\TetoTV-v2.0.40-universal.apk

.\tool\release\verify_release_apk.ps1 `
  -Channel Beta `
  -ApkPath .\build\fire-tv\TetoTV-v2.0.40-universal.apk

.\tool\release\verify_native_redistribution.ps1 `
  -StageBundle -ReleaseTag v2.0.40

.\tool\release\new_release_checksums.ps1 `
  -ApkPath .\build\fire-tv\TetoTV-v2.0.40-universal.apk `
  -NativeSourcePath .\build\release-compliance\TetoTV-v2.0.40-native-playback-sources.zip `
  -OutputPath .\build\fire-tv\SHA256SUMS

.\tool\release\verify_release_payloads.ps1 `
  -Channel Beta `
  -ApkPath .\build\fire-tv\TetoTV-v2.0.40-universal.apk `
  -NativeSourcePath .\build\release-compliance\TetoTV-v2.0.40-native-playback-sources.zip `
  -ChecksumsPath .\build\fire-tv\SHA256SUMS `
  -ReleaseNotesPath .\docs\RELEASE_NOTES_2.0.40.md
```

The Beta GitHub release has exactly three custom assets: the universal APK, the
versioned native playback source ZIP, and `SHA256SUMS`. GitHub also adds its
tagged source-code ZIP and tarball automatically. Keep staged third-party
notice archives as release evidence, and do not upload per-ABI APKs.

The full Material icon font is intentionally retained. This makes the release
command reproducible on Windows hosts where Application Control blocks
Flutter's optional `font-subset.exe` helper; it does not change app behavior.

Many Fire TV models expose a 32-bit application ABI even when their CPU is
64-bit. The universal APK avoids making the user choose a split. These commands
are still useful when recording a device-smoke-test inventory:

```powershell
adb shell getprop ro.product.cpu.abilist
adb shell getprop ro.build.version.sdk
```

The published `app-release.apk` contains `armeabi-v7a` and `arm64-v8a`, avoiding
device-side ABI selection errors. Keep x86_64 builds local and debug-only for
emulators. Separate ARM32/ARM64 release APKs can be restored later if there is
a specific distribution need; do not publish them by default.

The current Flutter toolchain has a minimum SDK of API 24. It supports Fire OS
6 and newer, but not Fire OS 5 devices (API 22).
