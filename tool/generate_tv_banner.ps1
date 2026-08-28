Add-Type -AssemblyName System.Drawing

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$sourcePath = Join-Path $repoRoot 'assets\branding\tetotv_tv_banner.png'
$outputDirectory = Join-Path $repoRoot 'android\app\src\main\res\drawable-xhdpi'
$outputPath = Join-Path $outputDirectory 'tv_banner.png'

if (-not (Test-Path -LiteralPath $sourcePath)) {
    throw "Missing TetoTV banner source: $sourcePath"
}

New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
$source = [System.Drawing.Image]::FromFile($sourcePath)
$target = [System.Drawing.Bitmap]::new(320, 180)
$graphics = [System.Drawing.Graphics]::FromImage($target)
$graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic

try {
    $graphics.DrawImage($source, 0, 0, 320, 180)
    $target.Save($outputPath, [System.Drawing.Imaging.ImageFormat]::Png)
}
finally {
    $graphics.Dispose()
    $target.Dispose()
    $source.Dispose()
}

Write-Output "Generated $outputPath"
