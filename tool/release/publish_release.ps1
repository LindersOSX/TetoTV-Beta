[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("Beta")]
    [string]$Channel,

    [Parameter(Mandatory = $true)]
    [string]$ApkPath,

    [Parameter(Mandatory = $true)]
    [string]$NativeSourcePath,

    [Parameter(Mandatory = $true)]
    [string]$ChecksumsPath,

    [string]$ReleaseNotesPath = "",

    [string]$NativeLicenseReviewPath = "",

    [string]$NativeLicenseReviewSignaturePath = "",

    [string]$UnreviewedBetaDeclarationPath = "",

    [switch]$PublishWithoutIndependentNativeLicenseReview,

    [string]$UnreviewedBetaAcknowledgement = "",

    [switch]$Publish
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
$expectedMajor = 2
if ($versionMajor -ne $expectedMajor) {
    throw "$Channel releases require a $expectedMajor.x version; pubspec.yaml contains $versionName."
}

$releaseTag = "v$versionName"
$repository = "LindersOSX/TetoTV-Beta"
$releaseTitle = "TetoTV $versionName Beta - Android TV / Google TV / Fire TV"
$unreviewedBetaAcknowledgementText = "PUBLISH UNREVIEWED BETA"
$unreviewedBetaStatusMarker = "<!-- tetotv-native-license-review-status: unreviewed-beta -->"
$unreviewedBetaDisclosureText = "No independent native-license review: This Beta has not received independent native-library licensing review. Automated checks verify the APK, native-source bundle, notices, pinned inputs, and checksums, but do not establish legal compliance or reproducible builds."
$unreviewedBetaVisibleWarningPrefix = "# TetoTV $versionName Beta`n`n> [!WARNING]`n> $unreviewedBetaDisclosureText`n"
if ([string]::IsNullOrWhiteSpace($ReleaseNotesPath)) {
    $ReleaseNotesPath = Join-Path $repositoryRoot "docs\RELEASE_NOTES_$versionName.md"
}

$releaseEvidenceMode = if ($PublishWithoutIndependentNativeLicenseReview) {
    "UnreviewedBeta"
}
else {
    "Reviewed"
}
if ($releaseEvidenceMode -ceq "UnreviewedBeta") {
    if (
        -not [string]::Equals(
            $UnreviewedBetaAcknowledgement,
            $unreviewedBetaAcknowledgementText,
            [StringComparison]::Ordinal
        )
    ) {
        throw "Unreviewed Beta publication requires the exact acknowledgement '$unreviewedBetaAcknowledgementText'."
    }
    if (
        -not [string]::IsNullOrWhiteSpace($NativeLicenseReviewPath) -or
        -not [string]::IsNullOrWhiteSpace($NativeLicenseReviewSignaturePath)
    ) {
        throw "Reviewed native-license evidence and the unreviewed Beta exception are mutually exclusive."
    }
}
elseif (
    -not [string]::IsNullOrWhiteSpace($UnreviewedBetaDeclarationPath) -or
    -not [string]::IsNullOrWhiteSpace($UnreviewedBetaAcknowledgement)
) {
    throw "Unreviewed Beta inputs require -PublishWithoutIndependentNativeLicenseReview."
}

$resolvedApk = (Resolve-Path -LiteralPath $ApkPath).Path
$resolvedNativeSource = (Resolve-Path -LiteralPath $NativeSourcePath).Path
$resolvedChecksums = (Resolve-Path -LiteralPath $ChecksumsPath).Path
$resolvedNotes = (Resolve-Path -LiteralPath $ReleaseNotesPath).Path
$sourceNotesText = [IO.File]::ReadAllText($resolvedNotes)
$normalizedSourceNotesText = $sourceNotesText.Replace("`r`n", "`n")
if ($sourceNotesText -match '(?im)<!--\s*tetotv-(?:native-license-review-(?:sha256|attestation-base64|signature-base64|status)|unreviewed-beta-declaration-(?:sha256|base64)):') {
    throw "The source release-notes file must not contain publisher-added native-license evidence markers."
}
$sourceDisclosureCount = @([regex]::Matches(
    $sourceNotesText,
    [regex]::Escape($unreviewedBetaDisclosureText)
)).Count
if ($releaseEvidenceMode -ceq "UnreviewedBeta") {
    if (
        $sourceDisclosureCount -ne 1 -or
        -not $normalizedSourceNotesText.StartsWith(
            $unreviewedBetaVisibleWarningPrefix,
            [StringComparison]::Ordinal
        )
    ) {
        throw "Unreviewed Beta source release notes must begin with the exact visible warning block."
    }
}
elseif ($sourceDisclosureCount -ne 0) {
    throw "Reviewed release notes must not claim that independent native-license review was not performed."
}

& (Join-Path $PSScriptRoot "verify_release_payloads.ps1") `
    -Channel $Channel `
    -ApkPath $resolvedApk `
    -NativeSourcePath $resolvedNativeSource `
    -ChecksumsPath $resolvedChecksums `
    -ReleaseNotesPath $resolvedNotes

$assetPaths = @($resolvedApk, $resolvedNativeSource, $resolvedChecksums)
$expectedAssets = @($assetPaths | ForEach-Object {
    $item = Get-Item -LiteralPath $_
    [pscustomobject]@{
        Name = $item.Name
        Path = $item.FullName
        Size = [long]$item.Length
        Sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $item.FullName).Hash.ToLowerInvariant()
    }
})

function Invoke-GitHubCli {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [int[]]$AllowedExitCodes = @(0)
    )

    $previousErrorActionPreference = $ErrorActionPreference
    $nativePreferenceVariable = Get-Variable `
        -Name PSNativeCommandUseErrorActionPreference `
        -ErrorAction SilentlyContinue
    try {
        $ErrorActionPreference = "Continue"
        if ($nativePreferenceVariable) {
            $PSNativeCommandUseErrorActionPreference = $false
        }
        $output = @(& gh @Arguments 2>&1 | ForEach-Object { $_.ToString() })
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
        if ($nativePreferenceVariable) {
            $PSNativeCommandUseErrorActionPreference = [bool]$nativePreferenceVariable.Value
        }
    }

    if ($AllowedExitCodes -notcontains $exitCode) {
        $details = ($output -join "`n").Trim()
        $message = "GitHub CLI failed with exit code $exitCode`: gh $($Arguments -join ' ')"
        if ($details) { $message = "$message`n$details" }
        throw $message
    }
    return [pscustomobject]@{ ExitCode = $exitCode; Output = $output }
}

function Get-GitHubRelease([string]$Repository, [string]$Tag, [switch]$AllowMissing) {
    # GitHub's release-by-tag endpoint returns 404 for private drafts, even to
    # an authenticated repository owner. Enumerate all pages so verification
    # and rollback can see both drafts and published releases.
    $result = Invoke-GitHubCli -Arguments @(
        "api", "--paginate", "--slurp",
        "repos/$Repository/releases?per_page=100"
    )
    try {
        $pages = @(($result.Output -join "`n") | ConvertFrom-Json)
        $releases = @($pages | ForEach-Object { @($_) })
    }
    catch {
        throw "GitHub returned invalid release-list data for $Repository."
    }
    $matches = @($releases | Where-Object { [string]$_.tag_name -ceq $Tag })
    if ($matches.Count -gt 1) {
        throw "GitHub returned more than one release for exact tag $Tag in $Repository."
    }
    if ($matches.Count -eq 0) {
        if ($AllowMissing) { return $null }
        throw "Release $Tag does not exist in $Repository."
    }
    return $matches[0]
}

function Get-LatestGitHubRelease([string]$Repository) {
    $result = Invoke-GitHubCli `
        -Arguments @("api", "repos/$Repository/releases/latest") `
        -AllowedExitCodes @(0, 1)
    if ($result.ExitCode -ne 0) {
        $details = ($result.Output -join "`n").Trim()
        if ($details -match '(?i)(HTTP\s+404|not\s+found)') { return $null }
        throw "Could not read the latest release from $Repository.`n$details"
    }
    try {
        return ($result.Output -join "`n") | ConvertFrom-Json
    }
    catch {
        throw "GitHub returned invalid latest-release data for $Repository."
    }
}

function Get-RemoteRefCommit([string]$Repository, [string]$Ref, [switch]$Tag) {
    $repositoryUrl = "https://github.com/$Repository.git"
    $arguments = @("ls-remote", "--exit-code")
    if ($Tag) { $arguments += "--tags" }
    $arguments += @($repositoryUrl, $Ref)
    if ($Tag) { $arguments += "$Ref^{}" }
    $lines = @(& git @arguments 2>$null)
    if ($LASTEXITCODE -ne 0 -or $lines.Count -eq 0) {
        throw "Could not resolve $Ref in $Repository."
    }
    $selected = if ($Tag) {
        $lines | Where-Object { $_ -match [regex]::Escape("$Ref^{}") + '$' } | Select-Object -First 1
    }
    else {
        $lines | Select-Object -First 1
    }
    if (-not $selected) {
        $selected = $lines | Where-Object { $_ -match [regex]::Escape($Ref) + '$' } | Select-Object -First 1
    }
    return (($selected -split '\s+')[0]).Trim()
}

function Assert-TagMatchesHead([string]$Repository, [string]$Tag, [string]$HeadCommit) {
    $localTagCommit = (& git rev-list -n 1 $Tag 2>$null).Trim()
    if ($LASTEXITCODE -ne 0 -or $localTagCommit -cne $HeadCommit) {
        throw "Local tag $Tag must resolve to HEAD ($HeadCommit)."
    }
    $remoteMainCommit = Get-RemoteRefCommit $Repository "refs/heads/main"
    if ($remoteMainCommit -cne $HeadCommit) {
        throw "$Repository main must resolve to HEAD ($HeadCommit)."
    }
    $remoteTagCommit = Get-RemoteRefCommit $Repository "refs/tags/$Tag" -Tag
    if ($remoteTagCommit -cne $HeadCommit) {
        throw "$Repository tag $Tag must resolve to HEAD ($HeadCommit)."
    }
}

function Assert-RemoteTagMatchesCommit(
    [string]$Repository,
    [string]$Tag,
    [string]$ExpectedCommit
) {
    $remoteTagCommit = Get-RemoteRefCommit $Repository "refs/tags/$Tag" -Tag
    if ($remoteTagCommit -cne $ExpectedCommit) {
        throw "$Repository tag $Tag must resolve to $ExpectedCommit."
    }
}

function Remove-GitHubDraftAfterFailure(
    [string]$Repository,
    [string]$Tag
) {
    try {
        $release = Get-GitHubRelease $Repository $Tag -AllowMissing
        if ($null -eq $release) { return }
        if (-not [bool]$release.draft) {
            Write-Warning "Release $Repository $Tag is already published. It was not deleted; published immutable releases require investigation instead of automated rollback."
            return
        }
        $arguments = @("release", "delete", $Tag, "--repo", $Repository, "--yes")
        Invoke-GitHubCli -Arguments $arguments | Out-Null
    }
    catch {
        Write-Warning "Could not roll back draft $Repository release $Tag. Remove the draft manually before retrying."
    }
}

function Get-GitHubApiJson([string]$Path) {
    $result = Invoke-GitHubCli -Arguments @("api", $Path)
    try {
        return ($result.Output -join "`n") | ConvertFrom-Json
    }
    catch {
        throw "GitHub returned invalid JSON for API path $Path."
    }
}

function Get-GitHubApiItems([string]$Path) {
    $value = Get-GitHubApiJson $Path
    # ConvertFrom-Json emits no object for an empty JSON array. Returning the
    # value directly preserves that as an empty PowerShell pipeline, so callers
    # can safely wrap the result in @() without turning $null into one item.
    if ($null -eq $value) { return }
    $value
}

function Assert-GitHubReleaseAuthorityBoundary(
    [string]$Repository,
    [string]$ExpectedOwner,
    [object]$GitHubAppInventory
) {
    $appInventory = $GitHubAppInventory
    if ($null -eq $appInventory) {
        throw "The verified release evidence is missing its GitHub App inventory."
    }
    $appInventoryProperties = @($appInventory.PSObject.Properties.Name | Sort-Object)
    $expectedAppInventoryProperties = @(
        "checkedAtUtc",
        "installations",
        "inventoryComplete",
        "repository",
        "reviewMethod"
    ) | Sort-Object
    if (
        $appInventoryProperties.Count -ne $expectedAppInventoryProperties.Count -or
        (Compare-Object $expectedAppInventoryProperties $appInventoryProperties) -or
        [string]$appInventory.repository -cne $Repository -or
        $appInventory.inventoryComplete -ne $true -or
        @($appInventory.installations).Count -ne 0
    ) {
        throw "The verified release evidence must contain a complete empty GitHub App inventory for $Repository."
    }

    $authenticatedUser = Get-GitHubApiJson "user"
    if ([string]$authenticatedUser.login -cne $ExpectedOwner) {
        throw "The authenticated GitHub publisher must be exactly $ExpectedOwner."
    }

    $metadata = Get-GitHubApiJson "repos/$Repository"
    if (
        [string]$metadata.owner.login -cne $ExpectedOwner -or
        [string]$metadata.owner.type -cne "User" -or
        [string]$metadata.default_branch -cne "main" -or
        [string]$metadata.visibility -cne "public" -or
        [bool]$metadata.archived
    ) {
        throw "The GitHub repository owner, visibility, default branch, or archive state does not match the reviewed release boundary."
    }

    $collaborators = @(Get-GitHubApiItems "repos/$Repository/collaborators?affiliation=all&per_page=100")
    if (
        $collaborators.Count -ne 1 -or
        [string]$collaborators[0].login -cne $ExpectedOwner -or
        -not [bool]$collaborators[0].permissions.admin
    ) {
        throw "Publication requires the audited single-owner authority boundary; unexpected collaborators are present."
    }
    if (@(Get-GitHubApiItems "repos/$Repository/invitations").Count -ne 0) {
        throw "Publication is blocked while repository collaborator invitations are pending."
    }
    if (@(Get-GitHubApiItems "repos/$Repository/hooks").Count -ne 0) {
        throw "Publication is blocked while a repository webhook is configured."
    }
    $runners = Get-GitHubApiJson "repos/$Repository/actions/runners"
    if ([long]$runners.total_count -ne 0 -or @($runners.runners).Count -ne 0) {
        throw "Publication is blocked while a self-hosted repository runner is registered."
    }
    $writeDeployKeys = @(
        @(Get-GitHubApiItems "repos/$Repository/keys") |
            Where-Object { -not [bool]$_.read_only }
    )
    if ($writeDeployKeys.Count -ne 0) {
        throw "Publication is blocked while a write-capable repository deploy key exists."
    }

    $immutableReleases = Get-GitHubApiJson "repos/$Repository/immutable-releases"
    if (-not [bool]$immutableReleases.enabled) {
        throw "GitHub immutable future releases must be enabled before publication."
    }
    $actionsPolicy = Get-GitHubApiJson "repos/$Repository/actions/permissions"
    if (
        -not [bool]$actionsPolicy.enabled -or
        [string]$actionsPolicy.allowed_actions -cne "selected" -or
        -not [bool]$actionsPolicy.sha_pinning_required
    ) {
        throw "GitHub Actions must allow only selected actions and require full commit-SHA pins before publication."
    }
    $selectedActionsPolicy = Get-GitHubApiJson "repos/$Repository/actions/permissions/selected-actions"
    $expectedExternalActionPatterns = @(
        @(
            "android-actions/setup-android@*"
        ) | Sort-Object
    )
    $actualExternalActionPatterns = @($selectedActionsPolicy.patterns_allowed | Sort-Object)
    if (
        -not [bool]$selectedActionsPolicy.github_owned_allowed -or
        [bool]$selectedActionsPolicy.verified_allowed -or
        $actualExternalActionPatterns.Count -ne $expectedExternalActionPatterns.Count -or
        (Compare-Object $expectedExternalActionPatterns $actualExternalActionPatterns)
    ) {
        throw "GitHub Actions must allow GitHub-owned actions plus only the pinned external Android setup action required by the hosted verifier."
    }
    $workflowPermissions = Get-GitHubApiJson "repos/$Repository/actions/permissions/workflow"
    if (
        [string]$workflowPermissions.default_workflow_permissions -cne "read" -or
        [bool]$workflowPermissions.can_approve_pull_request_reviews
    ) {
        throw "GitHub workflow tokens must remain read-only by default and must not approve pull requests."
    }
}

function Assert-GitHubRelease {
    param(
        [string]$Repository,
        [string]$Tag,
        [string]$Title,
        [string]$ExpectedTagCommit,
        [object[]]$ExpectedAssets,
        [string]$BuildCode,
        [string]$NativeLicenseReviewSha256 = "",
        [string]$UnreviewedBetaDeclarationSha256 = "",
        [bool]$ExpectedDraft
    )

    # GitHub may briefly omit a newly created draft (or retain its old draft
    # state after publication) from the paginated release list. Wait for one
    # complete, exact snapshot instead of treating that consistency delay as
    # either success or a permanent failure.
    $release = $null
    $lastCandidate = $null
    $maxSnapshotAttempts = 10
    for ($attempt = 1; $attempt -le $maxSnapshotAttempts; $attempt++) {
        $candidate = Get-GitHubRelease $Repository $Tag -AllowMissing
        $snapshotReady = $false
        if ($null -ne $candidate) {
            $lastCandidate = $candidate
            $candidateAssets = @($candidate.assets)
            $snapshotReady = (
                $candidate.tag_name -ceq $Tag -and
                $candidate.name -ceq $Title -and
                [bool]$candidate.draft -eq $ExpectedDraft -and
                -not [bool]$candidate.prerelease -and
                $candidateAssets.Count -eq $ExpectedAssets.Count
            )
            if ($snapshotReady) {
                foreach ($expected in $ExpectedAssets) {
                    $assetMatches = @(
                        $candidateAssets | Where-Object name -CEQ $expected.Name
                    )
                    if (
                        $assetMatches.Count -ne 1 -or
                        [long]$assetMatches[0].size -ne [long]$expected.Size
                    ) {
                        $snapshotReady = $false
                        break
                    }
                }
            }
        }
        if ($snapshotReady) {
            $release = $candidate
            break
        }
        if ($attempt -lt $maxSnapshotAttempts) {
            Start-Sleep -Milliseconds 1500
        }
    }
    if ($null -eq $release) {
        $release = $lastCandidate
    }
    if ($null -eq $release) {
        throw "Release $Repository $Tag did not become visible after draft-state synchronization."
    }
    if (
        $release.tag_name -cne $Tag -or
        $release.name -cne $Title -or
        [bool]$release.draft -ne $ExpectedDraft -or
        [bool]$release.prerelease
    ) {
        $state = if ($ExpectedDraft) { "draft" } else { "published" }
        throw "$state release metadata verification failed for $Repository $Tag."
    }
    $buildMarker = "<!-- tetotv-android-version-code: $BuildCode -->"
    if (@([regex]::Matches([string]$release.body, [regex]::Escape($buildMarker))).Count -ne 1) {
        throw "Release notes do not contain the exact Android build-code marker once."
    }
    $hasReviewedEvidence = -not [string]::IsNullOrWhiteSpace($NativeLicenseReviewSha256)
    $hasUnreviewedEvidence = -not [string]::IsNullOrWhiteSpace($UnreviewedBetaDeclarationSha256)
    if ($hasReviewedEvidence -eq $hasUnreviewedEvidence) {
        throw "Release verification requires exactly one native-license evidence mode."
    }
    $attestationEvidenceMatches = @()
    $signatureEvidenceMatches = @()
    $unreviewedDeclarationMatches = @()
    if ($hasReviewedEvidence) {
        $normalizedReleaseBody = ([string]$release.body).Replace("`r`n", "`n")
        if (@([regex]::Matches($normalizedReleaseBody, [regex]::Escape($unreviewedBetaDisclosureText))).Count -ne 0) {
            throw "Reviewed release notes must not claim that independent native-license review was not performed."
        }
        $reviewMarker = "<!-- tetotv-native-license-review-sha256: $NativeLicenseReviewSha256 -->"
        if (@([regex]::Matches([string]$release.body, [regex]::Escape($reviewMarker))).Count -ne 1) {
            throw "Release notes do not contain the exact native-license review digest marker once."
        }
        if (@([regex]::Matches([string]$release.body, '(?im)<!--\s*tetotv-native-license-review-sha256:')).Count -ne 1) {
            throw "Release notes contain an unexpected native-license review marker."
        }
        $attestationEvidenceMatches = @([regex]::Matches(
            [string]$release.body,
            '(?im)<!--\s*tetotv-native-license-review-attestation-base64:\s*(?<data>[A-Za-z0-9+/]+={0,2})\s*-->'
        ))
        if (
            $attestationEvidenceMatches.Count -ne 1 -or
            @([regex]::Matches(
                [string]$release.body,
                '(?im)<!--\s*tetotv-native-license-review-attestation-base64:'
            )).Count -ne 1
        ) {
            throw "Release notes must contain exactly one encoded native-license review attestation."
        }
        $signatureEvidenceMatches = @([regex]::Matches(
            [string]$release.body,
            '(?im)<!--\s*tetotv-native-license-review-signature-base64:\s*(?<data>[A-Za-z0-9+/]+={0,2})\s*-->'
        ))
        if (
            $signatureEvidenceMatches.Count -ne 1 -or
            @([regex]::Matches(
                [string]$release.body,
                '(?im)<!--\s*tetotv-native-license-review-signature-base64:'
            )).Count -ne 1
        ) {
            throw "Release notes must contain exactly one encoded native-license review signature."
        }
        if ([string]$release.body -match '(?im)tetotv-(?:native-license-review-status:\s*unreviewed-beta|unreviewed-beta-declaration-)') {
            throw "Reviewed release notes must not contain unreviewed Beta evidence."
        }
    }
    else {
        $normalizedReleaseBody = ([string]$release.body).Replace("`r`n", "`n")
        if ($UnreviewedBetaDeclarationSha256 -notmatch '^[0-9a-f]{64}$') {
            throw "Unreviewed Beta declaration digest must be lowercase SHA-256."
        }
        if ([string]$release.body -match '(?im)<!--\s*tetotv-native-license-review-(?:sha256|attestation-base64|signature-base64):') {
            throw "Unreviewed Beta release notes must not contain qualified-review evidence."
        }
        if (@([regex]::Matches([string]$release.body, [regex]::Escape($unreviewedBetaStatusMarker))).Count -ne 1) {
            throw "Unreviewed Beta release notes must contain the exact status marker once."
        }
        if (@([regex]::Matches([string]$release.body, '(?im)<!--\s*tetotv-native-license-review-status:')).Count -ne 1) {
            throw "Unreviewed Beta release notes contain an unexpected review-status marker."
        }
        if (
            @([regex]::Matches($normalizedReleaseBody, [regex]::Escape($unreviewedBetaDisclosureText))).Count -ne 1 -or
            -not $normalizedReleaseBody.StartsWith(
                $unreviewedBetaVisibleWarningPrefix,
                [StringComparison]::Ordinal
            )
        ) {
            throw "Unreviewed Beta release notes must begin with the exact visible warning block."
        }
        $declarationMarker = "<!-- tetotv-unreviewed-beta-declaration-sha256: $UnreviewedBetaDeclarationSha256 -->"
        if (@([regex]::Matches([string]$release.body, [regex]::Escape($declarationMarker))).Count -ne 1) {
            throw "Release notes do not contain the exact unreviewed Beta declaration digest once."
        }
        if (@([regex]::Matches([string]$release.body, '(?im)<!--\s*tetotv-unreviewed-beta-declaration-sha256:')).Count -ne 1) {
            throw "Release notes contain an unexpected unreviewed Beta declaration marker."
        }
        $unreviewedDeclarationMatches = @([regex]::Matches(
            [string]$release.body,
            '(?im)<!--\s*tetotv-unreviewed-beta-declaration-base64:\s*(?<data>[A-Za-z0-9+/]+={0,2})\s*-->'
        ))
        if (
            $unreviewedDeclarationMatches.Count -ne 1 -or
            @([regex]::Matches(
                [string]$release.body,
                '(?im)<!--\s*tetotv-unreviewed-beta-declaration-base64:'
            )).Count -ne 1
        ) {
            throw "Release notes must contain exactly one encoded unreviewed Beta declaration."
        }
    }
    foreach ($expected in $ExpectedAssets) {
        if (-not ([string]$release.body).Contains($expected.Name)) {
            throw "Release notes do not name the asset '$($expected.Name)'."
        }
    }

    $hostedAssets = @($release.assets)
    if ($hostedAssets.Count -ne $ExpectedAssets.Count) {
        throw "Release must contain exactly $($ExpectedAssets.Count) assets."
    }
    foreach ($expected in $ExpectedAssets) {
        $matches = @($hostedAssets | Where-Object name -CEQ $expected.Name)
        if ($matches.Count -ne 1) {
            throw "Release is missing the unique asset '$($expected.Name)'."
        }
        $hosted = $matches[0]
        if ([long]$hosted.size -ne [long]$expected.Size) {
            throw "Hosted asset size mismatch: $($expected.Name)."
        }
        if (
            [string]$hosted.digest -and
            [string]$hosted.digest -cne "sha256:$($expected.Sha256)"
        ) {
            throw "Hosted asset digest mismatch: $($expected.Name)."
        }
    }

    $downloadRoot = Join-Path ([IO.Path]::GetTempPath()) ("tetotv-release-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $downloadRoot | Out-Null
    try {
        foreach ($expected in $ExpectedAssets) {
            Invoke-GitHubCli -Arguments @(
                "release", "download", $Tag,
                "--repo", $Repository,
                "--pattern", $expected.Name,
                "--dir", $downloadRoot
            ) | Out-Null
            $downloadedPath = Join-Path $downloadRoot $expected.Name
            if (-not (Test-Path -LiteralPath $downloadedPath -PathType Leaf)) {
                throw "GitHub did not return the hosted asset '$($expected.Name)'."
            }
            $downloadedHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $downloadedPath).Hash.ToLowerInvariant()
            if ($downloadedHash -cne $expected.Sha256) {
                throw "Downloaded hosted asset digest mismatch: $($expected.Name)."
            }
        }

        $downloadedNotesPath = Join-Path $downloadRoot "RELEASE_NOTES.md"
        [IO.File]::WriteAllText(
            $downloadedNotesPath,
            [string]$release.body,
            [Text.UTF8Encoding]::new($false)
        )
        if ($hasReviewedEvidence) {
            $downloadedAttestationPath = Join-Path $downloadRoot "native-license-review.json"
            $downloadedSignaturePath = Join-Path $downloadRoot "native-license-review.json.sig"
            try {
                [IO.File]::WriteAllBytes(
                    $downloadedAttestationPath,
                    [Convert]::FromBase64String(
                        $attestationEvidenceMatches[0].Groups['data'].Value
                    )
                )
                [IO.File]::WriteAllBytes(
                    $downloadedSignaturePath,
                    [Convert]::FromBase64String(
                        $signatureEvidenceMatches[0].Groups['data'].Value
                    )
                )
            }
            catch {
                throw "Release notes contain invalid encoded native-license review evidence."
            }
            $downloadedAttestationSha256 = (
                Get-FileHash -Algorithm SHA256 -LiteralPath $downloadedAttestationPath
            ).Hash.ToLowerInvariant()
            if ($downloadedAttestationSha256 -cne $NativeLicenseReviewSha256) {
                throw "Encoded native-license review attestation does not match its digest marker."
            }
            & (Join-Path $PSScriptRoot "verify_native_license_review.ps1") `
                -AttestationPath $downloadedAttestationPath `
                -SignaturePath $downloadedSignaturePath `
                -ReleaseTag $Tag `
                -GitCommit $ExpectedTagCommit `
                -ApkPath (Join-Path $downloadRoot ([IO.Path]::GetFileName($resolvedApk))) `
                -NativeSourcePath (Join-Path $downloadRoot ([IO.Path]::GetFileName($resolvedNativeSource)))
            & (Join-Path $PSScriptRoot "verify_release_payloads.ps1") `
                -Channel $Channel `
                -ApkPath (Join-Path $downloadRoot ([IO.Path]::GetFileName($resolvedApk))) `
                -NativeSourcePath (Join-Path $downloadRoot ([IO.Path]::GetFileName($resolvedNativeSource))) `
                -ChecksumsPath (Join-Path $downloadRoot ([IO.Path]::GetFileName($resolvedChecksums))) `
                -ReleaseNotesPath $downloadedNotesPath `
                -NativeLicenseReviewSha256 $NativeLicenseReviewSha256
        }
        else {
            $downloadedDeclarationPath = Join-Path $downloadRoot "unreviewed-beta-release-declaration.json"
            try {
                [IO.File]::WriteAllBytes(
                    $downloadedDeclarationPath,
                    [Convert]::FromBase64String(
                        $unreviewedDeclarationMatches[0].Groups['data'].Value
                    )
                )
            }
            catch {
                throw "Release notes contain invalid encoded unreviewed Beta evidence."
            }
            $downloadedDeclarationSha256 = (
                Get-FileHash -Algorithm SHA256 -LiteralPath $downloadedDeclarationPath
            ).Hash.ToLowerInvariant()
            if ($downloadedDeclarationSha256 -cne $UnreviewedBetaDeclarationSha256) {
                throw "Encoded unreviewed Beta declaration does not match its digest marker."
            }
            & (Join-Path $PSScriptRoot "verify_unreviewed_beta_release_declaration.ps1") `
                -DeclarationPath $downloadedDeclarationPath `
                -ReleaseTag $Tag `
                -GitCommit $ExpectedTagCommit `
                -ApkPath (Join-Path $downloadRoot ([IO.Path]::GetFileName($resolvedApk))) `
                -NativeSourcePath (Join-Path $downloadRoot ([IO.Path]::GetFileName($resolvedNativeSource)))
            & (Join-Path $PSScriptRoot "verify_release_payloads.ps1") `
                -Channel $Channel `
                -ApkPath (Join-Path $downloadRoot ([IO.Path]::GetFileName($resolvedApk))) `
                -NativeSourcePath (Join-Path $downloadRoot ([IO.Path]::GetFileName($resolvedNativeSource))) `
                -ChecksumsPath (Join-Path $downloadRoot ([IO.Path]::GetFileName($resolvedChecksums))) `
                -ReleaseNotesPath $downloadedNotesPath `
                -UnreviewedBetaDeclarationSha256 $UnreviewedBetaDeclarationSha256
        }
    }
    finally {
        $safeTempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        $safeDownloadRoot = [IO.Path]::GetFullPath($downloadRoot)
        if ($safeDownloadRoot.StartsWith($safeTempRoot, [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $safeDownloadRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Assert-RemoteTagMatchesCommit $Repository $Tag $ExpectedTagCommit
    if ($ExpectedDraft) {
        $latest = Get-LatestGitHubRelease $Repository
        if ($null -ne $latest -and $latest.tag_name -ceq $Tag) {
            throw "Draft $Tag must not be exposed through /releases/latest."
        }
    }
    else {
        $latest = $null
        for ($attempt = 1; $attempt -le $maxSnapshotAttempts; $attempt++) {
            $latest = Get-LatestGitHubRelease $Repository
            if ($null -ne $latest -and $latest.tag_name -ceq $Tag) { break }
            if ($attempt -lt $maxSnapshotAttempts) {
                Start-Sleep -Milliseconds 1500
            }
        }
        if ($null -eq $latest -or $latest.tag_name -cne $Tag) {
            throw "$Repository does not expose published $Tag through /releases/latest."
        }
    }
}

Write-Host "Prepared $Channel release"
Write-Host "  Repository:  $repository"
Write-Host "  Tag:        $releaseTag"
Write-Host "  Build code: $buildCode"
Write-Host "  Title:      $releaseTitle"
Write-Host "  Assets:     $($expectedAssets.Count)"
foreach ($asset in $expectedAssets) {
    Write-Host "    $($asset.Name) ($($asset.Size) bytes; sha256:$($asset.Sha256))"
}

if (-not $Publish) {
    Write-Host "Dry run only. No GitHub changes were made."
    if ($releaseEvidenceMode -ceq "Reviewed") {
        Write-Host "Reviewed publication additionally requires an SSH-signed, allowlisted native-license review attestation bound to the final tag, commit, APK, source ZIP, manifest, and native notice."
    }
    else {
        Write-Warning "Unreviewed Beta mode selected. Publication requires a fresh owner declaration that explicitly records no independent native-license or corresponding-source review."
    }
    exit 0
}
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw "GitHub CLI (gh) is required to publish."
}
if (
    $releaseEvidenceMode -ceq "Reviewed" -and
    [string]::IsNullOrWhiteSpace($NativeLicenseReviewPath)
) {
    throw "Reviewed publication requires -NativeLicenseReviewPath and fails closed without a signed qualified-reviewer attestation."
}
if (
    $releaseEvidenceMode -ceq "UnreviewedBeta" -and
    [string]::IsNullOrWhiteSpace($UnreviewedBetaDeclarationPath)
) {
    throw "Unreviewed Beta publication requires -UnreviewedBetaDeclarationPath."
}

Push-Location $repositoryRoot
try {
    if (git status --porcelain) {
        throw "The working tree must be clean before publishing."
    }
    $headCommit = (& git rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $headCommit) {
        throw "Could not resolve local HEAD."
    }
    Assert-TagMatchesHead $repository $releaseTag $headCommit
    $resolvedReview = ""
    $resolvedReviewSignature = ""
    $nativeLicenseReviewSha256 = ""
    $resolvedUnreviewedDeclaration = ""
    $unreviewedBetaDeclarationSha256 = ""
    $githubAppInventory = $null
    if ($releaseEvidenceMode -ceq "Reviewed") {
        $reviewArguments = @{
            AttestationPath = $NativeLicenseReviewPath
            ReleaseTag = $releaseTag
            GitCommit = $headCommit
            ApkPath = $resolvedApk
            NativeSourcePath = $resolvedNativeSource
        }
        if (-not [string]::IsNullOrWhiteSpace($NativeLicenseReviewSignaturePath)) {
            $reviewArguments.SignaturePath = $NativeLicenseReviewSignaturePath
        }
        & (Join-Path $PSScriptRoot "verify_native_license_review.ps1") @reviewArguments
        $resolvedReview = (Resolve-Path -LiteralPath $NativeLicenseReviewPath).Path
        $reviewEvidence = Get-Content -Raw -LiteralPath $resolvedReview | ConvertFrom-Json
        $githubAppInventory = $reviewEvidence.githubAppInventory
        $resolvedReviewSignature = if (
            [string]::IsNullOrWhiteSpace($NativeLicenseReviewSignaturePath)
        ) {
            (Resolve-Path -LiteralPath "$resolvedReview.sig").Path
        }
        else {
            (Resolve-Path -LiteralPath $NativeLicenseReviewSignaturePath).Path
        }
        $nativeLicenseReviewSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedReview).Hash.ToLowerInvariant()
    }
    else {
        $unreviewedArguments = @{
            DeclarationPath = $UnreviewedBetaDeclarationPath
            ReleaseTag = $releaseTag
            GitCommit = $headCommit
            ApkPath = $resolvedApk
            NativeSourcePath = $resolvedNativeSource
        }
        & (Join-Path $PSScriptRoot "verify_unreviewed_beta_release_declaration.ps1") @unreviewedArguments
        $resolvedUnreviewedDeclaration = (
            Resolve-Path -LiteralPath $UnreviewedBetaDeclarationPath
        ).Path
        $unreviewedEvidence = Get-Content -Raw -LiteralPath $resolvedUnreviewedDeclaration |
            ConvertFrom-Json
        $githubAppInventory = $unreviewedEvidence.githubAppInventory
        $unreviewedBetaDeclarationSha256 = (
            Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedUnreviewedDeclaration
        ).Hash.ToLowerInvariant()
    }
    Assert-GitHubReleaseAuthorityBoundary `
        -Repository $repository `
        -ExpectedOwner "LindersOSX" `
        -GitHubAppInventory $githubAppInventory

    if ($null -ne (Get-GitHubRelease $repository $releaseTag -AllowMissing)) {
        throw "Release $releaseTag already exists in $repository."
    }

    $latest = Get-LatestGitHubRelease $repository
    if ($null -ne $latest) {
        try {
            $latestVersion = [version]([string]$latest.tag_name).TrimStart('v')
            $candidateVersion = [version]$versionName
        }
        catch {
            throw "The latest or candidate $Channel version in $repository is not valid semantic version data."
        }
        if ($candidateVersion -le $latestVersion) {
            throw "Candidate $Channel $versionName must be newer than latest $($latest.tag_name) in $repository."
        }
        $latestBuildMatch = [regex]::Match(
            [string]$latest.body,
            '(?is)tetotv-android-version-code:\s*(?<code>\d+)'
        )
        if (
            $latestBuildMatch.Success -and
            [long]$buildCode -le [long]$latestBuildMatch.Groups['code'].Value
        ) {
            throw "Android build code $buildCode must exceed the latest published $Channel build code in $repository."
        }
    }

    $notesText = $sourceNotesText
    if ($releaseEvidenceMode -ceq "Reviewed") {
        $reviewMarker = "<!-- tetotv-native-license-review-sha256: $nativeLicenseReviewSha256 -->"
        $reviewAttestationBase64 = [Convert]::ToBase64String(
            [IO.File]::ReadAllBytes($resolvedReview)
        )
        $reviewSignatureBase64 = [Convert]::ToBase64String(
            [IO.File]::ReadAllBytes($resolvedReviewSignature)
        )
        $reviewAttestationMarker = "<!-- tetotv-native-license-review-attestation-base64: $reviewAttestationBase64 -->"
        $reviewSignatureMarker = "<!-- tetotv-native-license-review-signature-base64: $reviewSignatureBase64 -->"
        $verifiedReleaseNotes = (
            $notesText.TrimEnd() + "`n`n" +
            $reviewMarker + "`n" +
            $reviewAttestationMarker + "`n" +
            $reviewSignatureMarker + "`n"
        )
    }
    else {
        $normalizedNotesText = $notesText.Replace("`r`n", "`n")
        if (
            @([regex]::Matches($normalizedNotesText, [regex]::Escape($unreviewedBetaDisclosureText))).Count -ne 1 -or
            -not $normalizedNotesText.StartsWith(
                $unreviewedBetaVisibleWarningPrefix,
                [StringComparison]::Ordinal
            )
        ) {
            throw "The source release notes must begin with the exact visible unreviewed Beta warning block."
        }
        $declarationMarker = "<!-- tetotv-unreviewed-beta-declaration-sha256: $unreviewedBetaDeclarationSha256 -->"
        $declarationBase64 = [Convert]::ToBase64String(
            [IO.File]::ReadAllBytes($resolvedUnreviewedDeclaration)
        )
        $declarationEvidenceMarker = "<!-- tetotv-unreviewed-beta-declaration-base64: $declarationBase64 -->"
        $verifiedReleaseNotes = (
            $notesText.TrimEnd() + "`n`n" +
            $unreviewedBetaStatusMarker + "`n" +
            $declarationMarker + "`n" +
            $declarationEvidenceMarker + "`n"
        )
    }
    $releaseTempRoot = Join-Path ([IO.Path]::GetTempPath()) ("tetotv-release-notes-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $releaseTempRoot | Out-Null
    $verifiedNotesPath = Join-Path $releaseTempRoot "RELEASE_NOTES.md"
    [IO.File]::WriteAllText(
        $verifiedNotesPath,
        $verifiedReleaseNotes,
        [Text.UTF8Encoding]::new($false)
    )

    try {
        Invoke-GitHubCli -Arguments @(
            "release", "create", $releaseTag,
            $resolvedApk,
            $resolvedNativeSource,
            $resolvedChecksums,
            "--repo", $repository,
            "--draft",
            "--latest=false",
            "--title", $releaseTitle,
            "--notes-file", $verifiedNotesPath,
            "--verify-tag"
        ) | Out-Null
        # This is the publication boundary: re-download every private draft
        # asset and run the complete APK/native/source/checksum verifier before
        # the release becomes visible. No asset can bypass the draft gate.
        Assert-GitHubRelease `
            -Repository $repository `
            -Tag $releaseTag `
            -Title $releaseTitle `
            -ExpectedTagCommit $headCommit `
            -ExpectedAssets $expectedAssets `
            -BuildCode $buildCode `
            -NativeLicenseReviewSha256 $nativeLicenseReviewSha256 `
            -UnreviewedBetaDeclarationSha256 $unreviewedBetaDeclarationSha256 `
            -ExpectedDraft $true

        Invoke-GitHubCli -Arguments @(
            "release", "edit", $releaseTag,
            "--repo", $repository,
            "--draft=false",
            "--latest",
            "--verify-tag"
        ) | Out-Null

        Assert-GitHubRelease `
            -Repository $repository `
            -Tag $releaseTag `
            -Title $releaseTitle `
            -ExpectedTagCommit $headCommit `
            -ExpectedAssets $expectedAssets `
            -BuildCode $buildCode `
            -NativeLicenseReviewSha256 $nativeLicenseReviewSha256 `
            -UnreviewedBetaDeclarationSha256 $unreviewedBetaDeclarationSha256 `
            -ExpectedDraft $false
    }
    catch {
        # `gh release create` creates the draft before uploading each asset.
        # Query actual GitHub state on every failure so a partial upload cannot
        # leave a stale draft merely because the CLI command never returned.
        Remove-GitHubDraftAfterFailure -Repository $repository -Tag $releaseTag
        throw
    }
    finally {
        $safeTempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        $safeReleaseTempRoot = [IO.Path]::GetFullPath($releaseTempRoot)
        if ($safeReleaseTempRoot.StartsWith($safeTempRoot, [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $safeReleaseTempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
finally {
    Pop-Location
}
