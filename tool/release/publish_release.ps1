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
if ([string]::IsNullOrWhiteSpace($ReleaseNotesPath)) {
    $ReleaseNotesPath = Join-Path $repositoryRoot "docs\RELEASE_NOTES_$versionName.md"
}

$resolvedApk = (Resolve-Path -LiteralPath $ApkPath).Path
$resolvedNativeSource = (Resolve-Path -LiteralPath $NativeSourcePath).Path
$resolvedChecksums = (Resolve-Path -LiteralPath $ChecksumsPath).Path
$resolvedNotes = (Resolve-Path -LiteralPath $ReleaseNotesPath).Path

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
    $encodedTag = [Uri]::EscapeDataString($Tag)
    $allowedExitCodes = if ($AllowMissing) { @(0, 1) } else { @(0) }
    $result = Invoke-GitHubCli `
        -Arguments @("api", "repos/$Repository/releases/tags/$encodedTag") `
        -AllowedExitCodes $allowedExitCodes
    if ($result.ExitCode -ne 0) {
        $details = ($result.Output -join "`n").Trim()
        if ($AllowMissing -and $details -match '(?i)(HTTP\s+404|not\s+found)') {
            return $null
        }
        throw "Could not read release $Tag from $Repository.`n$details"
    }
    try {
        return ($result.Output -join "`n") | ConvertFrom-Json
    }
    catch {
        throw "GitHub returned invalid release data for $Repository $Tag."
    }
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

function Assert-GitHubReleaseAuthorityBoundary(
    [string]$Repository,
    [string]$ExpectedOwner,
    [string]$SignedReviewAttestationPath
) {
    try {
        $signedReview = Get-Content -Raw -LiteralPath $SignedReviewAttestationPath |
            ConvertFrom-Json
    }
    catch {
        throw "Could not read the already verified signed release-authority review evidence."
    }
    $appInventory = $signedReview.githubAppInventory
    if ($null -eq $appInventory) {
        throw "The signed release-authority review is missing its GitHub App inventory."
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
        throw "The signed release-authority review must contain a complete empty GitHub App inventory for $Repository."
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

    $collaborators = @(Get-GitHubApiJson "repos/$Repository/collaborators?affiliation=all&per_page=100")
    if (
        $collaborators.Count -ne 1 -or
        [string]$collaborators[0].login -cne $ExpectedOwner -or
        -not [bool]$collaborators[0].permissions.admin
    ) {
        throw "Publication requires the audited single-owner authority boundary; unexpected collaborators are present."
    }
    if (@(Get-GitHubApiJson "repos/$Repository/invitations").Count -ne 0) {
        throw "Publication is blocked while repository collaborator invitations are pending."
    }
    $writeDeployKeys = @(
        @(Get-GitHubApiJson "repos/$Repository/keys") |
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
        [string]$NativeLicenseReviewSha256,
        [bool]$ExpectedDraft
    )

    $release = Get-GitHubRelease $Repository $Tag
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
    finally {
        $safeTempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        $safeDownloadRoot = [IO.Path]::GetFullPath($downloadRoot)
        if ($safeDownloadRoot.StartsWith($safeTempRoot, [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $safeDownloadRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Assert-RemoteTagMatchesCommit $Repository $Tag $ExpectedTagCommit
    $latest = Get-LatestGitHubRelease $Repository
    if ($ExpectedDraft) {
        if ($null -ne $latest -and $latest.tag_name -ceq $Tag) {
            throw "Draft $Tag must not be exposed through /releases/latest."
        }
    }
    elseif ($null -eq $latest -or $latest.tag_name -cne $Tag) {
        throw "$Repository does not expose published $Tag through /releases/latest."
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
    Write-Host "Publication additionally requires an SSH-signed, allowlisted native-license review attestation bound to the final tag, commit, APK, source ZIP, manifest, and native notice."
    exit 0
}
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw "GitHub CLI (gh) is required to publish."
}
if ([string]::IsNullOrWhiteSpace($NativeLicenseReviewPath)) {
    throw "-Publish requires -NativeLicenseReviewPath. Publication fails closed without a signed qualified-reviewer attestation."
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
    Assert-GitHubReleaseAuthorityBoundary `
        -Repository $repository `
        -ExpectedOwner "LindersOSX" `
        -SignedReviewAttestationPath $resolvedReview
    $resolvedReviewSignature = if (
        [string]::IsNullOrWhiteSpace($NativeLicenseReviewSignaturePath)
    ) {
        (Resolve-Path -LiteralPath "$resolvedReview.sig").Path
    }
    else {
        (Resolve-Path -LiteralPath $NativeLicenseReviewSignaturePath).Path
    }
    $nativeLicenseReviewSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedReview).Hash.ToLowerInvariant()

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

    $notesText = [IO.File]::ReadAllText($resolvedNotes)
    if ($notesText -match '(?im)<!--\s*tetotv-native-license-review-(?:sha256|attestation-base64|signature-base64):') {
        throw "The source release-notes file must not contain native-license review markers; the publisher adds verified evidence."
    }
    $reviewMarker = "<!-- tetotv-native-license-review-sha256: $nativeLicenseReviewSha256 -->"
    $reviewAttestationBase64 = [Convert]::ToBase64String(
        [IO.File]::ReadAllBytes($resolvedReview)
    )
    $reviewSignatureBase64 = [Convert]::ToBase64String(
        [IO.File]::ReadAllBytes($resolvedReviewSignature)
    )
    $reviewAttestationMarker = "<!-- tetotv-native-license-review-attestation-base64: $reviewAttestationBase64 -->"
    $reviewSignatureMarker = "<!-- tetotv-native-license-review-signature-base64: $reviewSignatureBase64 -->"
    $releaseNotesWithReview = (
        $notesText.TrimEnd() + "`n`n" +
        $reviewMarker + "`n" +
        $reviewAttestationMarker + "`n" +
        $reviewSignatureMarker + "`n"
    )
    $releaseTempRoot = Join-Path ([IO.Path]::GetTempPath()) ("tetotv-release-notes-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $releaseTempRoot | Out-Null
    $verifiedNotesPath = Join-Path $releaseTempRoot "RELEASE_NOTES.md"
    [IO.File]::WriteAllText(
        $verifiedNotesPath,
        $releaseNotesWithReview,
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
