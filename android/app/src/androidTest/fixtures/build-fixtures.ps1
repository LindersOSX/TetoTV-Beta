param(
    [string]$SdkPath = "$env:LOCALAPPDATA/Android/Sdk",
    [string]$DebugKeyStore = "$env:USERPROFILE/.android/debug.keystore"
)
$ErrorActionPreference = 'Stop'
$fixtureRepo = (Resolve-Path (Join-Path $PSScriptRoot '../../../../..')).Path
$fixtureOutput = Join-Path $fixtureRepo 'build/aniyomi-isolation-fixtures'
$fixtureClasses = Join-Path $fixtureOutput 'extension-classes'
$fixtureDex = Join-Path $fixtureOutput 'dex'
$fixtureDependencyJars = Join-Path $fixtureOutput 'dependency-jars'
$fixtureAssets = Join-Path $PSScriptRoot '../assets'
$fixtureUnitClasses = Join-Path $fixtureRepo 'build/aniyomi-compat/tmp/kotlin-classes/debugUnitTest'
$fixtureCompatJar = Join-Path $fixtureRepo 'build/aniyomi-compat/intermediates/compile_library_classes_jar/debug/bundleLibCompileToJarDebug/classes.jar'
$fixtureAndroidJar = Join-Path $SdkPath 'platforms/android-36/android.jar'
$fixtureTools = Join-Path $SdkPath 'build-tools/36.0.0'
foreach ($directory in @($fixtureOutput, $fixtureClasses, $fixtureDex, $fixtureDependencyJars, $fixtureAssets)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
}
if (!(Test-Path -LiteralPath $fixtureCompatJar) -or !(Test-Path -LiteralPath $fixtureUnitClasses)) {
    throw 'Run :aniyomi-compat:testDebugUnitTest before generating these first-party APK fixtures.'
}
$fixtureCache = Join-Path $env:USERPROFILE '.gradle/caches/modules-2/files-2.1'
$fixtureDependencies = @(
    'io.reactivex/rxjava/1.3.8',
    'org.jetbrains.kotlin/kotlin-stdlib/2.3.20',
    'com.squareup.okio/okio-jvm/3.17.0',
    'org.jsoup/jsoup/1.19.1',
    'org.jetbrains.kotlinx/kotlinx-coroutines-core-jvm/1.10.1',
    'org.jetbrains.kotlinx/kotlinx-serialization-core-jvm/1.9.0'
)
$fixtureJars = @($fixtureCompatJar, $fixtureAndroidJar)
foreach ($dependency in $fixtureDependencies) {
    $jar = Get-ChildItem -LiteralPath (Join-Path $fixtureCache $dependency) -Recurse -Filter '*.jar' |
        Where-Object { $_.Name -notmatch 'sources|javadoc' } | Select-Object -First 1
    if (!$jar) { throw "Missing already-verified build dependency: $dependency" }
    $fixtureJars += $jar.FullName
}
$fixtureAarDependencies = @(
    'com.squareup.okhttp3/okhttp-android/5.4.0',
    'app.cash.quickjs/quickjs-android/0.9.2'
)
Add-Type -AssemblyName System.IO.Compression.FileSystem
foreach ($dependency in $fixtureAarDependencies) {
    $aar = Get-ChildItem -LiteralPath (Join-Path $fixtureCache $dependency) -Recurse -Filter '*.aar' |
        Select-Object -First 1
    if (!$aar) { throw "Missing already-verified build dependency: $dependency" }
    $outputJar = Join-Path $fixtureDependencyJars (($dependency -replace '[/\\]', '-') + '-classes.jar')
    $archive = [IO.Compression.ZipFile]::OpenRead($aar.FullName)
    try {
        $entry = $archive.GetEntry('classes.jar')
        if (!$entry) { throw "AAR has no classes.jar: $dependency" }
        [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $outputJar, $true)
    } finally { $archive.Dispose() }
    $fixtureJars += $outputJar
}
$fixtureClasspath = (@($fixtureUnitClasses) + $fixtureJars) -join [IO.Path]::PathSeparator
& javac -source 17 -target 17 -classpath $fixtureClasspath -d $fixtureClasses `
    (Join-Path $PSScriptRoot 'IsolationFixtureAnimeSource.java') (Join-Path $PSScriptRoot 'OfflineFixtureMangaSource.java')
if ($LASTEXITCODE) { throw 'Fixture Java compilation failed' }
$fixtureD8Args = @('--min-api', '26', '--lib', $fixtureAndroidJar, '--output', $fixtureDex)
foreach ($jar in $fixtureJars | Where-Object { $_ -ne $fixtureAndroidJar }) { $fixtureD8Args += @('--classpath', $jar) }
foreach ($name in @('FixtureAnimeSource.class', 'FixtureMangaSource.class', 'FormatHintVideoSource.class')) {
    $fixtureD8Args += Join-Path $fixtureUnitClasses "tetotv/fixture/$name"
}
$fixtureD8Args += @(Get-ChildItem -LiteralPath $fixtureClasses -Recurse -Filter '*.class' | Select-Object -ExpandProperty FullName)
& (Join-Path $fixtureTools 'd8.bat') @fixtureD8Args
if ($LASTEXITCODE) { throw 'Fixture DEX compilation failed' }
foreach ($kind in @('anime', 'manga')) {
    $unsignedApk = Join-Path $fixtureOutput "$kind-unsigned.apk"
    & (Join-Path $fixtureTools 'aapt2.exe') link -o $unsignedApk --manifest (Join-Path $PSScriptRoot "$kind-manifest.xml") -I $fixtureAndroidJar
    if ($LASTEXITCODE) { throw 'Fixture manifest compilation failed' }
    $zip = [IO.Compression.ZipFile]::Open($unsignedApk, [IO.Compression.ZipArchiveMode]::Update)
    try {
        [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, (Join-Path $fixtureDex 'classes.dex'), 'classes.dex') | Out-Null
        [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, (Join-Path $PSScriptRoot 'messages_en.properties'), 'assets/i18n/messages_en.properties') | Out-Null
    }
    finally { $zip.Dispose() }
    if ($kind -eq 'anime') { Copy-Item -LiteralPath $unsignedApk -Destination (Join-Path $fixtureAssets 'aniyomi-fixture-unsigned.apk') -Force }
    $signedApk = Join-Path $fixtureAssets "aniyomi-fixture-$kind.apk"
    & (Join-Path $fixtureTools 'apksigner.bat') sign --ks $DebugKeyStore --ks-pass 'pass:android' --key-pass 'pass:android' --v4-signing-enabled false --out $signedApk $unsignedApk
    if ($LASTEXITCODE) { throw 'Fixture debug signing failed' }
    & (Join-Path $fixtureTools 'apksigner.bat') verify $signedApk
    if ($LASTEXITCODE) { throw 'Generated fixture signature verification failed' }
}
Write-Output 'Generated only first-party androidTest fixture APKs; no providers downloaded or installed.'
