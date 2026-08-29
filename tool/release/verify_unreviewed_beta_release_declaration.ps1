[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$DeclarationPath,

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
$repository = "LindersOSX/TetoTV-Beta"
$operatorIdentity = "LindersOSX"
$inventoryMethod = "github-repository-settings-installed-github-apps-owner-confirmation"

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
    if ($null -eq $Value) {
        throw "$Label is missing."
    }
    $actual = @($Value.PSObject.Properties.Name | Sort-Object)
    $wanted = @($Expected | Sort-Object)
    if (
        $actual.Count -ne $wanted.Count -or
        (Compare-Object -CaseSensitive $wanted $actual)
    ) {
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

function Get-CanonicalUtcJsonString(
    [string]$Json,
    [string]$PropertyName,
    [string]$Label
) {
    # ConvertFrom-Json in newer PowerShell versions may deserialize ISO-8601
    # strings as DateTime values. Match the raw JSON lexeme so validation is
    # exact and behaves the same in Windows PowerShell 5.1 and PowerShell 7+.
    $keyPattern = '(?<!\\)"{0}"\s*:' -f `
        [regex]::Escape($PropertyName)
    $keyOccurrences = @([regex]::Matches(
        $Json,
        $keyPattern,
        [Text.RegularExpressions.RegexOptions]::CultureInvariant
    ))
    if ($keyOccurrences.Count -ne 1) {
        throw "$Label must appear exactly once as a JSON property."
    }
    $pattern = $keyPattern + '\s*"(?<value>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)"'
    $occurrences = @([regex]::Matches(
        $Json,
        $pattern,
        [Text.RegularExpressions.RegexOptions]::CultureInvariant
    ))
    if ($occurrences.Count -ne 1) {
        throw "$Label must appear exactly once as a canonical UTC JSON string."
    }
    return $occurrences[0].Groups['value'].Value
}

$resolvedDeclaration = Resolve-RequiredFile $DeclarationPath "Unreviewed Beta release declaration"
$resolvedApk = Resolve-RequiredFile $ApkPath "Release APK"
$resolvedNativeSource = Resolve-RequiredFile $NativeSourcePath "Native source bundle"
$resolvedManifest = Resolve-RequiredFile $manifestPath "Native playback manifest"
$resolvedNotice = Resolve-RequiredFile $noticePath "Native playback notice"

if ($ReleaseTag -cnotmatch '^v2\.\d+\.\d+$') {
    throw "ReleaseTag must be a canonical Beta v2.x.y tag."
}
if ($GitCommit -cnotmatch '^[0-9a-f]{40}$') {
    throw "GitCommit must be the lowercase full Git commit ID."
}

$expectedApkName = "TetoTV-$ReleaseTag-universal.apk"
$expectedNativeSourceName = "TetoTV-$ReleaseTag-native-playback-sources.zip"
if ([IO.Path]::GetFileName($resolvedApk) -cne $expectedApkName) {
    throw "Expected APK name '$expectedApkName'."
}
if ([IO.Path]::GetFileName($resolvedNativeSource) -cne $expectedNativeSourceName) {
    throw "Expected native source bundle name '$expectedNativeSourceName'."
}

try {
    $declarationJson = Get-Content -Raw -LiteralPath $resolvedDeclaration
    $declaration = $declarationJson | ConvertFrom-Json
}
catch {
    throw "Unreviewed Beta release declaration is not valid JSON: $($_.Exception.Message)"
}

Assert-ExactProperties $declaration @(
    "schemaVersion",
    "statementType",
    "releaseTag",
    "gitCommit",
    "declaredAtUtc",
    "operatorIdentity",
    "independentNativeLicenseReview",
    "correspondingSourceIndependentlyReviewed",
    "knownProvenanceLimitsAcknowledged",
    "knownProvenanceLimitsSha256",
    "githubAppInventory",
    "artifacts"
) "Unreviewed Beta release declaration"
Assert-ExactProperties $declaration.githubAppInventory @(
    "repository",
    "checkedAtUtc",
    "reviewMethod",
    "inventoryComplete",
    "installations"
) "GitHub App installation inventory"
Assert-ExactProperties $declaration.artifacts @(
    "apkSha256",
    "nativeSourceSha256",
    "nativeManifestSha256",
    "nativePlaybackNoticeSha256"
) "Unreviewed Beta artifact binding"

$declaredAtText = Get-CanonicalUtcJsonString `
    -Json $declarationJson `
    -PropertyName "declaredAtUtc" `
    -Label "declaredAtUtc"
$inventoryCheckedAtText = Get-CanonicalUtcJsonString `
    -Json $declarationJson `
    -PropertyName "checkedAtUtc" `
    -Label "GitHub App inventory checkedAtUtc"

if (
    $declaration.schemaVersion -isnot [int] -and
    $declaration.schemaVersion -isnot [long]
) {
    throw "schemaVersion must be a JSON integer."
}
if ([long]$declaration.schemaVersion -ne 1) {
    throw "Unsupported unreviewed Beta declaration schema."
}
if ([string]$declaration.statementType -cne "tetotv-unreviewed-beta-release-declaration") {
    throw "Unexpected unreviewed Beta declaration statement type."
}
if ([string]$declaration.releaseTag -cne $ReleaseTag) {
    throw "Unreviewed Beta declaration is not bound to release tag $ReleaseTag."
}
if ([string]$declaration.gitCommit -cne $GitCommit) {
    throw "Unreviewed Beta declaration is not bound to Git commit $GitCommit."
}
if ([string]$declaration.operatorIdentity -cne $operatorIdentity) {
    throw "Unreviewed Beta declaration operator must be exactly '$operatorIdentity'."
}

foreach ($falseField in @(
    "independentNativeLicenseReview",
    "correspondingSourceIndependentlyReviewed"
)) {
    $value = $declaration.$falseField
    if ($value -isnot [bool] -or $value -ne $false) {
        throw "$falseField must be the JSON boolean false."
    }
}
$acknowledgement = $declaration.knownProvenanceLimitsAcknowledged
if ($acknowledgement -isnot [bool] -or $acknowledgement -ne $true) {
    throw "knownProvenanceLimitsAcknowledged must be the JSON boolean true."
}

if ($declaredAtText -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$') {
    throw "declaredAtUtc must use UTC form YYYY-MM-DDTHH:MM:SSZ."
}
$declaredAt = [DateTimeOffset]::ParseExact(
    $declaredAtText,
    "yyyy-MM-dd'T'HH:mm:ss'Z'",
    [Globalization.CultureInfo]::InvariantCulture,
    [Globalization.DateTimeStyles]::AssumeUniversal
)
$now = [DateTimeOffset]::UtcNow
if ($declaredAt -gt $now.AddMinutes(5) -or $declaredAt -lt $now.AddHours(-24)) {
    throw "Unreviewed Beta declaration must be created within 24 hours before publication and may be at most five minutes ahead for clock skew."
}

$appInventory = $declaration.githubAppInventory
if ([string]$appInventory.repository -cne $repository) {
    throw "GitHub App inventory must cover the exact Beta release repository."
}
if ([string]$appInventory.reviewMethod -cne $inventoryMethod) {
    throw "GitHub App inventory must record an owner confirmation from the repository Installed GitHub Apps settings page."
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
if ($inventoryCheckedAtText -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$') {
    throw "GitHub App inventory checkedAtUtc must use UTC form YYYY-MM-DDTHH:MM:SSZ."
}
$inventoryCheckedAt = [DateTimeOffset]::ParseExact(
    $inventoryCheckedAtText,
    "yyyy-MM-dd'T'HH:mm:ss'Z'",
    [Globalization.CultureInfo]::InvariantCulture,
    [Globalization.DateTimeStyles]::AssumeUniversal
)
if ($inventoryCheckedAt -ne $declaredAt) {
    throw "The complete empty GitHub App inventory must be confirmed when the declaration is created."
}

$manifest = Get-Content -Raw -LiteralPath $resolvedManifest | ConvertFrom-Json
$knownLimits = @($manifest.knownProvenanceLimits | ForEach-Object { [string]$_ })
if ($knownLimits.Count -eq 0) {
    throw "native_playback_manifest.json must record at least one provenance limitation."
}
$limitsText = ($knownLimits -join "`n") + "`n"
$expectedLimitsHash = Get-TextSha256 $limitsText
if ([string]$declaration.knownProvenanceLimitsSha256 -cne $expectedLimitsHash) {
    throw "Unreviewed Beta declaration does not acknowledge the exact recorded provenance-limit set."
}

$expectedArtifacts = @{
    apkSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedApk).Hash.ToLowerInvariant()
    nativeSourceSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedNativeSource).Hash.ToLowerInvariant()
    nativeManifestSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedManifest).Hash.ToLowerInvariant()
    nativePlaybackNoticeSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedNotice).Hash.ToLowerInvariant()
}
foreach ($name in $expectedArtifacts.Keys) {
    $actual = [string]$declaration.artifacts.$name
    if ($actual -notmatch '^[0-9a-f]{64}$' -or $actual -cne $expectedArtifacts[$name]) {
        throw "Unreviewed Beta artifact binding mismatch: $name."
    }
}

$declarationSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedDeclaration).Hash.ToLowerInvariant()
Write-Host "Unreviewed Beta release declaration verification passed"
Write-Host "  Operator:       $operatorIdentity"
Write-Host "  Release tag:    $ReleaseTag"
Write-Host "  Git commit:     $GitCommit"
Write-Host "  Declared at:    $declaredAtText"
Write-Host "  Declaration SHA-256: $declarationSha256"
Write-Warning "This evidence explicitly records that no independent native-license or corresponding-source review was performed."
Write-Warning "Verification confirms bindings and acknowledgements only; it is not legal advice or a compliance determination."
Write-Host "No private key, signature, credential, or other private material was read or required."
