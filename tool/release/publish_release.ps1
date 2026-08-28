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
$releaseTargets = [System.Collections.Generic.List[object]]::new()
$releaseTargets.Add([pscustomobject]@{
    Repository = $repository
    Title = $releaseTitle
    IsCanonical = $true
    CreatesTag = $false
})
$releaseTargets.Add([pscustomobject]@{
    Repository = "LindersOSX/TetoTV"
    Title = "$releaseTitle - legacy updater bridge"
    IsCanonical = $false
    CreatesTag = $true
})
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

function Test-RemoteTagExists([string]$Repository, [string]$Tag) {
    $repositoryUrl = "https://github.com/$Repository.git"
    $lines = @(& git ls-remote --tags $repositoryUrl "refs/tags/$Tag" "refs/tags/$Tag^{}" 2>$null)
    if ($LASTEXITCODE -ne 0) {
        throw "Could not inspect tag $Tag in $Repository."
    }
    return $lines.Count -gt 0
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

function Remove-GitHubReleaseAfterFailure(
    [string]$Repository,
    [string]$Tag,
    [bool]$CleanupTag
) {
    try {
        $arguments = @("release", "delete", $Tag, "--repo", $Repository, "--yes")
        if ($CleanupTag) { $arguments += "--cleanup-tag" }
        Invoke-GitHubCli -Arguments $arguments | Out-Null
    }
    catch {
        Write-Warning "Could not roll back $Repository release $Tag. Remove it manually before retrying."
    }
}

function Assert-PublishedRelease {
    param(
        [string]$Repository,
        [string]$Tag,
        [string]$Title,
        [string]$ExpectedTagCommit,
        [object[]]$ExpectedAssets,
        [string]$BuildCode
    )

    $release = Get-GitHubRelease $Repository $Tag
    if (
        $release.tag_name -cne $Tag -or
        $release.name -cne $Title -or
        [bool]$release.draft -or
        [bool]$release.prerelease
    ) {
        throw "Published release metadata verification failed for $Repository $Tag."
    }
    $buildMarker = "<!-- tetotv-android-version-code: $BuildCode -->"
    if (@([regex]::Matches([string]$release.body, [regex]::Escape($buildMarker))).Count -ne 1) {
        throw "Published release notes do not contain the exact Android build-code marker once."
    }
    foreach ($expected in $ExpectedAssets) {
        if (-not ([string]$release.body).Contains($expected.Name)) {
            throw "Published release notes do not name the asset '$($expected.Name)'."
        }
    }

    $hostedAssets = @($release.assets)
    if ($hostedAssets.Count -ne $ExpectedAssets.Count) {
        throw "Published release must contain exactly $($ExpectedAssets.Count) assets."
    }
    foreach ($expected in $ExpectedAssets) {
        $matches = @($hostedAssets | Where-Object name -CEQ $expected.Name)
        if ($matches.Count -ne 1) {
            throw "Published release is missing the unique asset '$($expected.Name)'."
        }
        $hosted = $matches[0]
        if ([long]$hosted.size -ne [long]$expected.Size) {
            throw "Published asset size mismatch: $($expected.Name)."
        }
        if (
            [string]$hosted.digest -and
            [string]$hosted.digest -cne "sha256:$($expected.Sha256)"
        ) {
            throw "Published asset digest mismatch: $($expected.Name)."
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
                throw "GitHub did not return the published asset '$($expected.Name)'."
            }
            $downloadedHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $downloadedPath).Hash.ToLowerInvariant()
            if ($downloadedHash -cne $expected.Sha256) {
                throw "Downloaded published asset digest mismatch: $($expected.Name)."
            }
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
    $latest = Get-LatestGitHubRelease $Repository
    if ($null -eq $latest -or $latest.tag_name -cne $Tag) {
        throw "$Repository does not expose $Tag through /releases/latest."
    }
}

Write-Host "Prepared $Channel release"
Write-Host "  Repositories: $($releaseTargets.Repository -join ', ')"
Write-Host "  Tag:        $releaseTag"
Write-Host "  Build code: $buildCode"
Write-Host "  Title:      $releaseTitle"
Write-Host "  Assets:     $($expectedAssets.Count)"
foreach ($asset in $expectedAssets) {
    Write-Host "    $($asset.Name) ($($asset.Size) bytes; sha256:$($asset.Sha256))"
}

if (-not $Publish) {
    Write-Host "Dry run only. No GitHub changes were made."
    exit 0
}
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw "GitHub CLI (gh) is required to publish."
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

    $expectedTagCommits = @{}
    $latestReleases = @{}
    foreach ($target in $releaseTargets) {
        if ($null -ne (Get-GitHubRelease $target.Repository $releaseTag -AllowMissing)) {
            throw "Release $releaseTag already exists in $($target.Repository)."
        }
        if (-not $target.IsCanonical -and (Test-RemoteTagExists $target.Repository $releaseTag)) {
            throw "Tag $releaseTag already exists in legacy updater repository $($target.Repository)."
        }
        $latestReleases[$target.Repository] = Get-LatestGitHubRelease $target.Repository
        $expectedTagCommits[$target.Repository] = if ($target.IsCanonical) {
            $headCommit
        }
        else {
            Get-RemoteRefCommit $target.Repository "refs/heads/main"
        }
    }

    $latest = $latestReleases[$repository]
    $legacyLatest = $latestReleases["LindersOSX/TetoTV"]
    if ($null -ne $latest -and $null -eq $legacyLatest) {
        throw "The legacy Beta updater feed is empty while the canonical feed is not. Repair the legacy feed before publishing."
    }
    if ($null -ne $latest -and $latest.tag_name -cne $legacyLatest.tag_name) {
        throw "Canonical and legacy Beta updater feeds are out of sync. Repair them before publishing."
    }
    if ($null -eq $latest -and $null -ne $legacyLatest) {
        Write-Host "The clean canonical Beta repository has no prior release; the legacy feed will be used as the version floor for this first synchronized publication."
    }

    foreach ($target in $releaseTargets) {
        $targetLatest = $latestReleases[$target.Repository]
        if ($null -eq $targetLatest) { continue }
        try {
            $latestVersion = [version]([string]$targetLatest.tag_name).TrimStart('v')
            $candidateVersion = [version]$versionName
        }
        catch {
            throw "The latest or candidate $Channel version in $($target.Repository) is not valid semantic version data."
        }
        if ($candidateVersion -le $latestVersion) {
            throw "Candidate $Channel $versionName must be newer than latest $($targetLatest.tag_name) in $($target.Repository)."
        }
        $latestBuildMatch = [regex]::Match(
            [string]$targetLatest.body,
            '(?is)tetotv-android-version-code:\s*(?<code>\d+)'
        )
        if (
            $latestBuildMatch.Success -and
            [long]$buildCode -le [long]$latestBuildMatch.Groups['code'].Value
        ) {
            throw "Android build code $buildCode must exceed the latest published $Channel build code in $($target.Repository)."
        }
    }

    $createdTargets = [System.Collections.Generic.List[object]]::new()
    try {
        foreach ($target in $releaseTargets) {
            $createArguments = @(
                "release", "create", $releaseTag,
                $resolvedApk,
                $resolvedNativeSource,
                $resolvedChecksums,
                "--repo", $target.Repository,
                "--latest",
                "--title", $target.Title,
                "--notes-file", $resolvedNotes
            )
            if ($target.IsCanonical) {
                $createArguments += "--verify-tag"
            }
            else {
                $createArguments += @("--target", "main")
            }
            Invoke-GitHubCli -Arguments $createArguments | Out-Null
            $createdTargets.Add($target)

            Assert-PublishedRelease `
                -Repository $target.Repository `
                -Tag $releaseTag `
                -Title $target.Title `
                -ExpectedTagCommit $expectedTagCommits[$target.Repository] `
                -ExpectedAssets $expectedAssets `
                -BuildCode $buildCode
        }
    }
    catch {
        for ($index = $createdTargets.Count - 1; $index -ge 0; $index--) {
            $created = $createdTargets[$index]
            Remove-GitHubReleaseAfterFailure `
                -Repository $created.Repository `
                -Tag $releaseTag `
                -CleanupTag ([bool]$created.CreatesTag)
        }
        throw
    }
}
finally {
    Pop-Location
}
