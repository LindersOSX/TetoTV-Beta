[CmdletBinding()]
param(
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
if (-not [string]::IsNullOrWhiteSpace($NativeLicenseReviewPath)) {
    $arguments.NativeLicenseReviewPath = $NativeLicenseReviewPath
}
if (-not [string]::IsNullOrWhiteSpace($NativeLicenseReviewSignaturePath)) {
    $arguments.NativeLicenseReviewSignaturePath = $NativeLicenseReviewSignaturePath
}
if (-not [string]::IsNullOrWhiteSpace($UnreviewedBetaDeclarationPath)) {
    $arguments.UnreviewedBetaDeclarationPath = $UnreviewedBetaDeclarationPath
}
if ($PublishWithoutIndependentNativeLicenseReview) {
    $arguments.PublishWithoutIndependentNativeLicenseReview = $true
}
if (-not [string]::IsNullOrWhiteSpace($UnreviewedBetaAcknowledgement)) {
    $arguments.UnreviewedBetaAcknowledgement = $UnreviewedBetaAcknowledgement
}

& (Join-Path $PSScriptRoot "publish_release.ps1") @arguments
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
