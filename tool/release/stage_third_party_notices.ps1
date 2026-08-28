[CmdletBinding()]
param(
    [switch]$StageBundle,
    [string]$OutputDirectory = "",
    [string]$BundlePath = "",
    [switch]$RequireDiscordSdkBinary
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$failures = [System.Collections.Generic.List[string]]::new()
$fixedZipTimestamp = [DateTimeOffset]::new(2000, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
$discordAarSha256 = "85a5b0c9b2b828c84d27a7d7839d834bd7dac323895a691e2a19e056543d2faa"
$discordAarSize = 29838129

$noticeFiles = @(
    [pscustomobject]@{ Source = "LICENSE"; Destination = "LICENSE"; Marker = "MIT License" }
    [pscustomobject]@{ Source = "docs/THIRD_PARTY_NOTICES.md"; Destination = "docs/THIRD_PARTY_NOTICES.md"; Marker = "libtorrent4j 2.1.0-38" }
    [pscustomobject]@{ Source = "docs/NATIVE_PLAYBACK_REDISTRIBUTION.md"; Destination = "docs/NATIVE_PLAYBACK_REDISTRIBUTION.md"; Marker = "native playback" }
    [pscustomobject]@{ Source = "docs/DIRECT_TORRENT_STREAMING.md"; Destination = "docs/DIRECT_TORRENT_STREAMING.md"; Marker = "libtorrent4j" }
    [pscustomobject]@{ Source = "tool/release/native_playback_manifest.json"; Destination = "provenance/native_playback_manifest.json"; Marker = '"schemaVersion": 1' }
    [pscustomobject]@{ Source = "assets/addon_runtime/ANDROID_JS_RUNTIMES_LICENSE.txt"; Destination = "assets/addon_runtime/ANDROID_JS_RUNTIMES_LICENSE.txt"; Marker = "MIT License" }
    [pscustomobject]@{ Source = "assets/addon_runtime/CRYPTO_JS_LICENSE.txt"; Destination = "assets/addon_runtime/CRYPTO_JS_LICENSE.txt"; Marker = "MIT License" }
    [pscustomobject]@{ Source = "assets/addon_runtime/JS_RUNTIME_NOTICES.txt"; Destination = "assets/addon_runtime/JS_RUNTIME_NOTICES.txt"; Marker = "Package: linkedom" }
    [pscustomobject]@{ Source = "assets/addon_runtime/LINKEDOM_LICENSE.txt"; Destination = "assets/addon_runtime/LINKEDOM_LICENSE.txt"; Marker = "ISC License" }
    [pscustomobject]@{ Source = "assets/addon_runtime/QUICKJS_LICENSE.txt"; Destination = "assets/addon_runtime/QUICKJS_LICENSE.txt"; Marker = "Permission is hereby granted" }
    [pscustomobject]@{ Source = "assets/typescript/SUCRASE_LICENSE.txt"; Destination = "assets/typescript/SUCRASE_LICENSE.txt"; Marker = "MIT License" }
    [pscustomobject]@{ Source = "assets/fonts/OFL.txt"; Destination = "assets/fonts/OFL.txt"; Marker = "SIL OPEN FONT LICENSE" }
    [pscustomobject]@{ Source = "assets/legal/native/GPL-2.0.txt"; Destination = "assets/legal/native/GPL-2.0.txt"; Marker = "GNU GENERAL PUBLIC LICENSE" }
    [pscustomobject]@{ Source = "assets/legal/native/GPL-3.0.txt"; Destination = "assets/legal/native/GPL-3.0.txt"; Marker = "GNU GENERAL PUBLIC LICENSE" }
    [pscustomobject]@{ Source = "assets/legal/native/LGPL-2.1.txt"; Destination = "assets/legal/native/LGPL-2.1.txt"; Marker = "GNU LESSER GENERAL PUBLIC LICENSE" }
    [pscustomobject]@{ Source = "assets/legal/native/LGPL-3.0.txt"; Destination = "assets/legal/native/LGPL-3.0.txt"; Marker = "GNU LESSER GENERAL PUBLIC LICENSE" }
    [pscustomobject]@{ Source = "assets/legal/native/LIBMPV_ANDROID_BUILD_DEFAULT_LICENSE.txt"; Destination = "assets/legal/native/LIBMPV_ANDROID_BUILD_DEFAULT_LICENSE.txt"; Marker = "Permission is hereby granted" }
    [pscustomobject]@{ Source = "assets/legal/native/LIBTORRENT4J_LICENSE.txt"; Destination = "assets/legal/native/LIBTORRENT4J_LICENSE.txt"; Marker = "Copyright (c) 2018-2025 Alden Torres" }
    [pscustomobject]@{ Source = "assets/legal/native/LIBTORRENT_RASTERBAR_LICENSE.txt"; Destination = "assets/legal/native/LIBTORRENT_RASTERBAR_LICENSE.txt"; Marker = "Copyright (c) 2003-2020, Arvid Norberg" }
    [pscustomobject]@{ Source = "assets/legal/native/BOOST_LICENSE_1_0.txt"; Destination = "assets/legal/native/BOOST_LICENSE_1_0.txt"; Marker = "Boost Software License - Version 1.0" }
    [pscustomobject]@{ Source = "assets/legal/native/OPENSSL_LICENSE.txt"; Destination = "assets/legal/native/OPENSSL_LICENSE.txt"; Marker = "Apache License" }
    [pscustomobject]@{ Source = "assets/legal/native/LIBDATACHANNEL_LICENSE.txt"; Destination = "assets/legal/native/LIBDATACHANNEL_LICENSE.txt"; Marker = "Mozilla Public License Version 2.0" }
    [pscustomobject]@{ Source = "assets/legal/native/LIBJUICE_LICENSE.txt"; Destination = "assets/legal/native/LIBJUICE_LICENSE.txt"; Marker = "Mozilla Public License Version 2.0" }
    [pscustomobject]@{ Source = "assets/legal/native/USRSCTP_LICENSE.txt"; Destination = "assets/legal/native/USRSCTP_LICENSE.txt"; Marker = "Copyright (c) 2015" }
    [pscustomobject]@{ Source = "assets/legal/native/LIBSRTP_LICENSE.txt"; Destination = "assets/legal/native/LIBSRTP_LICENSE.txt"; Marker = "Copyright (c) 2001-2017" }
    [pscustomobject]@{ Source = "assets/legal/native/PLOG_LICENSE.txt"; Destination = "assets/legal/native/PLOG_LICENSE.txt"; Marker = "MIT License" }
    [pscustomobject]@{ Source = "assets/legal/native/DIRECT_TORRENT_NATIVE_NOTICE.txt"; Destination = "assets/legal/native/DIRECT_TORRENT_NATIVE_NOTICE.txt"; Marker = "TetoTV direct-torrent native component provenance" }
    [pscustomobject]@{ Source = "assets/legal/native/NATIVE_PLAYBACK_NOTICE.txt"; Destination = "assets/legal/native/NATIVE_PLAYBACK_NOTICE.txt"; Marker = "native playback" }
    [pscustomobject]@{ Source = "third_party/discord_social_sdk/License-Notices.txt"; Destination = "third_party/discord_social_sdk/License-Notices.txt"; Marker = "Open Source Software Disclosure" }
    [pscustomobject]@{ Source = "third_party/discord_social_sdk/README.md"; Destination = "third_party/discord_social_sdk/README.md"; Marker = "85A5B0C9B2B828C84D27A7D7839D834BD7DAC323895A691E2A19E056543D2FAA" }
    [pscustomobject]@{ Source = "third_party/flutter_js/LICENSE"; Destination = "third_party/flutter_js/LICENSE"; Marker = "MIT License" }
    [pscustomobject]@{ Source = "third_party/flutter_js/android/src/main/c/quickjs/LICENSE"; Destination = "third_party/flutter_js/android/src/main/c/quickjs/LICENSE"; Marker = "Permission is hereby granted" }
)

$bundleReadme = (@(
    "This archive contains TetoTV's release-time third-party notices, license texts,"
    "and provenance records. It does not contain the proprietary Discord Social SDK"
    "AAR. Discord SDK access and use remain subject to the terms accepted by the"
    "application owner. See CONTENTS.sha256 to verify every copied source file."
    ""
) -join "`n")

function Add-Failure([string]$Message) {
    $script:failures.Add($Message)
}

function Get-SourcePath([string]$RelativePath) {
    return Join-Path $script:repoRoot $RelativePath.Replace('/', [IO.Path]::DirectorySeparatorChar)
}

function Get-FileSha256([string]$Path) {
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Get-BytesSha256([byte[]]$Bytes) {
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $digest = $algorithm.ComputeHash($Bytes)
        return ([BitConverter]::ToString($digest) -replace '-', '').ToLowerInvariant()
    } finally {
        $algorithm.Dispose()
    }
}

function Get-ZipEntryBytes([IO.Compression.ZipArchiveEntry]$Entry) {
    $entryStream = $Entry.Open()
    try {
        $memory = [IO.MemoryStream]::new()
        try {
            $entryStream.CopyTo($memory)
            return ,$memory.ToArray()
        } finally {
            $memory.Dispose()
        }
    } finally {
        $entryStream.Dispose()
    }
}

$sourceHashes = @{}
foreach ($item in $noticeFiles) {
    $sourcePath = Get-SourcePath $item.Source
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        Add-Failure "Missing notice source: $($item.Source)"
        continue
    }
    $sourceFile = Get-Item -LiteralPath $sourcePath
    if ($sourceFile.Length -eq 0) {
        Add-Failure "Notice source is empty: $($item.Source)"
        continue
    }
    $sourceText = Get-Content -Raw -LiteralPath $sourcePath
    if (-not $sourceText.Contains($item.Marker)) {
        Add-Failure "$($item.Source) does not contain expected marker: $($item.Marker)"
    }
    $sourceHashes[$item.Destination] = Get-FileSha256 $sourcePath
}

$discordAarPath = Get-SourcePath "android/app/libs/discord_partner_sdk.aar"
if (Test-Path -LiteralPath $discordAarPath -PathType Leaf) {
    $actualDiscordSize = (Get-Item -LiteralPath $discordAarPath).Length
    $actualDiscordHash = Get-FileSha256 $discordAarPath
    if ($actualDiscordSize -ne $discordAarSize) {
        Add-Failure "Discord Social SDK AAR size mismatch: $actualDiscordSize"
    }
    if ($actualDiscordHash -ne $discordAarSha256) {
        Add-Failure "Discord Social SDK AAR SHA-256 mismatch: $actualDiscordHash"
    }
} elseif ($RequireDiscordSdkBinary) {
    Add-Failure "Missing Discord Social SDK AAR required for this release check"
} else {
    Write-Warning "Discord Social SDK AAR is absent. This is expected in git-exported source archives; use -RequireDiscordSdkBinary for a release checkout."
}

if ($failures.Count -gt 0) {
    throw ("Third-party notice source verification failed:`n - " + ($failures -join "`n - "))
}

$manifestLines = foreach ($item in ($noticeFiles | Sort-Object Destination)) {
    "{0}  {1}" -f $sourceHashes[$item.Destination], $item.Destination
}
$contentsManifest = ($manifestLines -join "`n") + "`n"
$expectedNames = @($noticeFiles | ForEach-Object Destination) + @("CONTENTS.sha256", "README.txt")

function Test-NoticeBundle([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Notice bundle does not exist: $Path"
    }

    $bundleFailures = [System.Collections.Generic.List[string]]::new()
    $archive = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $entries = @($archive.Entries | Where-Object { -not $_.FullName.EndsWith('/') })
        $actualNames = @($entries | ForEach-Object FullName)

        foreach ($name in $actualNames) {
            if ($name.StartsWith('/') -or $name.Contains('\') -or $name.Contains('../')) {
                $bundleFailures.Add("Unsafe archive path: $name")
            }
            if (@($actualNames | Where-Object { $_ -ceq $name }).Count -gt 1) {
                $bundleFailures.Add("Duplicate archive entry: $name")
            }
        }
        foreach ($name in $script:expectedNames) {
            if ($actualNames -cnotcontains $name) {
                $bundleFailures.Add("Missing archive entry: $name")
            }
        }
        foreach ($name in $actualNames) {
            if ($script:expectedNames -cnotcontains $name) {
                $bundleFailures.Add("Unexpected archive entry: $name")
            }
        }

        foreach ($item in $script:noticeFiles) {
            $entry = $entries | Where-Object FullName -CEQ $item.Destination | Select-Object -First 1
            if ($null -eq $entry) { continue }
            [byte[]]$entryBytes = Get-ZipEntryBytes $entry
            $entryHash = Get-BytesSha256 $entryBytes
            if ($entryHash -ne $script:sourceHashes[$item.Destination]) {
                $bundleFailures.Add("Archive hash mismatch: $($item.Destination)")
            }
        }

        $manifestEntry = $entries | Where-Object FullName -CEQ "CONTENTS.sha256" | Select-Object -First 1
        if ($null -ne $manifestEntry) {
            [byte[]]$manifestBytes = Get-ZipEntryBytes $manifestEntry
            $manifestText = [Text.Encoding]::UTF8.GetString($manifestBytes)
            if ($manifestText -cne $script:contentsManifest) {
                $bundleFailures.Add("CONTENTS.sha256 does not match the verified source files")
            }
        }

        $readmeEntry = $entries | Where-Object FullName -CEQ "README.txt" | Select-Object -First 1
        if ($null -ne $readmeEntry) {
            [byte[]]$readmeBytes = Get-ZipEntryBytes $readmeEntry
            $readmeText = [Text.Encoding]::UTF8.GetString($readmeBytes)
            if ($readmeText -cne $script:bundleReadme) {
                $bundleFailures.Add("README.txt does not match the release-tool template")
            }
        }
    } finally {
        $archive.Dispose()
    }

    if ($bundleFailures.Count -gt 0) {
        throw ("Third-party notice bundle verification failed:`n - " + ($bundleFailures -join "`n - "))
    }
    Write-Host "Verified third-party notice bundle: $Path"
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

Write-Host "Verified $($noticeFiles.Count) third-party notice and provenance source file(s)."

if (-not [string]::IsNullOrWhiteSpace($BundlePath)) {
    if (-not [IO.Path]::IsPathRooted($BundlePath)) {
        $BundlePath = Join-Path $repoRoot $BundlePath
    }
    Test-NoticeBundle ([IO.Path]::GetFullPath($BundlePath))
}

if (-not $StageBundle) { exit 0 }

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $repoRoot "build\release-compliance\third-party-notices"
} elseif (-not [IO.Path]::IsPathRooted($OutputDirectory)) {
    $OutputDirectory = Join-Path $repoRoot $OutputDirectory
}

$outputFull = [IO.Path]::GetFullPath($OutputDirectory)
$allowedRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot "build\release-compliance"))
if (-not $outputFull.StartsWith($allowedRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw "OutputDirectory must be a child of $allowedRoot"
}
if (Test-Path -LiteralPath $outputFull) {
    throw "Refusing to overwrite existing staging directory: $outputFull"
}

$bundleOutputPath = Join-Path (Split-Path $outputFull -Parent) "TetoTV-third-party-notices.zip"
if (Test-Path -LiteralPath $bundleOutputPath) {
    throw "Refusing to overwrite existing notice bundle: $bundleOutputPath"
}

New-Item -ItemType Directory -Path $outputFull | Out-Null
foreach ($item in $noticeFiles) {
    $sourcePath = Get-SourcePath $item.Source
    $destinationPath = Join-Path $outputFull $item.Destination.Replace('/', [IO.Path]::DirectorySeparatorChar)
    $destinationDirectory = Split-Path $destinationPath -Parent
    if (-not (Test-Path -LiteralPath $destinationDirectory)) {
        New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
    }
    Copy-Item -LiteralPath $sourcePath -Destination $destinationPath
}

$utf8NoBom = [Text.UTF8Encoding]::new($false)
[IO.File]::WriteAllText((Join-Path $outputFull "CONTENTS.sha256"), $contentsManifest, $utf8NoBom)
[IO.File]::WriteAllText((Join-Path $outputFull "README.txt"), $bundleReadme, $utf8NoBom)

$bundleStream = [IO.File]::Open(
    $bundleOutputPath,
    [IO.FileMode]::CreateNew,
    [IO.FileAccess]::Write,
    [IO.FileShare]::None
)
try {
    $archive = [IO.Compression.ZipArchive]::new(
        $bundleStream,
        [IO.Compression.ZipArchiveMode]::Create,
        $false
    )
    try {
        $stagedFiles = Get-ChildItem -LiteralPath $outputFull -Recurse -File | ForEach-Object {
            [pscustomobject]@{
                File = $_
                EntryName = $_.FullName.Substring($outputFull.Length + 1).Replace('\', '/')
            }
        } | Sort-Object EntryName

        foreach ($staged in $stagedFiles) {
            $entry = $archive.CreateEntry($staged.EntryName, [IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime = $fixedZipTimestamp
            $entryStream = $entry.Open()
            try {
                $inputStream = [IO.File]::OpenRead($staged.File.FullName)
                try {
                    $inputStream.CopyTo($entryStream)
                } finally {
                    $inputStream.Dispose()
                }
            } finally {
                $entryStream.Dispose()
            }
        }
    } finally {
        $archive.Dispose()
    }
} finally {
    $bundleStream.Dispose()
}

Test-NoticeBundle $bundleOutputPath
Write-Host "Staged third-party notice bundle: $bundleOutputPath"
Write-Host "SHA-256: $(Get-FileSha256 $bundleOutputPath)"
