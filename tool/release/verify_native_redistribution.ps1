[CmdletBinding()]
param(
    [switch]$StageBundle,
    [string]$OutputDirectory = "",
    [switch]$RequireResolvedBinaries,
    [string]$BundlePath = "",
    [string]$ReleaseTag = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$manifestPath = Join-Path $PSScriptRoot "native_playback_manifest.json"
$manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
$failures = [System.Collections.Generic.List[string]]::new()
$fixedZipTimestamp = [DateTimeOffset]::new(2000, 1, 1, 0, 0, 0, [TimeSpan]::Zero)

function Test-Condition([bool]$Condition, [string]$Message) {
    if (-not $Condition) { $script:failures.Add($Message) }
}

function Test-FileText([string]$RelativePath, [string]$Literal) {
    $path = Join-Path $script:repoRoot $RelativePath
    Test-Condition (Test-Path -LiteralPath $path -PathType Leaf) "Missing $RelativePath"
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $text = Get-Content -Raw -LiteralPath $path
        Test-Condition $text.Contains($Literal) "$RelativePath does not contain: $Literal"
    }
}

function Test-Hash([string]$Path, [string]$Expected, [string]$Label) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $script:failures.Add("Missing $Label at $Path")
        return
    }
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
    Test-Condition ($actual -eq $Expected.ToLowerInvariant()) "$Label SHA-256 mismatch: $actual"
}

function Get-ZipEntrySha256([IO.Compression.ZipArchiveEntry]$Entry) {
    $algorithm = [Security.Cryptography.SHA256]::Create()
    $stream = $Entry.Open()
    try {
        $digest = $algorithm.ComputeHash($stream)
        return ([BitConverter]::ToString($digest) -replace '-', '').ToLowerInvariant()
    }
    finally {
        $stream.Dispose()
        $algorithm.Dispose()
    }
}

function Read-ZipEntryText([IO.Compression.ZipArchiveEntry]$Entry) {
    $stream = $Entry.Open()
    try {
        $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $true)
        try {
            return $reader.ReadToEnd()
        }
        finally {
            $reader.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

function Test-NativeSourceBundle([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Native source bundle does not exist: $Path"
    }
    if ((Get-Item -LiteralPath $Path).Length -le 0) {
        throw "Native source bundle is empty: $Path"
    }

    $bundleFailures = [System.Collections.Generic.List[string]]::new()
    $archive = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $entries = @($archive.Entries | Where-Object { -not $_.FullName.EndsWith('/') })
        $entryNames = @($entries | ForEach-Object FullName)
        if (@($entryNames | Sort-Object -Unique).Count -ne $entryNames.Count) {
            $bundleFailures.Add("Archive contains duplicate entry names")
        }

        foreach ($name in $entryNames) {
            if (
                $name.StartsWith('/') -or
                $name.Contains('\') -or
                $name -match '(^|/)\.\.(/|$)' -or
                $name -notmatch '^(?:sources/|licenses/|[^/]+$)'
            ) {
                $bundleFailures.Add("Unsafe or unexpected archive path: $name")
            }
        }

        $requiredRootEntries = @(
            "native_playback_manifest.json",
            "NATIVE_PLAYBACK_REDISTRIBUTION.md",
            "DIRECT_TORRENT_STREAMING.md",
            "RESOLVED_SOURCE_REFS.json",
            "SOURCE_SNAPSHOT_HASHES.sha256",
            "README.txt"
        )
        foreach ($name in $requiredRootEntries) {
            if ($entryNames -cnotcontains $name) {
                $bundleFailures.Add("Missing archive entry: $name")
            }
        }

        $expectedLicenseNames = @(
            $script:manifest.licenseAssets |
                ForEach-Object { "licenses/$([IO.Path]::GetFileName($_.path))" }
        )
        foreach ($name in $expectedLicenseNames) {
            if ($entryNames -cnotcontains $name) {
                $bundleFailures.Add("Missing license entry: $name")
            }
        }
        $actualLicenseNames = @($entryNames | Where-Object { $_.StartsWith('licenses/') })
        foreach ($name in $actualLicenseNames) {
            if ($expectedLicenseNames -cnotcontains $name) {
                $bundleFailures.Add("Unexpected license entry: $name")
            }
        }

        $manifestEntry = $entries |
            Where-Object FullName -CEQ "native_playback_manifest.json" |
            Select-Object -First 1
        if ($null -ne $manifestEntry) {
            $expectedManifestHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $script:manifestPath).Hash.ToLowerInvariant()
            if ((Get-ZipEntrySha256 $manifestEntry) -ne $expectedManifestHash) {
                $bundleFailures.Add("Bundled native_playback_manifest.json does not match this checkout")
            }
        }

        $sourceEntries = @($entries | Where-Object { $_.FullName.StartsWith('sources/') })
        $expectedSourceCount = @($script:manifest.sourceRoots).Count +
            @($script:manifest.libmpvDeclaredDependencyRefs).Count +
            @($script:manifest.sourceArchives).Count
        if ($sourceEntries.Count -ne $expectedSourceCount) {
            $bundleFailures.Add("Expected $expectedSourceCount source snapshots, found $($sourceEntries.Count)")
        }

        $hashEntry = $entries |
            Where-Object FullName -CEQ "SOURCE_SNAPSHOT_HASHES.sha256" |
            Select-Object -First 1
        if ($null -ne $hashEntry) {
            $hashRecords = @{}
            $hashText = Read-ZipEntryText $hashEntry
            foreach ($line in ($hashText -split "`r?`n" | Where-Object { $_ -ne '' })) {
                $match = [regex]::Match($line, '^(?<hash>[0-9a-f]{64})  (?<name>sources/[^/]+)$')
                if (-not $match.Success) {
                    $bundleFailures.Add("Invalid source hash record: $line")
                    continue
                }
                $name = $match.Groups['name'].Value
                if ($hashRecords.ContainsKey($name)) {
                    $bundleFailures.Add("Duplicate source hash record: $name")
                    continue
                }
                $hashRecords[$name] = $match.Groups['hash'].Value
            }
            foreach ($entry in $sourceEntries) {
                if (-not $hashRecords.ContainsKey($entry.FullName)) {
                    $bundleFailures.Add("Missing source hash record: $($entry.FullName)")
                    continue
                }
                if ((Get-ZipEntrySha256 $entry) -ne $hashRecords[$entry.FullName]) {
                    $bundleFailures.Add("Source snapshot hash mismatch: $($entry.FullName)")
                }
            }
            foreach ($name in $hashRecords.Keys) {
                if ($entryNames -cnotcontains $name) {
                    $bundleFailures.Add("Source hash references a missing entry: $name")
                }
            }
        }

        $refsEntry = $entries |
            Where-Object FullName -CEQ "RESOLVED_SOURCE_REFS.json" |
            Select-Object -First 1
        if ($null -ne $refsEntry) {
            try {
                $resolvedRecords = @(Read-ZipEntryText $refsEntry | ConvertFrom-Json)
                if ($resolvedRecords.Count -ne $expectedSourceCount) {
                    $bundleFailures.Add("Expected $expectedSourceCount resolved source records, found $($resolvedRecords.Count)")
                }
                foreach ($record in $resolvedRecords) {
                    $entryName = "sources/$($record.archive)"
                    $sourceEntry = $entries |
                        Where-Object FullName -CEQ $entryName |
                        Select-Object -First 1
                    if ($null -eq $sourceEntry) {
                        $bundleFailures.Add("Resolved source record references a missing entry: $entryName")
                    }
                    elseif (
                        [string]$record.sha256 -notmatch '^[0-9a-f]{64}$' -or
                        (Get-ZipEntrySha256 $sourceEntry) -ne [string]$record.sha256
                    ) {
                        $bundleFailures.Add("Resolved source record digest mismatch: $entryName")
                    }
                }
            }
            catch {
                $bundleFailures.Add("RESOLVED_SOURCE_REFS.json is invalid: $($_.Exception.Message)")
            }
        }
    }
    finally {
        $archive.Dispose()
    }

    if ($bundleFailures.Count -gt 0) {
        throw ("Native source bundle verification failed:`n - " + ($bundleFailures -join "`n - "))
    }
    Write-Host "Verified native source bundle: $Path"
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

Test-Condition ($manifest.schemaVersion -eq 1) "Unsupported native manifest schema"
Test-FileText "pubspec.lock" "media_kit_libs_android_video:"
Test-FileText "pubspec.lock" 'version: "1.3.8"'
Test-FileText "pubspec.yaml" "assets/legal/native/NATIVE_PLAYBACK_NOTICE.txt"
Test-FileText "android/app/build.gradle.kts" 'org.libtorrent4j:libtorrent4j:2.1.0-38'
Test-FileText "android/app/build.gradle.kts" 'org.libtorrent4j:libtorrent4j-android-arm:2.1.0-38'
Test-FileText "android/app/build.gradle.kts" 'org.libtorrent4j:libtorrent4j-android-arm64:2.1.0-38'
$pubspecText = Get-Content -Raw -LiteralPath (Join-Path $repoRoot "pubspec.yaml")

foreach ($license in $manifest.licenseAssets) {
    $path = Join-Path $repoRoot $license.path
    Test-Condition (Test-Path -LiteralPath $path -PathType Leaf) "Missing license asset $($license.path)"
    $hashProperty = $license.PSObject.Properties["sha256"]
    if ($null -ne $hashProperty -and $hashProperty.Value -ne "" -and (Test-Path -LiteralPath $path)) {
        Test-Hash $path $hashProperty.Value $license.path
    }
    Test-Condition $pubspecText.Contains($license.path) "pubspec.yaml does not bundle $($license.path)"
}

foreach ($archive in $manifest.sourceArchives) {
    Test-Condition ($archive.url -like "https://*") "Source archive URL must use HTTPS: $($archive.id)"
    Test-Condition ($archive.size -gt 0) "Source archive size is invalid: $($archive.id)"
    Test-Condition ($archive.sha256 -match '^[0-9a-f]{64}$') "Source archive SHA-256 is invalid: $($archive.id)"
}

$packageConfigPath = Join-Path $repoRoot ".dart_tool\package_config.json"
if (Test-Path -LiteralPath $packageConfigPath) {
    $packageConfig = Get-Content -Raw -LiteralPath $packageConfigPath | ConvertFrom-Json
    $nativePackage = $packageConfig.packages | Where-Object name -eq "media_kit_libs_android_video" | Select-Object -First 1
    Test-Condition ($null -ne $nativePackage) "media_kit_libs_android_video is absent from package_config.json"
    if ($null -ne $nativePackage) {
        $rootUri = [Uri]$nativePackage.rootUri
        $packageRoot = [Uri]::UnescapeDataString($rootUri.LocalPath)
        $pluginGradle = Join-Path $packageRoot "android\build.gradle"
        if (Test-Path -LiteralPath $pluginGradle) {
            $pluginText = Get-Content -Raw -LiteralPath $pluginGradle
            Test-Condition $pluginText.Contains("releases/download/v1.1.7/default-arm64-v8a.jar") "Plugin does not resolve v1.1.7 arm64 JAR"
            Test-Condition $pluginText.Contains("releases/download/v1.1.7/default-armeabi-v7a.jar") "Plugin does not resolve v1.1.7 armv7 JAR"
            Test-Condition $pluginText.Contains("83df25b61193af8fa815e373143ac9af") "Plugin arm64 MD5 differs from manifest evidence"
            Test-Condition $pluginText.Contains("22e21526fefc0a2b8f17adbec9f57590") "Plugin armv7 MD5 differs from manifest evidence"
        } else {
            $failures.Add("Missing resolved plugin Gradle file at $pluginGradle")
        }
    }
} else {
    $failures.Add("Run flutter pub get before verification; .dart_tool/package_config.json is missing")
}

$resolved = 0
foreach ($artifact in $manifest.binaryArtifacts) {
    $candidates = @()
    if ($artifact.id -like "libmpv-*") {
        $candidates += Join-Path $repoRoot "build\media_kit_libs_android_video\v1.1.7\$($artifact.fileName)"
        $candidates += Join-Path $repoRoot "build\media_kit_libs_android_video\output\$($artifact.fileName)"
    } elseif ($artifact.id -like "libtorrent4j-*") {
        $gradleModuleRoot = Join-Path $env:USERPROFILE ".gradle\caches\modules-2\files-2.1\org.libtorrent4j"
        if (Test-Path -LiteralPath $gradleModuleRoot -PathType Container) {
            $candidates += Get-ChildItem -LiteralPath $gradleModuleRoot -Recurse -File -Filter $artifact.fileName |
                Select-Object -ExpandProperty FullName
        }
    }
    $candidate = $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if ($null -ne $candidate) {
        Test-Hash $candidate $artifact.sha256 $artifact.id
        Test-Condition ((Get-Item -LiteralPath $candidate).Length -eq $artifact.size) "$($artifact.id) size mismatch"
        $resolved++
    } elseif ($RequireResolvedBinaries) {
        $failures.Add("Resolved binary not found: $($artifact.id)")
    } else {
        Write-Warning "Resolved binary not present locally; hash not checked: $($artifact.id)"
    }
}

if ($failures.Count -gt 0) {
    throw ("Native redistribution verification failed:`n - " + ($failures -join "`n - "))
}

Write-Host "Native redistribution metadata verified; $resolved resolved binary artifact(s) checked."
foreach ($limit in $manifest.knownProvenanceLimits) {
    Write-Warning $limit
}

if (-not [string]::IsNullOrWhiteSpace($BundlePath)) {
    if (-not [IO.Path]::IsPathRooted($BundlePath)) {
        $BundlePath = Join-Path $repoRoot $BundlePath
    }
    Test-NativeSourceBundle ([IO.Path]::GetFullPath($BundlePath))
}

if (-not $StageBundle) { exit 0 }

if ($ReleaseTag -notmatch '^v(?:1|2)\.\d+\.\d+$') {
    throw "-StageBundle requires -ReleaseTag in Public v1.x.y or Beta v2.x.y form."
}

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $repoRoot "build\release-compliance\$ReleaseTag\native-playback"
}
$outputFull = [IO.Path]::GetFullPath($OutputDirectory)
$allowedRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot "build\release-compliance"))
if (-not $outputFull.StartsWith($allowedRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw "OutputDirectory must be a child of $allowedRoot"
}
if (Test-Path -LiteralPath $outputFull) {
    throw "Refusing to overwrite existing staging directory: $outputFull"
}

$sourceDir = Join-Path $outputFull "sources"
$checkoutDir = Join-Path $outputFull ".checkouts"
$licenseDir = Join-Path $outputFull "licenses"
New-Item -ItemType Directory -Path $sourceDir, $checkoutDir, $licenseDir -Force | Out-Null
Copy-Item -LiteralPath $manifestPath -Destination $outputFull
Copy-Item -LiteralPath (Join-Path $repoRoot "docs\NATIVE_PLAYBACK_REDISTRIBUTION.md") -Destination $outputFull
Copy-Item -LiteralPath (Join-Path $repoRoot "docs\DIRECT_TORRENT_STREAMING.md") -Destination $outputFull
foreach ($license in $manifest.licenseAssets) {
    Copy-Item -LiteralPath (Join-Path $repoRoot $license.path) -Destination $licenseDir
}

$resolvedRefs = [System.Collections.Generic.List[object]]::new()
function Export-GitSnapshot([string]$Id, [string]$Repository, [string]$Ref, [bool]$Immutable) {
    $checkout = Join-Path $script:checkoutDir $Id
    if ($Immutable) {
        & git clone --quiet --no-checkout $Repository $checkout
        if ($LASTEXITCODE -ne 0) { throw "git clone failed for $Id" }
    } else {
        & git clone --quiet --no-checkout --depth 1 --branch $Ref --single-branch $Repository $checkout
    }
    if ($LASTEXITCODE -ne 0) { throw "git clone failed for $Id at $Ref" }
    # Export directly from Git's object database. Checking out every source
    # tree first can exceed Win32 path limits (notably HarfBuzz's test corpus),
    # while `git archive` needs no working-tree files at all.
    $requestedRevision = if ($Immutable) { "$Ref`^{commit}" } else { "HEAD^{commit}" }
    $resolvedRef = (& git -C $checkout rev-parse $requestedRevision).Trim()
    if ($LASTEXITCODE -ne 0) { throw "git revision resolution failed for $Id at $Ref" }
    if ($Immutable -and $resolvedRef -ne $Ref) { throw "$Id resolved to $resolvedRef instead of $Ref" }
    $archive = Join-Path $script:sourceDir "$Id-$resolvedRef.zip"
    & git -C $checkout archive --format=zip --output=$archive $resolvedRef
    if ($LASTEXITCODE -ne 0) { throw "git archive failed for $Id" }
    $script:resolvedRefs.Add([pscustomobject]@{
        id = $Id; repository = $Repository; requestedRef = $Ref
        resolvedCommit = $resolvedRef; immutableInput = $Immutable
        archive = [IO.Path]::GetFileName($archive)
        sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash.ToLowerInvariant()
    })
}

foreach ($source in $manifest.sourceRoots) {
    Export-GitSnapshot $source.id $source.repository $source.revision $true
}
foreach ($source in $manifest.libmpvDeclaredDependencyRefs) {
    $id = ($source.name.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
    Export-GitSnapshot "libmpv-dependency-$id" $source.repository $source.ref $false
}

foreach ($archive in $manifest.sourceArchives) {
    $destination = Join-Path $sourceDir $archive.fileName
    $temporary = "$destination.download"
    if (Test-Path -LiteralPath $temporary) {
        throw "Refusing to overwrite partial source archive: $temporary"
    }
    try {
        Invoke-WebRequest -UseBasicParsing -Uri $archive.url -OutFile $temporary
        Test-Condition ((Get-Item -LiteralPath $temporary).Length -eq $archive.size) "$($archive.id) source archive size mismatch"
        Test-Hash $temporary $archive.sha256 "$($archive.id) source archive"
        if ($failures.Count -gt 0) {
            throw ("Native source archive verification failed:`n - " + ($failures -join "`n - "))
        }
        Move-Item -LiteralPath $temporary -Destination $destination
        $resolvedRefs.Add([pscustomobject]@{
            id = $archive.id; repository = $archive.url; requestedRef = $archive.sha256
            resolvedCommit = $null; immutableInput = $true
            archive = [IO.Path]::GetFileName($destination)
            sha256 = $archive.sha256
        })
    } finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

$resolvedRefs | ConvertTo-Json -Depth 5 | Set-Content -Encoding utf8 -LiteralPath (Join-Path $outputFull "RESOLVED_SOURCE_REFS.json")
$hashLines = Get-ChildItem -Path $sourceDir -File | Sort-Object Name | ForEach-Object {
    "{0}  sources/{1}" -f (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLowerInvariant(), $_.Name
}
$hashLines | Set-Content -Encoding ascii -LiteralPath (Join-Path $outputFull "SOURCE_SNAPSHOT_HASHES.sha256")

$bundleReadme = @"
This bundle contains the exact immutable source roots, source distributions,
and snapshots of each upstream-declared dependency ref recorded for TetoTV's
native playback and optional direct-torrent stacks. Read
NATIVE_PLAYBACK_REDISTRIBUTION.md, DIRECT_TORRENT_STREAMING.md, and
RESOLVED_SOURCE_REFS.json before use.
Mutable-tag inputs and the lack of upstream reproducible-build metadata remain
documented evidence limits; this bundle does not assert bit-for-bit identity.
"@
$bundleReadme | Set-Content -Encoding utf8 -LiteralPath (Join-Path $outputFull "README.txt")

$checkoutFull = [IO.Path]::GetFullPath($checkoutDir)
if (-not $checkoutFull.StartsWith($outputFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Unsafe checkout cleanup target: $checkoutFull"
}
Remove-Item -LiteralPath $checkoutFull -Recurse -Force
$bundlePath = Join-Path (Split-Path $outputFull -Parent) "TetoTV-$ReleaseTag-native-playback-sources.zip"
if (Test-Path -LiteralPath $bundlePath) { throw "Refusing to overwrite $bundlePath" }

# Compress-Archive writes Windows path separators into nested ZIP entry names.
# Build the archive explicitly so release bundles extract with the same
# directory layout on Android, Linux, macOS, and Windows.
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$bundleStream = [IO.File]::Open(
    $bundlePath,
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

Test-NativeSourceBundle $bundlePath
Write-Host "Staged native redistribution bundle: $bundlePath"
Write-Host "SHA-256: $((Get-FileHash -Algorithm SHA256 -LiteralPath $bundlePath).Hash.ToLowerInvariant())"
Write-Warning "A qualified release reviewer must resolve the manifest's provenance limits and verify complete corresponding source before publishing."
