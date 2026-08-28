[CmdletBinding()]
param(
    [string]$KeystorePath = (Join-Path $env:USERPROFILE '.tetotv\release\tetotv-release.p12'),
    [switch]$ReplaceExisting
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$propertiesPath = Join-Path $repoRoot 'android\key.properties'
$resolvedKeystorePath = [IO.Path]::GetFullPath($KeystorePath)
$keystoreDirectory = Split-Path -Parent $resolvedKeystorePath

if ((Test-Path -LiteralPath $resolvedKeystorePath) -and -not $ReplaceExisting) {
    throw 'A release keystore already exists. Use -ReplaceExisting only for an intentional pre-distribution rotation.'
}
if ((Test-Path -LiteralPath $propertiesPath) -and -not $ReplaceExisting) {
    throw 'android/key.properties already exists. Confirm its key is not the production identity before using -ReplaceExisting.'
}

$keytool = if ($env:JAVA_HOME) {
    Join-Path $env:JAVA_HOME 'bin\keytool.exe'
} else {
    (Get-Command keytool.exe -ErrorAction Stop).Source
}
if (-not (Test-Path -LiteralPath $keytool)) {
    throw 'keytool.exe was not found. Configure the JDK used by Flutter first.'
}

[IO.Directory]::CreateDirectory($keystoreDirectory) | Out-Null

$random = [Security.Cryptography.RandomNumberGenerator]::Create()
$passwordBytes = New-Object byte[] 36
try {
    $random.GetBytes($passwordBytes)
} finally {
    $random.Dispose()
}
$password = [Convert]::ToBase64String($passwordBytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
$alias = 'tetotv_release'

if (Test-Path -LiteralPath $resolvedKeystorePath) {
    Remove-Item -LiteralPath $resolvedKeystorePath -Force
}

& $keytool -genkeypair `
    -keystore $resolvedKeystorePath `
    -storetype PKCS12 `
    -storepass $password `
    -keypass $password `
    -alias $alias `
    -keyalg RSA `
    -keysize 4096 `
    -sigalg SHA256withRSA `
    -validity 10000 `
    -dname 'CN=TetoTV Release, OU=Release, O=TetoTV' `
    -noprompt
if ($LASTEXITCODE -ne 0) {
    Remove-Item -LiteralPath $resolvedKeystorePath -Force -ErrorAction SilentlyContinue
    throw 'keytool failed to create the release keystore.'
}

$propertiesKeystorePath = $resolvedKeystorePath.Replace('\', '/')
$properties = @(
    "storePassword=$password"
    "keyPassword=$password"
    "keyAlias=$alias"
    "storeFile=$propertiesKeystorePath"
) -join [Environment]::NewLine
[IO.File]::WriteAllText(
    $propertiesPath,
    "$properties$([Environment]::NewLine)",
    [Text.UTF8Encoding]::new($false)
)

# Restrict the local signing directory without printing identities or secrets
# into normal build output.
$identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
& icacls.exe $keystoreDirectory /inheritance:r /grant:r "${identity}:(OI)(CI)F" 'SYSTEM:(OI)(CI)F' | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw 'The key was created, but its Windows ACL could not be restricted.'
}

Write-Host 'A unique TetoTV release key is configured.'
Write-Host 'Back up the keystore and android/key.properties separately in encrypted offline storage.'
Write-Host 'Never commit or regenerate them after distributing an APK.'
