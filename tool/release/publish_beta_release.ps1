[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ApkPath,

    [Parameter(Mandatory = $true)]
    [string]$NativeSourcePath,

    [Parameter(Mandatory = $true)]
    [string]$ChecksumsPath,

    [string]$ReleaseNotesPath = "",

    [switch]$Publish
)

$arguments = @{
    Channel = "Beta"
    ApkPath = $ApkPath
    NativeSourcePath = $NativeSourcePath
    ChecksumsPath = $ChecksumsPath
    Publish = $Publish
}
if (-not [string]::IsNullOrWhiteSpace($ReleaseNotesPath)) {
    $arguments.ReleaseNotesPath = $ReleaseNotesPath
}

& (Join-Path $PSScriptRoot "publish_release.ps1") @arguments
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
