[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ApkPath,

    [ValidateSet("Auto", "Beta", "Public")]
    [string]$Channel = "Auto"
)

$ErrorActionPreference = "Stop"

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$resolvedApk = (Resolve-Path -LiteralPath $ApkPath).Path
$pubspecText = Get-Content -LiteralPath (Join-Path $repositoryRoot "pubspec.yaml") -Raw
$versionMatch = [regex]::Match(
    $pubspecText,
    '(?m)^version:\s*((?<major>[12])\.\d+\.\d+)\+(?<code>\d+)\s*$'
)
if (-not $versionMatch.Success) {
    throw "pubspec.yaml does not contain a supported Public 1.x or Beta 2.x version and Android build code."
}

$expectedVersionName = $versionMatch.Groups[1].Value
$expectedMajor = [int]$versionMatch.Groups['major'].Value
$expectedVersionCode = $versionMatch.Groups['code'].Value
$expectedChannel = if ($expectedMajor -eq 1) { "Public" } else { "Beta" }
if ($Channel -ne "Auto" -and $Channel -ne $expectedChannel) {
    throw "The $Channel channel cannot publish version $expectedVersionName; expected $expectedChannel."
}
$expectedPackageId = "dev.animetv.anime_tv"
$expectedMinimumSdk = "24"
# Public certificate fingerprint from the production signer used by v2.0.25.
# This is not a private signing credential.
$expectedSignerSha256 = "008ef69468023edcf1009d2ae999ef57d91e5411ff62bd37194fd91fad12fb5c"

function Resolve-AndroidSdkRoot {
    foreach ($candidate in @($env:ANDROID_SDK_ROOT, $env:ANDROID_HOME)) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Container)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    $localProperties = Join-Path $repositoryRoot "android\local.properties"
    if (Test-Path -LiteralPath $localProperties -PathType Leaf) {
        $sdkLine = Get-Content -LiteralPath $localProperties |
            Where-Object { $_ -match '^sdk\.dir=' } |
            Select-Object -First 1
        if ($sdkLine) {
            $candidate = ($sdkLine -replace '^sdk\.dir=', '') -replace '\\\\', '\'
            if (Test-Path -LiteralPath $candidate -PathType Container) {
                return (Resolve-Path -LiteralPath $candidate).Path
            }
        }
    }

    throw "Android SDK not found. Set ANDROID_SDK_ROOT or ANDROID_HOME."
}

function Resolve-AndroidTool {
    param(
        [Parameter(Mandatory = $true)] [string]$SdkRoot,
        [Parameter(Mandatory = $true)] [string]$WindowsName,
        [Parameter(Mandatory = $true)] [string]$UnixName,
        [Parameter(Mandatory = $true)] [string]$RelativeRoot
    )

    $root = Join-Path $SdkRoot $RelativeRoot
    $toolName = if ($IsWindows -or $env:OS -eq "Windows_NT") {
        $WindowsName
    }
    else {
        $UnixName
    }
    $tool = Get-ChildItem -LiteralPath $root -Recurse -File -Filter $toolName `
        -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending |
        Select-Object -First 1
    if (-not $tool) {
        throw "Required Android SDK tool '$toolName' was not found under $root."
    }
    return $tool.FullName
}

function Invoke-CheckedTool {
    param(
        [Parameter(Mandatory = $true)] [string]$Tool,
        [Parameter(Mandatory = $true)] [string[]]$Arguments
    )

    $output = & $Tool @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Android SDK tool failed: $Tool $($Arguments -join ' ')`n$($output -join "`n")"
    }
    return (($output | ForEach-Object { $_.ToString() }) -join "`n").Trim()
}

$apkInfo = Get-Item -LiteralPath $resolvedApk
if ($apkInfo.Length -le 0) {
    throw "The APK is empty."
}

$sdkRoot = Resolve-AndroidSdkRoot
$apkAnalyzer = Resolve-AndroidTool `
    -SdkRoot $sdkRoot `
    -WindowsName "apkanalyzer.bat" `
    -UnixName "apkanalyzer" `
    -RelativeRoot "cmdline-tools"
$apkSigner = Resolve-AndroidTool `
    -SdkRoot $sdkRoot `
    -WindowsName "apksigner.bat" `
    -UnixName "apksigner" `
    -RelativeRoot "build-tools"

$packageId = Invoke-CheckedTool $apkAnalyzer @(
    "manifest", "application-id", $resolvedApk
)
$versionName = Invoke-CheckedTool $apkAnalyzer @(
    "manifest", "version-name", $resolvedApk
)
$versionCode = Invoke-CheckedTool $apkAnalyzer @(
    "manifest", "version-code", $resolvedApk
)
$minimumSdk = Invoke-CheckedTool $apkAnalyzer @(
    "manifest", "min-sdk", $resolvedApk
)
$files = Invoke-CheckedTool $apkAnalyzer @("files", "list", $resolvedApk)
$signer = Invoke-CheckedTool $apkSigner @(
    "verify", "--verbose", "--print-certs", $resolvedApk
)

if ($packageId -ne $expectedPackageId) {
    throw "Expected package '$expectedPackageId', received '$packageId'."
}
if ($versionName -ne $expectedVersionName) {
    throw "Expected version '$expectedVersionName', received '$versionName'."
}
if ($versionCode -ne $expectedVersionCode) {
    throw "Expected Android build '$expectedVersionCode', received '$versionCode'."
}
if ($minimumSdk -ne $expectedMinimumSdk) {
    throw "Expected minimum SDK '$expectedMinimumSdk', received '$minimumSdk'."
}

$abis = @(
    [regex]::Matches($files, '(?m)^/lib/([^/]+)/libapp\.so\r?$') |
        ForEach-Object { $_.Groups[1].Value } |
        Sort-Object -Unique
)
$expectedAbis = @("arm64-v8a", "armeabi-v7a")
$abiDifference = @(Compare-Object $expectedAbis $abis)
if ($abiDifference.Count -ne 0) {
    throw "Expected only ARM32 and ARM64 Flutter ABIs. Found: $($abis -join ', ')."
}

$certificateMatch = [regex]::Match(
    $signer,
    '(?i)certificate\s+SHA-?256\s+digest[^0-9a-f]*(?<fingerprint>(?:[0-9a-f]{2}[:\s-]?){31}[0-9a-f]{2})'
)
if (-not $certificateMatch.Success) {
    throw "The APK signing certificate fingerprint could not be read."
}
$signerSha256 = ($certificateMatch.Groups['fingerprint'].Value -replace '[^0-9a-fA-F]', '').ToLowerInvariant()
if ($signerSha256 -ne $expectedSignerSha256) {
    throw "The APK is not signed by the pinned TetoTV production certificate."
}

$apkSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedApk).Hash.ToLowerInvariant()
Write-Host "Release APK verification passed"
Write-Host "  Package:    $packageId"
Write-Host "  Version:    $versionName ($versionCode)"
Write-Host "  Minimum SDK: $minimumSdk"
Write-Host "  ABIs:       $($abis -join ', ')"
Write-Host "  SHA-256:    $apkSha256"
