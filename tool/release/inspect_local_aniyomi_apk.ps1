[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$ApkPath,
    [Parameter(Mandatory = $true)] [string]$MappingPath,
    [Parameter(Mandatory = $true)] [string]$SourceApiReferencePath,
    [string]$AndroidSdkPath = "$env:LOCALAPPDATA/Android/Sdk",
    # Test only the DEX contracts of an already-built minified debug APK.
    # This mode does NOT claim release/signing/manifest/native-BOM verification.
    [switch]$DexOnly,
    [ValidateRange(0, 4)] [int]$ExpectedAppOwnedChanges = 0
)

# Read-only supplemental inspection of an unpublished local APK. This does not
# replace or relax verify_release_apk.ps1, its BOM, or any publication gate.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$inspectionRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$inspectionApk = (Resolve-Path -LiteralPath $ApkPath).Path
$inspectionMapping = Get-Content -LiteralPath (Resolve-Path -LiteralPath $MappingPath).Path -Raw
$inspectionReference = Get-Content -LiteralPath (Resolve-Path -LiteralPath $SourceApiReferencePath).Path -Raw
$inspectionAnalyzer = Join-Path $AndroidSdkPath 'cmdline-tools/latest/bin/apkanalyzer.bat'
$inspectionSigner = Join-Path $AndroidSdkPath 'build-tools/36.0.0/apksigner.bat'

function Invoke-InspectionTool([string]$Tool, [string[]]$Arguments) {
    if (!(Test-Path -LiteralPath $Tool -PathType Leaf)) { throw "Missing SDK tool: $Tool" }
    $toolOutput = & $Tool @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "SDK inspection failed: $($Arguments[0]) $($Arguments[1])" }
    return ($toolOutput | ForEach-Object { $_.ToString() }) -join "`n"
}

function Resolve-MappedType([string]$Original) {
    $match = [regex]::Match($inspectionMapping, '(?m)^' + [regex]::Escape($Original) + ' -> ([^:\r\n]+):')
    if (!$match.Success) { throw "Required mapping absent: $Original" }
    return $match.Groups[1].Value
}

function Read-DexType([string]$Type) {
    return Invoke-InspectionTool $inspectionAnalyzer @('dex', 'code', '--class', $Type, $inspectionApk)
}

function Get-SourceApiSymbols([string]$Listing) {
    $symbols = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($match in [regex]::Matches($Listing, '(?m)^([CMF]) d \d+\s+\d+\s+\d+\s+(eu\.kanade\.tachiyomi\.[^\r\n]+)\r?$')) {
        $symbol = $match.Groups[2].Value
        # R8/D8 implementation artifacts are not source API contracts.
        if ($symbol -match '\$\$ExternalSynthetic|\$r8\$|write\$Self\$aniyomi_compat_(debug|release)\(') { continue }
        [void]$symbols.Add($match.Groups[1].Value + ' ' + $symbol)
    }
    return ,$symbols
}

$mapIdMatch = [regex]::Match($inspectionMapping, '(?m)^# pg_map_id: ([0-9a-f]{64})\r?$')
if (!$mapIdMatch.Success) { throw 'Mapping has no recognized R8 map ID' }
$mappingId = $mapIdMatch.Groups[1].Value
$runtimeCode = Read-DexType (Resolve-MappedType 'dev.animetv.anime_tv.aniyomi.compat.AniyomiCompatRuntime')
$mappingBound = $runtimeCode.Contains('r8-map-id-' + $mappingId)
if (!$DexOnly -and !$mappingBound) { throw 'Final APK source map ID does not match the supplied release mapping' }

$requiredRegistrationTypes = @(
    'android/app/Application',
    'eu/kanade/tachiyomi/network/NetworkHelper',
    'eu/kanade/tachiyomi/network/JavaScriptEngine',
    'kotlinx/serialization/json/Json'
)
# Kotlin numbers these anonymous inlined type tokens according to source order.
# Do not assign an ABI meaning to `$1`, `$2`, and so on: adding another valid
# registration would otherwise make the release gate report a false R8 failure.
$registrationPrefix = 'dev.animetv.anime_tv.aniyomi.compat.AniyomiCompatRuntime$executeChecked$$inlined$addSingleton$'
$registrationMatches = [regex]::Matches(
    $inspectionMapping,
    '(?m)^' + [regex]::Escape($registrationPrefix) + '\d+ -> ([^:\r\n]+):\r?$'
)
if ($registrationMatches.Count -eq 0) { throw 'Injekt generic registration mappings are absent' }
$registrationTypes = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($registrationMatch in $registrationMatches) {
    $mappedType = $registrationMatch.Groups[1].Value
    $code = Read-DexType $mappedType
    $signature = [regex]::Match($code, '(?s)\.annotation system Ldalvik/annotation/Signature;.*?\.end annotation').Value
    $genericType = [regex]::Match(
        $signature,
        '"Luy/kohesive/injekt/api/FullTypeReference<",\s*"L([^";]+);",\s*">;"'
    )
    if (!$genericType.Success) {
        throw "Injekt generic registration signature missing or malformed: $mappedType"
    }
    if (!$registrationTypes.Add($genericType.Groups[1].Value)) {
        throw "Duplicate Injekt generic registration: $($genericType.Groups[1].Value)"
    }
}
$missingRegistrationTypes = @($requiredRegistrationTypes | Where-Object { !$registrationTypes.Contains($_) })
$unexpectedRegistrationTypes = @($registrationTypes | Where-Object { $_ -notin $requiredRegistrationTypes })
if ($missingRegistrationTypes.Count -ne 0 -or $unexpectedRegistrationTypes.Count -ne 0) {
    throw "Injekt generic registrations differ from the reviewed runtime (missing: $($missingRegistrationTypes -join ', '); unexpected: $($unexpectedRegistrationTypes -join ', '))"
}

$asn1Models = @('com.android.apksig.internal.x509.SubjectPublicKeyInfo',
    'com.android.apksig.internal.x509.RSAPublicKey', 'com.android.apksig.internal.pkcs7.AlgorithmIdentifier')
foreach ($model in $asn1Models) {
    $code = Read-DexType $model
    if ($code -notmatch 'annotation runtime Lcom/android/apksig/internal/asn1/Asn1Class;' -or
        [regex]::Matches($code, 'annotation runtime Lcom/android/apksig/internal/asn1/Asn1Field;').Count -ne 2 -or
        $code -notmatch '\.method public constructor <init>\(\)V') {
        throw "apksig reflective ASN.1 model contract missing: $model"
    }
}
foreach ($annotation in @('Asn1Class', 'Asn1Field')) {
    $code = Read-DexType ('com.android.apksig.internal.asn1.' + $annotation)
    if ($code -notmatch '^\.class .*annotation ' -or $code -notmatch 'Ljava/lang/annotation/RetentionPolicy;->RUNTIME:') {
        throw "apksig annotation type/runtime retention missing: $annotation"
    }
}

$defined = Invoke-InspectionTool $inspectionAnalyzer @('dex', 'packages', '--defined-only', $inspectionApk)
$expectedApi = Get-SourceApiSymbols $inspectionReference
$actualApi = Get-SourceApiSymbols $defined
if ($expectedApi.Count -lt 1600) { throw 'Source API reference is incomplete or not a recognized defined-only SDK listing' }
$missingApi = @($expectedApi | Where-Object { !$actualApi.Contains($_) })
if ($missingApi.Count -ne 0) { throw "Missing source API contracts ($($missingApi.Count)): $($missingApi -join '; ')" }
foreach ($type in @('eu.kanade.tachiyomi.animesource.AnimeSource$DefaultImpls',
    'eu.kanade.tachiyomi.animesource.AnimeCatalogueSource$DefaultImpls',
    'eu.kanade.tachiyomi.source.Source$DefaultImpls', 'eu.kanade.tachiyomi.source.CatalogueSource$DefaultImpls')) {
    if (!$actualApi.Contains('C ' + $type)) { throw "Legacy default bridge missing: $type" }
}
$videoCode = Read-DexType 'eu.kanade.tachiyomi.animesource.model.Video'
if (!$videoCode.Contains('<init>(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Lokhttp3/Headers;Ljava/util/List;Ljava/util/List;)V')) {
    throw 'Legacy six-argument Video constructor missing'
}
$realCallCode = Read-DexType 'okhttp3.internal.connection.RealCall'
if (!$realCallCode.Contains('getClient()Lokhttp3/OkHttpClient;')) { throw 'Pinned broker RealCall.client ABI missing' }

$report = [ordered]@{
    mode = $(if ($DexOnly) { 'DEX contracts only; not release verification' } else { 'Local unpublished release supplemental inspection' })
    apk = $inspectionApk
    sha256 = (Get-FileHash -LiteralPath $inspectionApk -Algorithm SHA256).Hash.ToLowerInvariant()
    bytes = (Get-Item -LiteralPath $inspectionApk).Length
    mappingId = $mappingId
    sourceApiReferenceSha256 = (Get-FileHash -LiteralPath $SourceApiReferencePath -Algorithm SHA256).Hash.ToLowerInvariant()
    mappingBoundToApkSourceAttribute = $mappingBound
    injektGenericRegistrations = $registrationTypes.Count
    asn1Models = $asn1Models.Count
    sourceApiReferenceContracts = $expectedApi.Count
    missingSourceApiContracts = 0
    legacyVideoAndDefaultImpls = 'retained'
    brokerRealCallClient = 'retained'
}
if ($DexOnly) { $report | ConvertTo-Json -Depth 6; return }

$manifestXml = Invoke-InspectionTool $inspectionAnalyzer @('manifest', 'print', $inspectionApk)
$manifest = [Xml.XmlDocument]::new()
$manifest.XmlResolver = $null
$manifest.LoadXml($manifestXml)
$androidNs = 'http://schemas.android.com/apk/res/android'
$application = $manifest.SelectSingleNode('/manifest/application')
if ($null -eq $application) { throw 'Application manifest missing' }
foreach ($flag in @('debuggable', 'testOnly')) {
    if ($application.GetAttribute($flag, $androidNs) -notin @('', 'false')) { throw "Unsafe release flag: $flag" }
}
if ($application.GetAttribute('allowBackup', $androidNs) -ne 'false') { throw 'Release backup restriction missing' }
if ($manifest.SelectNodes('/manifest/instrumentation').Count -ne 0) { throw 'Release contains instrumentation' }
$workers = @($manifest.SelectNodes('/manifest/application/service') | Where-Object {
    $_.GetAttribute('name', $androidNs) -in @('.aniyomi.AniyomiIsolatedService', 'dev.animetv.anime_tv.aniyomi.AniyomiIsolatedService')
})
if ($workers.Count -ne 1) { throw 'Expected exactly one isolated Aniyomi service' }
foreach ($entry in @{ exported='false'; isolatedProcess='true'; stopWithTask='true'; process=':aniyomi_worker' }.GetEnumerator()) {
    if ($workers[0].GetAttribute($entry.Key, $androidNs) -ne $entry.Value) { throw "Worker manifest contract differs: $($entry.Key)" }
}
if ($defined -match '(?m)^C d [^\r\n]*dev\.animetv\.anime_tv\.aniyomi\.[^\r\n]*(Fixture|Instrumentation|Test)') {
    throw 'Release DEX contains Aniyomi test/fixture classes'
}
$version = [regex]::Match((Get-Content -LiteralPath (Join-Path $inspectionRoot 'pubspec.yaml') -Raw), '(?m)^version:\s*([^+\s]+)\+(\d+)\s*$')
if (!$version.Success -or $manifest.DocumentElement.GetAttribute('package') -ne 'dev.animetv.anime_tv' -or
    $manifest.DocumentElement.GetAttribute('versionName', $androidNs) -ne $version.Groups[1].Value -or
    $manifest.DocumentElement.GetAttribute('versionCode', $androidNs) -ne $version.Groups[2].Value -or
    $manifest.SelectSingleNode('/manifest/uses-sdk').GetAttribute('minSdkVersion', $androidNs) -ne '24') {
    throw 'Release package/version/minimum SDK differs from expected app identity'
}
$signer = Invoke-InspectionTool $inspectionSigner @('verify', '--verbose', '--print-certs', $inspectionApk)
$certificates = [regex]::Matches($signer, '(?im)^Signer #\d+ certificate SHA-256 digest: ([0-9a-f]{64})\r?$')
if ($certificates.Count -ne 1 -or $certificates[0].Groups[1].Value -ne '008ef69468023edcf1009d2ae999ef57d91e5411ff62bd37194fd91fad12fb5c') {
    throw 'APK does not have the single pinned production signer'
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$bom = Get-Content -LiteralPath (Join-Path $inspectionRoot 'tool/release/native_playback_manifest.json') -Raw | ConvertFrom-Json
$owned = @('lib/arm64-v8a/libapp.so', 'lib/armeabi-v7a/libapp.so',
    'lib/arm64-v8a/libtetotv_discord.so', 'lib/armeabi-v7a/libtetotv_discord.so')
$archive = [IO.Compression.ZipFile]::OpenRead($inspectionApk)
$changedOwned = @()
$pinnedCount = 0
try {
    if (@($archive.Entries | Where-Object { $_.FullName -match '(?i)\.apk$|aniyomi-fixture|authorized-animegg' }).Count -ne 0) {
        throw 'Release contains an embedded APK or named test fixture asset'
    }
    $native = @($archive.Entries | Where-Object { $_.FullName -match '^lib/[^/]+/[^/]+\.so$' })
    $expectedNative = @($bom.apkNativeLibraries)
    if ($native.Count -ne 20 -or $expectedNative.Count -ne 20 -or
        @(Compare-Object @($expectedNative | ForEach-Object path) @($native | ForEach-Object FullName)).Count -ne 0) {
        throw 'Native APK entries differ from the 20-entry ARM universal BOM'
    }
    foreach ($expected in $expectedNative) {
        $entry = $native | Where-Object FullName -CEQ $expected.path | Select-Object -First 1
        $stream = $entry.Open()
        $algorithm = [Security.Cryptography.SHA256]::Create()
        try { $hash = ([BitConverter]::ToString($algorithm.ComputeHash($stream)) -replace '-', '').ToLowerInvariant() }
        finally { $stream.Dispose(); $algorithm.Dispose() }
        $changed = $hash -cne $expected.sha256 -or $entry.Length -ne $expected.size
        if ($expected.path -in $owned) {
            if ($changed) { $changedOwned += [pscustomobject]@{ path=$expected.path; size=$entry.Length; sha256=$hash } }
        } else {
            if ($changed) { throw "Pinned native library changed: $($expected.path)" }
            $pinnedCount++
        }
    }
} finally { $archive.Dispose() }
if ($pinnedCount -ne 16 -or $changedOwned.Count -ne $ExpectedAppOwnedChanges) { throw 'Unexpected pinned/app-owned native change counts' }
$report.version = $version.Groups[1].Value + ' (' + $version.Groups[2].Value + ')'
$report.isolatedNonexportedWorker = $true
$report.releaseFlagsAndFixtureExclusion = 'passed'
$report.productionSigner = $certificates[0].Groups[1].Value
$report.nativeEntries = 20
$report.pinnedNativeUnchanged = $pinnedCount
$report.appOwnedNativeChanges = $changedOwned
$report.publicationEligibility = 'Not established: original published-BOM verifier remains unchanged and intentionally fails for changed app-owned local binaries'
$report | ConvertTo-Json -Depth 6
