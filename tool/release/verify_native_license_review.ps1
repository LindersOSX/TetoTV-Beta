[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$AttestationPath,

    [string]$SignaturePath = "",

    [Parameter(Mandatory = $true)]
    [string]$ReleaseTag,

    [Parameter(Mandatory = $true)]
    [string]$GitCommit,

    [Parameter(Mandatory = $true)]
    [string]$ApkPath,

    [Parameter(Mandatory = $true)]
    [string]$NativeSourcePath
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$manifestPath = Join-Path $PSScriptRoot "native_playback_manifest.json"
$noticePath = Join-Path $repositoryRoot "assets\legal\native\NATIVE_PLAYBACK_NOTICE.txt"
$allowedSignersPath = Join-Path $PSScriptRoot "qualified_native_license_reviewers.allowed_signers"
$namespace = "tetotv-native-license-review"

function Resolve-RequiredFile([string]$Path, [string]$Label) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Label does not exist: $Path"
    }
    return (Resolve-Path -LiteralPath $Path).Path
}

function Assert-ExactProperties(
    [object]$Value,
    [string[]]$Expected,
    [string]$Label
) {
    if ($null -eq $Value) { throw "$Label is missing." }
    $actual = @($Value.PSObject.Properties.Name | Sort-Object)
    $wanted = @($Expected | Sort-Object)
    if ($actual.Count -ne $wanted.Count -or (Compare-Object $wanted $actual)) {
        throw "$Label must contain exactly: $($Expected -join ', ')."
    }
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

function Invoke-SshReviewVerification(
    [string]$MessagePath,
    [string]$ReviewSignaturePath,
    [string]$ReviewerIdentity
) {
    $sshKeygen = Get-Command ssh-keygen -ErrorAction SilentlyContinue
    if ($null -eq $sshKeygen) {
        throw "OpenSSH ssh-keygen is required to verify the native-license review signature."
    }

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $sshKeygen.Source
    $startInfo.Arguments = (
        '-Y verify -f "{0}" -I "{1}" -n "{2}" -s "{3}"' -f
            $allowedSignersPath.Replace('"', '\"'),
            $ReviewerIdentity.Replace('"', '\"'),
            $namespace,
            $ReviewSignaturePath.Replace('"', '\"')
    )
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        throw "Could not start ssh-keygen for native-license review verification."
    }
    try {
        $input = [IO.File]::OpenRead($MessagePath)
        try {
            $input.CopyTo($process.StandardInput.BaseStream)
        }
        finally {
            $input.Dispose()
            $process.StandardInput.Close()
        }
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) {
            $details = (($stdout, $stderr) -join "`n").Trim()
            throw "Native-license review SSH signature is not valid for allowlisted reviewer '$ReviewerIdentity'.`n$details"
        }
    }
    finally {
        $process.Dispose()
    }
}

$resolvedAttestation = Resolve-RequiredFile $AttestationPath "Native-license review attestation"
if ([string]::IsNullOrWhiteSpace($SignaturePath)) {
    $SignaturePath = "$resolvedAttestation.sig"
}
$resolvedSignature = Resolve-RequiredFile $SignaturePath "Native-license review SSH signature"
$resolvedApk = Resolve-RequiredFile $ApkPath "Release APK"
$resolvedNativeSource = Resolve-RequiredFile $NativeSourcePath "Native source bundle"
$resolvedManifest = Resolve-RequiredFile $manifestPath "Native playback manifest"
$resolvedNotice = Resolve-RequiredFile $noticePath "Native playback notice"
$resolvedAllowedSigners = Resolve-RequiredFile $allowedSignersPath "Qualified-reviewer allowlist"

if ($ReleaseTag -notmatch '^v(?:1|2)\.\d+\.\d+$') {
    throw "ReleaseTag must be a canonical Public v1.x.y or Beta v2.x.y tag."
}
if ($GitCommit -notmatch '^[0-9a-f]{40}$') {
    throw "GitCommit must be the lowercase full Git commit ID."
}

try {
    $attestation = Get-Content -Raw -LiteralPath $resolvedAttestation | ConvertFrom-Json
}
catch {
    throw "Native-license review attestation is not valid JSON: $($_.Exception.Message)"
}

Assert-ExactProperties $attestation @(
    "schemaVersion",
    "statementType",
    "releaseTag",
    "gitCommit",
    "reviewedAtUtc",
    "reviewerIdentity",
    "reviewerRole",
    "decision",
    "qualifiedReviewer",
    "correspondingSourceReviewed",
    "knownProvenanceLimitsAcknowledged",
    "knownProvenanceLimitsSha256",
    "githubAppInventory",
    "artifacts"
) "Native-license review attestation"
Assert-ExactProperties $attestation.githubAppInventory @(
    "repository",
    "checkedAtUtc",
    "reviewMethod",
    "inventoryComplete",
    "installations"
) "GitHub App installation inventory"
Assert-ExactProperties $attestation.artifacts @(
    "apkSha256",
    "nativeSourceSha256",
    "nativeManifestSha256",
    "nativePlaybackNoticeSha256"
) "Native-license review artifact binding"

if (
    $attestation.schemaVersion -isnot [int] -and
    $attestation.schemaVersion -isnot [long]
) {
    throw "schemaVersion must be a JSON integer."
}
if ([long]$attestation.schemaVersion -ne 2) {
    throw "Unsupported native-license review attestation schema."
}
if ([string]$attestation.statementType -cne "tetotv-native-license-review") {
    throw "Unexpected native-license review statement type."
}
if ([string]$attestation.releaseTag -cne $ReleaseTag) {
    throw "Native-license review was not approved for release tag $ReleaseTag."
}
if ([string]$attestation.gitCommit -cne $GitCommit) {
    throw "Native-license review was not approved for Git commit $GitCommit."
}
if ([string]$attestation.decision -cne "approved") {
    throw "Native-license review decision must be exactly 'approved'."
}
foreach ($confirmationName in @(
    "qualifiedReviewer",
    "correspondingSourceReviewed",
    "knownProvenanceLimitsAcknowledged"
)) {
    $confirmation = $attestation.$confirmationName
    if ($confirmation -isnot [bool] -or $confirmation -ne $true) {
        throw "A qualified reviewer must explicitly approve corresponding source and acknowledge every recorded provenance limit."
    }
}
if (
    $attestation.qualifiedReviewer -ne $true -or
    $attestation.correspondingSourceReviewed -ne $true -or
    $attestation.knownProvenanceLimitsAcknowledged -ne $true
) {
    throw "A qualified reviewer must explicitly approve corresponding source and acknowledge every recorded provenance limit."
}

$reviewerIdentity = [string]$attestation.reviewerIdentity
if ($reviewerIdentity -notmatch '^[A-Za-z0-9][A-Za-z0-9._@+-]{2,127}$') {
    throw "reviewerIdentity must be a stable exact principal with no whitespace or wildcard characters."
}
$reviewerRole = [string]$attestation.reviewerRole
if ([string]::IsNullOrWhiteSpace($reviewerRole) -or $reviewerRole.Length -gt 160) {
    throw "reviewerRole must identify the reviewer's qualification in 160 characters or fewer."
}

$reviewedAtText = [string]$attestation.reviewedAtUtc
if ($reviewedAtText -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$') {
    throw "reviewedAtUtc must use UTC form YYYY-MM-DDTHH:MM:SSZ."
}
$reviewedAt = [DateTimeOffset]::ParseExact(
    $reviewedAtText,
    "yyyy-MM-dd'T'HH:mm:ss'Z'",
    [Globalization.CultureInfo]::InvariantCulture,
    [Globalization.DateTimeStyles]::AssumeUniversal
)
$now = [DateTimeOffset]::UtcNow
if ($reviewedAt -gt $now.AddMinutes(5) -or $reviewedAt -lt $now.AddDays(-30)) {
    throw "Native-license review must be completed within 30 days before publication and cannot be future-dated."
}

$appInventory = $attestation.githubAppInventory
if ([string]$appInventory.repository -cne "LindersOSX/TetoTV-Beta") {
    throw "GitHub App inventory must cover the exact Beta release repository."
}
if (
    [string]$appInventory.reviewMethod -cne
        "github-repository-settings-installed-github-apps"
) {
    throw "GitHub App inventory must be completed from the repository's Installed GitHub Apps settings page."
}
if (
    $appInventory.inventoryComplete -isnot [bool] -or
    $appInventory.inventoryComplete -ne $true
) {
    throw "GitHub App inventory must be explicitly marked complete."
}
if (@($appInventory.installations).Count -ne 0) {
    throw "Publication is blocked while any GitHub App is installed for the Beta repository."
}
$appInventoryCheckedAtText = [string]$appInventory.checkedAtUtc
if ($appInventoryCheckedAtText -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$') {
    throw "GitHub App inventory checkedAtUtc must use UTC form YYYY-MM-DDTHH:MM:SSZ."
}
$appInventoryCheckedAt = [DateTimeOffset]::ParseExact(
    $appInventoryCheckedAtText,
    "yyyy-MM-dd'T'HH:mm:ss'Z'",
    [Globalization.CultureInfo]::InvariantCulture,
    [Globalization.DateTimeStyles]::AssumeUniversal
)
if (
    $appInventoryCheckedAt -gt $now.AddMinutes(5) -or
    $appInventoryCheckedAt -lt $now.AddHours(-24) -or
    $appInventoryCheckedAt -ne $reviewedAt
) {
    throw "The signed empty GitHub App inventory must be completed with this review within 24 hours before publication."
}

$manifest = Get-Content -Raw -LiteralPath $resolvedManifest | ConvertFrom-Json
$limitsText = ((@($manifest.knownProvenanceLimits) | ForEach-Object { [string]$_ }) -join "`n") + "`n"
$expectedLimitsHash = Get-TextSha256 $limitsText
if ([string]$attestation.knownProvenanceLimitsSha256 -cne $expectedLimitsHash) {
    throw "Native-license review does not acknowledge the exact provenance-limit set in native_playback_manifest.json."
}

$expectedArtifacts = @{
    apkSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedApk).Hash.ToLowerInvariant()
    nativeSourceSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedNativeSource).Hash.ToLowerInvariant()
    nativeManifestSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedManifest).Hash.ToLowerInvariant()
    nativePlaybackNoticeSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedNotice).Hash.ToLowerInvariant()
}
foreach ($name in $expectedArtifacts.Keys) {
    $actual = [string]$attestation.artifacts.$name
    if ($actual -notmatch '^[0-9a-f]{64}$' -or $actual -cne $expectedArtifacts[$name]) {
        throw "Native-license review artifact binding mismatch: $name."
    }
}

$activeSignerLines = @(
    Get-Content -LiteralPath $resolvedAllowedSigners |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith('#') }
)
if ($activeSignerLines.Count -eq 0) {
    throw "No qualified native-license reviewer key is allowlisted. Publication is intentionally blocked until an independently verified reviewer key is added."
}
$matchingSignerLines = @($activeSignerLines | Where-Object {
    $principalField = ($_ -split '\s+', 2)[0]
    $principalField -ceq $reviewerIdentity
})
if ($matchingSignerLines.Count -ne 1) {
    throw "reviewerIdentity '$reviewerIdentity' must match exactly one allowlisted signing principal."
}
if (($matchingSignerLines[0] -split '\s+', 2)[0] -match '[*?]') {
    throw "Wildcard reviewer principals are not permitted in the qualified-reviewer allowlist."
}

Invoke-SshReviewVerification `
    -MessagePath $resolvedAttestation `
    -ReviewSignaturePath $resolvedSignature `
    -ReviewerIdentity $reviewerIdentity

$attestationSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedAttestation).Hash.ToLowerInvariant()
Write-Host "Native-license review verification passed"
Write-Host "  Reviewer identity: $reviewerIdentity"
Write-Host "  Release tag:       $ReleaseTag"
Write-Host "  Git commit:        $GitCommit"
Write-Host "  Attestation SHA-256: $attestationSha256"
