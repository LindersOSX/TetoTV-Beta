[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$releaseCommit = 'a738129cc4aa99206c00ae49e9c5b15cb58ad880'
$archiveUrl =
    "https://github.com/cashapp/quickjs-java/archive/$releaseCommit.tar.gz"
$archiveSha256 =
    'B54A2153690533AFD0181FC1136CE989EB31E3C39BF2E852B2FF1ADF4179D56F'
$upstreamContextSha256 =
    '4A33F1D0BE29983EC60020E0B6CFFBBAE9D3EDB2A5519888A09D66FF54DB7AE6'
$vendoredContextSha256 =
    'D187163CCC2AE2A4FE210BE24A93F4E4544B6D5484CB5AEF8F5CFCEF371FA30F'

function Assert-Sha256 {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Expected
    )

    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    if ($actual -ne $Expected) {
        throw "SHA-256 mismatch for $Path. Expected $Expected, received $actual."
    }
}

function Assert-SameFile {
    param(
        [Parameter(Mandatory = $true)][string]$ExpectedPath,
        [Parameter(Mandatory = $true)][string]$ActualPath
    )

    $expectedHash = (Get-FileHash -LiteralPath $ExpectedPath -Algorithm SHA256).Hash
    $actualHash = (Get-FileHash -LiteralPath $ActualPath -Algorithm SHA256).Hash
    if ($expectedHash -ne $actualHash) {
        throw "Vendored source differs from the pinned archive: $ActualPath"
    }
}

function Get-NormalizedText {
    param([Parameter(Mandatory = $true)][string]$Path)

    return [IO.File]::ReadAllText($Path).Replace("`r`n", "`n")
}

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$vendoredRoot = Join-Path $repositoryRoot 'third_party\app_cash_quickjs\upstream'
$sourceManifest = Join-Path $repositoryRoot `
    'android\cash-quickjs-android\SOURCE_MANIFEST.sha256'
$contextRelativePath = 'quickjs/common/native/Context.h'
$vendoredContext = Join-Path $vendoredRoot `
    ($contextRelativePath.Replace('/', '\'))
$apacheNotice = Join-Path $repositoryRoot `
    'assets\legal\aniyomi\OKHTTP_LICENSE.txt'
$quickJsNotice = Join-Path $repositoryRoot `
    'assets\addon_runtime\QUICKJS_LICENSE.txt'

if (-not (Test-Path -LiteralPath $sourceManifest -PathType Leaf)) {
    throw 'Cash App QuickJS source manifest is missing.'
}

$manifest = @{}
foreach ($line in [IO.File]::ReadAllLines($sourceManifest)) {
    if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) {
        continue
    }
    if ($line -notmatch '^(?<hash>[0-9a-fA-F]{64})  (?<path>.+)$') {
        throw "Malformed source manifest line: $line"
    }
    $manifest[$Matches.path] = $Matches.hash.ToUpperInvariant()
}

$actualPaths = @(
    Get-ChildItem -LiteralPath $vendoredRoot -Recurse -File |
        ForEach-Object {
            $_.FullName.Substring($vendoredRoot.Length + 1).Replace('\', '/')
        } |
        Sort-Object
)
$expectedPaths = @($manifest.Keys | Sort-Object)
$inventoryDelta = @(Compare-Object -ReferenceObject $expectedPaths `
    -DifferenceObject $actualPaths)
if ($inventoryDelta.Count -ne 0) {
    throw "Vendored source inventory differs from the reviewed manifest: $($inventoryDelta | Out-String)"
}

foreach ($relativePath in $expectedPaths) {
    $localPath = Join-Path $vendoredRoot ($relativePath.Replace('/', '\'))
    Assert-Sha256 -Path $localPath -Expected $manifest[$relativePath]
}
Assert-Sha256 -Path $vendoredContext -Expected $vendoredContextSha256

$temporaryRoot = Join-Path (
    [System.IO.Path]::GetTempPath()
) ("tetotv-app-cash-quickjs-verify-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporaryRoot | Out-Null

try {
    $archive = Join-Path $temporaryRoot "app-cash-quickjs-$releaseCommit.tar.gz"
    Invoke-WebRequest -UseBasicParsing -Uri $archiveUrl -OutFile $archive
    Assert-Sha256 -Path $archive -Expected $archiveSha256

    & tar -xf $archive -C $temporaryRoot
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not extract the pinned Cash App QuickJS source archive.'
    }

    $sourceRoots = @(
        Get-ChildItem -LiteralPath $temporaryRoot -Directory |
            Where-Object {
                (Test-Path -LiteralPath (Join-Path $_.FullName 'LICENSE')) -and
                (Test-Path -LiteralPath (
                    Join-Path $_.FullName 'quickjs\common\native\quickjs\quickjs.c'
                ))
            }
    )
    if ($sourceRoots.Count -ne 1) {
        throw "Expected one extracted source root, found $($sourceRoots.Count)."
    }
    $upstreamRoot = $sourceRoots[0].FullName

    foreach ($relativePath in $expectedPaths) {
        $upstreamPath = Join-Path $upstreamRoot ($relativePath.Replace('/', '\'))
        $localPath = Join-Path $vendoredRoot ($relativePath.Replace('/', '\'))
        if (-not (Test-Path -LiteralPath $upstreamPath -PathType Leaf)) {
            throw "Pinned source archive is missing imported file: $relativePath"
        }
        if ($relativePath -ne $contextRelativePath) {
            Assert-SameFile -ExpectedPath $upstreamPath -ActualPath $localPath
        }
    }

    $upstreamContext = Join-Path $upstreamRoot `
        ($contextRelativePath.Replace('/', '\'))
    Assert-Sha256 -Path $upstreamContext -Expected $upstreamContextSha256
    $patchedContextText = Get-NormalizedText -Path $vendoredContext
    $functionalInclude = "#include <functional>`n"
    $includeCount = ([regex]::Matches(
        $patchedContextText,
        [regex]::Escape($functionalInclude)
    )).Count
    if ($includeCount -ne 1) {
        throw 'Context.h must contain exactly one documented <functional> include.'
    }
    $reconstructedContext = $patchedContextText.Replace($functionalInclude, '')
    $upstreamContextText = Get-NormalizedText -Path $upstreamContext
    if ($reconstructedContext -ne $upstreamContextText) {
        throw 'Context.h contains changes beyond the documented <functional> include.'
    }

    $upstreamApache = Get-NormalizedText -Path `
        (Join-Path $upstreamRoot 'LICENSE')
    $packagedApache = Get-NormalizedText -Path $apacheNotice
    if ($upstreamApache -ne $packagedApache) {
        throw 'The packaged Apache-2.0 text differs from the pinned wrapper license.'
    }

    $engineSource = Get-NormalizedText -Path (
        Join-Path $upstreamRoot 'quickjs\common\native\quickjs\quickjs.c'
    )
    $licenseMatch = [regex]::Match($engineSource, '(?s)^/\*\n(?<body>.*?)\n \*/')
    if (-not $licenseMatch.Success) {
        throw 'Could not extract the embedded QuickJS license header.'
    }
    $engineLicenseLines = @(
        $licenseMatch.Groups['body'].Value.Split("`n") |
            ForEach-Object { $_ -replace '^ \* ?', '' }
    )
    $engineLicense = ($engineLicenseLines -join "`n").Trim()
    $packagedEngineLicense = (Get-NormalizedText -Path $quickJsNotice).Trim()
    if ($engineLicense -ne $packagedEngineLicense) {
        throw 'The packaged QuickJS MIT text differs from the pinned engine header.'
    }

    Write-Host (
        'Verified Cash App QuickJS Android 0.9.2 source inventory, ' +
        'documented Context.h adaptation, and packaged licenses.'
    )
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}
