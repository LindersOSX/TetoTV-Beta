[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$quickJsVersion = '2026-06-04'
$quickJsArchiveUrl =
    "https://bellard.org/quickjs/quickjs-$quickJsVersion.tar.xz"
$quickJsArchiveSha256 =
    'B376E839B322978313D929FD20663B11BA58B75DF5A46C126DD19EA2FA70AD2A'

$bridgeCommit = '0f72f7409ff610b33b0e09bd9460213f0e487bf0'
$bridgeUrl =
    "https://raw.githubusercontent.com/fast-development/android-js-runtimes/$bridgeCommit/quickjs/src/main/c/quickjs_runtime.cpp"
$bridgeUpstreamSha256 =
    '54B873706D077451D843CA564F511582479C3562438D34FDB883F3639A5ED047'
$bridgeVendoredSha256 =
    '8E1953548F72B5F68040421FA2919AEEA2C755EDB27A6FB001C4CFD66E71C03B'
$bridgeLicenseUrl =
    "https://raw.githubusercontent.com/fast-development/android-js-runtimes/$bridgeCommit/LICENSE"
$bridgeLicenseSha256 =
    '77203F87A1D4C88A9F8E783A4F24422EB342AE6299BC7AA43FE0D8B2B6C43A18'

$quickJsFiles = @(
    'cutils.c',
    'cutils.h',
    'dtoa.c',
    'dtoa.h',
    'libregexp-opcode.h',
    'libregexp.c',
    'libregexp.h',
    'libunicode-table.h',
    'libunicode.c',
    'libunicode.h',
    'LICENSE',
    'list.h',
    'quickjs-atom.h',
    'quickjs-opcode.h',
    'quickjs.c',
    'quickjs.h'
)

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

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$nativeRoot = Join-Path $repositoryRoot 'third_party\flutter_js\android\src\main\c'
$vendoredQuickJs = Join-Path $nativeRoot 'quickjs'
$vendoredBridge = Join-Path $nativeRoot 'quickjs_runtime.cpp'
$bridgeNotice = Join-Path $repositoryRoot 'assets\addon_runtime\ANDROID_JS_RUNTIMES_LICENSE.txt'
$quickJsNotice = Join-Path $repositoryRoot 'assets\addon_runtime\QUICKJS_LICENSE.txt'

$temporaryRoot = Join-Path (
    [System.IO.Path]::GetTempPath()
) ("tetotv-quickjs-verify-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporaryRoot | Out-Null

try {
    $archive = Join-Path $temporaryRoot "quickjs-$quickJsVersion.tar.xz"
    Invoke-WebRequest -UseBasicParsing -Uri $quickJsArchiveUrl -OutFile $archive
    Assert-Sha256 -Path $archive -Expected $quickJsArchiveSha256
    & tar -xf $archive -C $temporaryRoot
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not extract the pinned QuickJS source archive.'
    }

    $extractedQuickJs = Join-Path $temporaryRoot "quickjs-$quickJsVersion"
    foreach ($file in $quickJsFiles) {
        Assert-SameFile `
            -ExpectedPath (Join-Path $extractedQuickJs $file) `
            -ActualPath (Join-Path $vendoredQuickJs $file)
    }

    $unexpected = Get-ChildItem -LiteralPath $vendoredQuickJs -File |
        Where-Object { $_.Name -notin $quickJsFiles }
    if ($unexpected) {
        throw "Unexpected vendored QuickJS files: $($unexpected.Name -join ', ')"
    }

    $upstreamBridge = Join-Path $temporaryRoot 'quickjs_runtime.cpp'
    Invoke-WebRequest -UseBasicParsing -Uri $bridgeUrl -OutFile $upstreamBridge
    Assert-Sha256 -Path $upstreamBridge -Expected $bridgeUpstreamSha256
    Assert-Sha256 -Path $vendoredBridge -Expected $bridgeVendoredSha256

    $upstreamBridgeLicense = Join-Path $temporaryRoot 'android-js-runtimes-LICENSE'
    Invoke-WebRequest `
        -UseBasicParsing `
        -Uri $bridgeLicenseUrl `
        -OutFile $upstreamBridgeLicense
    Assert-Sha256 -Path $upstreamBridgeLicense -Expected $bridgeLicenseSha256

    $normalizedBridgeLicense = [IO.File]::ReadAllText($upstreamBridgeLicense).
        Replace("`r`n", "`n")
    $normalizedBridgeNotice = [IO.File]::ReadAllText($bridgeNotice).
        Replace("`r`n", "`n")
    if ($normalizedBridgeLicense -ne $normalizedBridgeNotice) {
        throw 'The packaged Android JS Runtimes license differs from upstream.'
    }

    $normalizedQuickJsLicense = [IO.File]::ReadAllText(
        (Join-Path $extractedQuickJs 'LICENSE')
    ).Replace("`r`n", "`n")
    $normalizedQuickJsNotice = [IO.File]::ReadAllText($quickJsNotice).
        Replace("`r`n", "`n")
    if ($normalizedQuickJsLicense -ne $normalizedQuickJsNotice) {
        throw 'The packaged QuickJS license differs from the pinned source.'
    }

    Write-Host "Verified QuickJS $quickJsVersion sources, bridge provenance, and licenses."
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}
