[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ApkPath,

    [Parameter(Mandatory = $true)]
    [string]$NativeSourcePath,

    [string]$OutputPath = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$resolvedApk = (Resolve-Path -LiteralPath $ApkPath).Path
$resolvedNativeSource = (Resolve-Path -LiteralPath $NativeSourcePath).Path
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path (Split-Path $resolvedApk -Parent) "SHA256SUMS"
}
elseif (-not [IO.Path]::IsPathRooted($OutputPath)) {
    $OutputPath = Join-Path (Get-Location).Path $OutputPath
}
$resolvedOutput = [IO.Path]::GetFullPath($OutputPath)
if (Test-Path -LiteralPath $resolvedOutput) {
    throw "Refusing to overwrite existing checksum manifest: $resolvedOutput"
}

$apkName = [IO.Path]::GetFileName($resolvedApk)
$sourceName = [IO.Path]::GetFileName($resolvedNativeSource)
if ($apkName -notmatch '^TetoTV-v[12]\.\d+\.\d+-universal\.apk$') {
    throw "APK name is not canonical: $apkName"
}
if ($sourceName -notmatch '^TetoTV-v[12]\.\d+\.\d+-native-playback-sources\.zip$') {
    throw "Native source bundle name is not canonical: $sourceName"
}
$apkTag = [regex]::Match($apkName, '^TetoTV-(v[12]\.\d+\.\d+)-').Groups[1].Value
$sourceTag = [regex]::Match($sourceName, '^TetoTV-(v[12]\.\d+\.\d+)-').Groups[1].Value
if ($apkTag -cne $sourceTag) {
    throw "APK and native source bundle versions do not match."
}

$apkSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedApk).Hash.ToLowerInvariant()
$sourceSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedNativeSource).Hash.ToLowerInvariant()
$contents = (@(
    "$apkSha256  $apkName"
    "$sourceSha256  $sourceName"
) -join "`n") + "`n"
$outputDirectory = Split-Path $resolvedOutput -Parent
if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}
[IO.File]::WriteAllText($resolvedOutput, $contents, [Text.ASCIIEncoding]::new())

Write-Host "Wrote release checksums: $resolvedOutput"
Write-Host "  $apkSha256  $apkName"
Write-Host "  $sourceSha256  $sourceName"
