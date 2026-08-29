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
    [string]$ReleaseNotesPath,

    [string]$ResolvedBinaryDirectory = "",

    [string]$NativeLicenseReviewSha256 = "",

    [string]$UnreviewedBetaDeclarationSha256 = ""
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
$nativeVerificationArguments = @{
    BundlePath = $resolvedNativeSource
    # Post-release verification has the final APK and the build provenance
    # embedded in the source bundle, but not TetoTV's intermediate input JARs.
    # A local publisher supplies (or naturally has) those inputs and gets the
    # stronger pre-package check; remote verification is bound to the final
    # APK-native BOM instead.
    RequireResolvedBinaries = -not [string]::IsNullOrWhiteSpace(
        $ResolvedBinaryDirectory
    )
}
if (-not [string]::IsNullOrWhiteSpace($ResolvedBinaryDirectory)) {
    $nativeVerificationArguments.ResolvedBinaryDirectory = $ResolvedBinaryDirectory
}
& (Join-Path $PSScriptRoot "verify_native_redistribution.ps1") @nativeVerificationArguments

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
$hasReviewedEvidence = -not [string]::IsNullOrWhiteSpace($NativeLicenseReviewSha256)
$hasUnreviewedEvidence = -not [string]::IsNullOrWhiteSpace($UnreviewedBetaDeclarationSha256)
if ($hasReviewedEvidence -and $hasUnreviewedEvidence) {
    throw "Release notes cannot contain both reviewed and unreviewed native-license evidence."
}
if ($hasReviewedEvidence) {
    if ($NativeLicenseReviewSha256 -notmatch '^[0-9a-f]{64}$') {
        throw "NativeLicenseReviewSha256 must be a lowercase SHA-256 digest."
    }
    $reviewMarker = "<!-- tetotv-native-license-review-sha256: $NativeLicenseReviewSha256 -->"
    if (@([regex]::Matches($releaseNotesText, [regex]::Escape($reviewMarker))).Count -ne 1) {
        throw "Release notes must contain the exact native-license review digest marker once."
    }
    if (@([regex]::Matches($releaseNotesText, '(?im)<!--\s*tetotv-native-license-review-sha256:')).Count -ne 1) {
        throw "Release notes must not contain another native-license review marker."
    }
    if ($releaseNotesText -match '(?im)tetotv-(?:native-license-review-status:\s*unreviewed-beta|unreviewed-beta-declaration-)') {
        throw "Reviewed release notes must not contain unreviewed Beta evidence."
    }
    $unreviewedDisclosure = "No independent native-license review: This Beta has not received independent native-library licensing review. Automated checks verify the APK, native-source bundle, notices, pinned inputs, and checksums, but do not establish legal compliance or reproducible builds."
    if ($releaseNotesText.Contains($unreviewedDisclosure)) {
        throw "Reviewed release notes must not claim that independent native-license review was not performed."
    }
}
if ($hasUnreviewedEvidence) {
    if ($Channel -cne "Beta") {
        throw "Unreviewed native-license evidence is permitted only for the Beta channel."
    }
    if ($UnreviewedBetaDeclarationSha256 -notmatch '^[0-9a-f]{64}$') {
        throw "UnreviewedBetaDeclarationSha256 must be a lowercase SHA-256 digest."
    }
    if ($releaseNotesText -match '(?im)<!--\s*tetotv-native-license-review-(?:sha256|attestation-base64|signature-base64):') {
        throw "Unreviewed Beta release notes must not contain qualified-review evidence."
    }
    $disclosure = "No independent native-license review: This Beta has not received independent native-library licensing review. Automated checks verify the APK, native-source bundle, notices, pinned inputs, and checksums, but do not establish legal compliance or reproducible builds."
    $visibleWarningPrefix = "# TetoTV $versionName Beta`n`n> [!WARNING]`n> $disclosure`n"
    $normalizedReleaseNotesText = $releaseNotesText.Replace("`r`n", "`n")
    if (
        @([regex]::Matches($normalizedReleaseNotesText, [regex]::Escape($disclosure))).Count -ne 1 -or
        -not $normalizedReleaseNotesText.StartsWith(
            $visibleWarningPrefix,
            [StringComparison]::Ordinal
        )
    ) {
        throw "Unreviewed Beta release notes must begin with the exact visible warning block."
    }
    $statusMarker = "<!-- tetotv-native-license-review-status: unreviewed-beta -->"
    if (@([regex]::Matches($releaseNotesText, [regex]::Escape($statusMarker))).Count -ne 1) {
        throw "Unreviewed Beta release notes must contain the exact status marker once."
    }
    if (@([regex]::Matches($releaseNotesText, '(?im)<!--\s*tetotv-native-license-review-status:')).Count -ne 1) {
        throw "Unreviewed Beta release notes must not contain another review-status marker."
    }
    $declarationMarker = "<!-- tetotv-unreviewed-beta-declaration-sha256: $UnreviewedBetaDeclarationSha256 -->"
    if (@([regex]::Matches($releaseNotesText, [regex]::Escape($declarationMarker))).Count -ne 1) {
        throw "Release notes must contain the exact unreviewed Beta declaration digest marker once."
    }
    if (@([regex]::Matches($releaseNotesText, '(?im)<!--\s*tetotv-unreviewed-beta-declaration-sha256:')).Count -ne 1) {
        throw "Release notes must not contain another unreviewed Beta declaration marker."
    }
    if (@([regex]::Matches(
        $releaseNotesText,
        '(?im)<!--\s*tetotv-unreviewed-beta-declaration-base64:\s*[A-Za-z0-9+/]+={0,2}\s*-->'
    )).Count -ne 1 -or @([regex]::Matches(
        $releaseNotesText,
        '(?im)<!--\s*tetotv-unreviewed-beta-declaration-base64:'
    )).Count -ne 1) {
        throw "Unreviewed Beta release notes must contain exactly one encoded declaration."
    }
}

Write-Host "Release payload verification passed"
Write-Host "  Channel:       $Channel"
Write-Host "  Tag:           $releaseTag"
Write-Host "  Build code:    $buildCode"
Write-Host "  APK SHA-256:   $apkSha256"
Write-Host "  Source SHA-256: $sourceSha256"
