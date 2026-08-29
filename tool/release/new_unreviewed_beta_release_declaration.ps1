[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ApkPath,

    [Parameter(Mandatory = $true)]
    [string]$NativeSourcePath,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath,

    [Parameter(Mandatory = $true)]
    [switch]$ConfirmNoIndependentNativeLicenseReview,

    [Parameter(Mandatory = $true)]
    [switch]$ConfirmCorrespondingSourceNotIndependentlyReviewed,

    [Parameter(Mandatory = $true)]
    [switch]$AcknowledgeKnownProvenanceLimits,

    [Parameter(Mandatory = $true)]
    [switch]$ConfirmNoGitHubAppsInstalledForRepository
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$manifestPath = Join-Path $PSScriptRoot "native_playback_manifest.json"
$noticePath = Join-Path $repositoryRoot "assets\legal\native\NATIVE_PLAYBACK_NOTICE.txt"
$repository = "LindersOSX/TetoTV-Beta"
$operatorIdentity = "LindersOSX"
$inventoryMethod = "github-repository-settings-installed-github-apps-owner-confirmation"

function Resolve-RequiredFile([string]$Path, [string]$Label) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Label does not exist: $Path"
    }
    return (Resolve-Path -LiteralPath $Path).Path
}

function Get-TextSha256([string]$Value) {
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Value)
        return ([BitConverter]::ToString($algorithm.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant()
    }
    finally {
        $algorithm.Dispose()
    }
}

foreach ($confirmation in @(
    $ConfirmNoIndependentNativeLicenseReview,
    $ConfirmCorrespondingSourceNotIndependentlyReviewed,
    $AcknowledgeKnownProvenanceLimits,
    $ConfirmNoGitHubAppsInstalledForRepository
)) {
    if (-not $confirmation) {
        throw "Every explicit unreviewed-Beta confirmation is required before a declaration can be created."
    }
}

$pubspecText = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot "pubspec.yaml")
$versionMatch = [regex]::Match(
    $pubspecText,
    '(?m)^version:\s*(2\.\d+\.\d+)\+\d+\s*$'
)
if (-not $versionMatch.Success) {
    throw "pubspec.yaml does not contain a supported Beta 2.x release version."
}
$releaseTag = "v$($versionMatch.Groups[1].Value)"

$resolvedApk = Resolve-RequiredFile $ApkPath "Release APK"
$resolvedNativeSource = Resolve-RequiredFile $NativeSourcePath "Native source bundle"
$resolvedManifest = Resolve-RequiredFile $manifestPath "Native playback manifest"
$resolvedNotice = Resolve-RequiredFile $noticePath "Native playback notice"

$expectedApkName = "TetoTV-$releaseTag-universal.apk"
$expectedNativeSourceName = "TetoTV-$releaseTag-native-playback-sources.zip"
if ([IO.Path]::GetFileName($resolvedApk) -cne $expectedApkName) {
    throw "Expected APK name '$expectedApkName'."
}
if ([IO.Path]::GetFileName($resolvedNativeSource) -cne $expectedNativeSourceName) {
    throw "Expected native source bundle name '$expectedNativeSourceName'."
}

$resolvedOutput = [IO.Path]::GetFullPath($OutputPath)
$allowedRoot = [IO.Path]::GetFullPath((Join-Path $repositoryRoot "build\release-compliance"))
if (-not $resolvedOutput.StartsWith(
    $allowedRoot + [IO.Path]::DirectorySeparatorChar,
    [StringComparison]::OrdinalIgnoreCase
)) {
    throw "OutputPath must be a child of $allowedRoot."
}
if (Test-Path -LiteralPath $resolvedOutput) {
    throw "Refusing to overwrite an existing unreviewed Beta declaration: $resolvedOutput"
}

Push-Location $repositoryRoot
try {
    if (git status --porcelain) {
        throw "The working tree must be clean before creating an unreviewed Beta declaration."
    }
    $gitCommit = (& git rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $gitCommit -notmatch '^[0-9a-f]{40}$') {
        throw "Could not resolve the declared Git commit."
    }
    $tagCommit = (& git rev-list -n 1 $releaseTag 2>$null).Trim()
    if ($LASTEXITCODE -ne 0 -or $tagCommit -cne $gitCommit) {
        throw "Local Beta release tag $releaseTag must resolve to the declared Git commit."
    }
}
finally {
    Pop-Location
}

& (Join-Path $PSScriptRoot "verify_native_redistribution.ps1") `
    -BundlePath $resolvedNativeSource `
    -RequireResolvedBinaries

$manifest = Get-Content -Raw -LiteralPath $resolvedManifest | ConvertFrom-Json
$knownLimits = @($manifest.knownProvenanceLimits | ForEach-Object { [string]$_ })
if ($knownLimits.Count -eq 0) {
    throw "native_playback_manifest.json must record at least one provenance limitation."
}
$limitsText = ($knownLimits -join "`n") + "`n"
$limitsHash = Get-TextSha256 $limitsText
$declaredAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")

$declaration = [ordered]@{
    schemaVersion = 1
    statementType = "tetotv-unreviewed-beta-release-declaration"
    releaseTag = $releaseTag
    gitCommit = $gitCommit
    declaredAtUtc = $declaredAtUtc
    operatorIdentity = $operatorIdentity
    independentNativeLicenseReview = $false
    correspondingSourceIndependentlyReviewed = $false
    knownProvenanceLimitsAcknowledged = $true
    knownProvenanceLimitsSha256 = $limitsHash
    githubAppInventory = [ordered]@{
        repository = $repository
        checkedAtUtc = $declaredAtUtc
        reviewMethod = $inventoryMethod
        inventoryComplete = $true
        installations = @()
    }
    artifacts = [ordered]@{
        apkSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedApk).Hash.ToLowerInvariant()
        nativeSourceSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedNativeSource).Hash.ToLowerInvariant()
        nativeManifestSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedManifest).Hash.ToLowerInvariant()
        nativePlaybackNoticeSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedNotice).Hash.ToLowerInvariant()
    }
}

$outputDirectory = Split-Path -Parent $resolvedOutput
if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}
$json = ($declaration | ConvertTo-Json -Depth 5) + "`n"
[IO.File]::WriteAllText($resolvedOutput, $json, [Text.UTF8Encoding]::new($false))

Write-Host "Created unsigned unreviewed Beta release declaration"
Write-Host "  Declaration: $resolvedOutput"
Write-Host "  Operator:    $operatorIdentity"
Write-Host "  Release tag: $releaseTag"
Write-Host "  Git commit:  $gitCommit"
Write-Host "  Declared at: $declaredAtUtc"
Write-Warning "This declaration explicitly records that no independent native-license or corresponding-source review was performed."
Write-Warning "It is not an approval, a legal-compliance determination, or a substitute for qualified review."
Write-Host "No private key, signature, credential, or other private material was requested or written."
