[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ApkPath,

    [Parameter(Mandatory = $true)]
    [string]$NativeSourcePath,

    [Parameter(Mandatory = $true)]
    [string]$ReviewerIdentity,

    [Parameter(Mandatory = $true)]
    [string]$ReviewerRole,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath,

    [Parameter(Mandatory = $true)]
    [switch]$Approve,

    [Parameter(Mandatory = $true)]
    [switch]$ConfirmQualifiedReviewer,

    [Parameter(Mandatory = $true)]
    [switch]$ConfirmCorrespondingSourceReviewed,

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
$pubspecText = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot "pubspec.yaml")
$versionMatch = [regex]::Match($pubspecText, '(?m)^version:\s*((?:1|2)\.\d+\.\d+)\+\d+\s*$')
if (-not $versionMatch.Success) {
    throw "pubspec.yaml does not contain a supported release version."
}
$releaseTag = "v$($versionMatch.Groups[1].Value)"

if ($ReviewerIdentity -notmatch '^[A-Za-z0-9][A-Za-z0-9._@+-]{2,127}$') {
    throw "ReviewerIdentity must be a stable exact principal with no whitespace or wildcard characters."
}
if ([string]::IsNullOrWhiteSpace($ReviewerRole) -or $ReviewerRole.Length -gt 160) {
    throw "ReviewerRole must identify the reviewer's qualification in 160 characters or fewer."
}
foreach ($confirmation in @(
    $Approve,
    $ConfirmQualifiedReviewer,
    $ConfirmCorrespondingSourceReviewed,
    $AcknowledgeKnownProvenanceLimits,
    $ConfirmNoGitHubAppsInstalledForRepository
)) {
    if (-not $confirmation) {
        throw "All explicit review confirmations are required before an approved attestation can be created."
    }
}

$resolvedApk = (Resolve-Path -LiteralPath $ApkPath).Path
$resolvedNativeSource = (Resolve-Path -LiteralPath $NativeSourcePath).Path
$resolvedOutput = [IO.Path]::GetFullPath($OutputPath)
$allowedRoot = [IO.Path]::GetFullPath((Join-Path $repositoryRoot "build\release-compliance"))
if (-not $resolvedOutput.StartsWith($allowedRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw "OutputPath must be a child of $allowedRoot."
}
if (Test-Path -LiteralPath $resolvedOutput) {
    throw "Refusing to overwrite an existing review attestation: $resolvedOutput"
}

Push-Location $repositoryRoot
try {
    if (git status --porcelain) {
        throw "The working tree must be clean before creating a native-license review attestation."
    }
    $gitCommit = (& git rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $gitCommit -notmatch '^[0-9a-f]{40}$') {
        throw "Could not resolve the reviewed Git commit."
    }
    $tagCommit = (& git rev-list -n 1 $releaseTag 2>$null).Trim()
    if ($LASTEXITCODE -ne 0 -or $tagCommit -cne $gitCommit) {
        throw "Local release tag $releaseTag must resolve to the reviewed Git commit."
    }
}
finally {
    Pop-Location
}

& (Join-Path $PSScriptRoot "verify_native_redistribution.ps1") `
    -BundlePath $resolvedNativeSource `
    -RequireResolvedBinaries

$manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
$limitsText = ((@($manifest.knownProvenanceLimits) | ForEach-Object { [string]$_ }) -join "`n") + "`n"
$algorithm = [Security.Cryptography.SHA256]::Create()
try {
    $limitsHash = ([BitConverter]::ToString(
        $algorithm.ComputeHash([Text.UTF8Encoding]::new($false).GetBytes($limitsText))
    ) -replace '-', '').ToLowerInvariant()
}
finally {
    $algorithm.Dispose()
}

$reviewedAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
$statement = [ordered]@{
    schemaVersion = 2
    statementType = "tetotv-native-license-review"
    releaseTag = $releaseTag
    gitCommit = $gitCommit
    reviewedAtUtc = $reviewedAtUtc
    reviewerIdentity = $ReviewerIdentity
    reviewerRole = $ReviewerRole
    decision = "approved"
    qualifiedReviewer = $true
    correspondingSourceReviewed = $true
    knownProvenanceLimitsAcknowledged = $true
    knownProvenanceLimitsSha256 = $limitsHash
    githubAppInventory = [ordered]@{
        repository = "LindersOSX/TetoTV-Beta"
        checkedAtUtc = $reviewedAtUtc
        reviewMethod = "github-repository-settings-installed-github-apps"
        inventoryComplete = $true
        installations = @()
    }
    artifacts = [ordered]@{
        apkSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedApk).Hash.ToLowerInvariant()
        nativeSourceSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedNativeSource).Hash.ToLowerInvariant()
        nativeManifestSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $manifestPath).Hash.ToLowerInvariant()
        nativePlaybackNoticeSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $noticePath).Hash.ToLowerInvariant()
    }
}

$outputDirectory = Split-Path -Parent $resolvedOutput
if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}
$json = ($statement | ConvertTo-Json -Depth 5) + "`n"
[IO.File]::WriteAllText($resolvedOutput, $json, [Text.UTF8Encoding]::new($false))

Write-Host "Created unsigned native-license review attestation: $resolvedOutput"
Write-Host "A qualified reviewer must sign these exact bytes with an allowlisted SSH key:"
Write-Host "  ssh-keygen -Y sign -f <private-key-path> -n tetotv-native-license-review `"$resolvedOutput`""
Write-Host "The expected detached signature path is: $resolvedOutput.sig"
Write-Warning "This attestation records review evidence; it is not legal advice or a claim of license compliance."
