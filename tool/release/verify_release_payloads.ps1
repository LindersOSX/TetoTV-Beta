[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("Beta", "Public")]
    [string]$Channel,

    [Parameter(Mandatory = $true)]
    [string]$ApkPath,

    [Parameter(Mandatory = $true)]
    [string]$NativeSourcePath,

    [Parameter(Mandatory = $true)]
    [string]$ChecksumsPath,

    [Parameter(Mandatory = $true)]
    [string]$ReleaseNotesPath
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$pubspecText = Get-Content -LiteralPath (Join-Path $repositoryRoot "pubspec.yaml") -Raw
$versionMatch = [regex]::Match(
    $pubspecText,
    '(?m)^version:\s*((?<major>[12])\.\d+\.\d+)\+(?<code>\d+)\s*$'
)
if (-not $versionMatch.Success) {
    throw "pubspec.yaml does not contain a supported Public 1.x or Beta 2.x version and Android build code."
}

$versionName = $versionMatch.Groups[1].Value
$versionMajor = [int]$versionMatch.Groups['major'].Value
$buildCode = $versionMatch.Groups['code'].Value
$expectedMajor = if ($Channel -eq "Public") { 1 } else { 2 }
if ($versionMajor -ne $expectedMajor) {
    throw "$Channel releases require a $expectedMajor.x version; pubspec.yaml contains $versionName."
}

$releaseTag = "v$versionName"
$expectedApkName = "TetoTV-$releaseTag-universal.apk"
$expectedNativeSourceName = "TetoTV-$releaseTag-native-playback-sources.zip"
$expectedChecksumsName = "SHA256SUMS"

function Resolve-RequiredFile([string]$Path, [string]$Label) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Label does not exist: $Path"
    }
    return (Resolve-Path -LiteralPath $Path).Path
}

$resolvedApk = Resolve-RequiredFile $ApkPath "Release APK"
$resolvedNativeSource = Resolve-RequiredFile $NativeSourcePath "Native source bundle"
$resolvedChecksums = Resolve-RequiredFile $ChecksumsPath "Checksum manifest"
$resolvedNotes = Resolve-RequiredFile $ReleaseNotesPath "Release notes"

if ([IO.Path]::GetFileName($resolvedApk) -cne $expectedApkName) {
    throw "Expected APK name '$expectedApkName'."
}
if ([IO.Path]::GetFileName($resolvedNativeSource) -cne $expectedNativeSourceName) {
    throw "Expected native source bundle name '$expectedNativeSourceName'."
}
if ([IO.Path]::GetFileName($resolvedChecksums) -cne $expectedChecksumsName) {
    throw "Expected checksum manifest name '$expectedChecksumsName'."
}

$apkInfo = Get-Item -LiteralPath $resolvedApk
$sourceInfo = Get-Item -LiteralPath $resolvedNativeSource
$checksumsInfo = Get-Item -LiteralPath $resolvedChecksums
if ($apkInfo.Length -lt 1MB) {
    throw "The universal APK is implausibly small."
}
if ($sourceInfo.Length -lt 1MB) {
    throw "The native source bundle is implausibly small."
}
if ($checksumsInfo.Length -le 0) {
    throw "SHA256SUMS is empty."
}

& (Join-Path $PSScriptRoot "verify_release_apk.ps1") `
    -ApkPath $resolvedApk `
    -Channel $Channel
& (Join-Path $PSScriptRoot "verify_native_redistribution.ps1") `
    -BundlePath $resolvedNativeSource

$apkSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedApk).Hash.ToLowerInvariant()
$sourceSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedNativeSource).Hash.ToLowerInvariant()
$expectedChecksums = (@(
    "$apkSha256  $expectedApkName"
    "$sourceSha256  $expectedNativeSourceName"
) -join "`n") + "`n"
$actualChecksums = [IO.File]::ReadAllText($resolvedChecksums).Replace("`r`n", "`n")
if ($actualChecksums -cne $expectedChecksums) {
    throw "SHA256SUMS must contain exactly the verified APK and native source bundle digests."
}

$releaseNotesText = Get-Content -LiteralPath $resolvedNotes -Raw
$buildCodeMatches = @(
    [regex]::Matches(
        $releaseNotesText,
        "(?im)<!--\s*tetotv-android-version-code:\s*$([regex]::Escape($buildCode))\s*-->"
    )
)
if ($buildCodeMatches.Count -ne 1) {
    throw "Release notes must contain the Android build-code metadata exactly once."
}
foreach ($assetName in @($expectedApkName, $expectedNativeSourceName, $expectedChecksumsName)) {
    if (-not $releaseNotesText.Contains($assetName)) {
        throw "Release notes must name the exact release asset '$assetName'."
    }
}

Write-Host "Release payload verification passed"
Write-Host "  Channel:       $Channel"
Write-Host "  Tag:           $releaseTag"
Write-Host "  Build code:    $buildCode"
Write-Host "  APK SHA-256:   $apkSha256"
Write-Host "  Source SHA-256: $sourceSha256"
