[CmdletBinding()]
param(
    [switch]$StageBundle,
    [string]$OutputDirectory = "",
    [switch]$RequireResolvedBinaries,
    [string]$ResolvedBinaryDirectory = "",
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
if (-not [string]::IsNullOrWhiteSpace($ResolvedBinaryDirectory)) {
    if (-not [IO.Path]::IsPathRooted($ResolvedBinaryDirectory)) {
        $ResolvedBinaryDirectory = Join-Path $repoRoot $ResolvedBinaryDirectory
    }
    $ResolvedBinaryDirectory = [IO.Path]::GetFullPath($ResolvedBinaryDirectory)
    if (-not (Test-Path -LiteralPath $ResolvedBinaryDirectory -PathType Container)) {
        throw "ResolvedBinaryDirectory does not exist: $ResolvedBinaryDirectory"
    }
}

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

function Test-SourceZipBuildScriptsUseLf(
    [IO.Compression.ZipArchiveEntry]$OuterEntry,
    [System.Collections.Generic.List[string]]$BundleFailures
) {
    $outerStream = $OuterEntry.Open()
    $memory = [IO.MemoryStream]::new()
    try {
        $outerStream.CopyTo($memory)
        $memory.Position = 0
        $nested = [IO.Compression.ZipArchive]::new(
            $memory,
            [IO.Compression.ZipArchiveMode]::Read,
            $true
        )
        try {
            foreach ($entry in $nested.Entries) {
                if ($entry.FullName.EndsWith('/')) { continue }
                $leaf = [IO.Path]::GetFileName($entry.FullName)
                if (
                    -not $leaf.EndsWith('.sh') -and
                    $leaf -cne 'configure'
                ) {
                    continue
                }

                $scriptStream = $entry.Open()
                $scriptBytes = [IO.MemoryStream]::new()
                try {
                    $scriptStream.CopyTo($scriptBytes)
                    $bytes = $scriptBytes.ToArray()
                    for ($index = 0; $index -lt ($bytes.Length - 1); $index++) {
                        if ($bytes[$index] -eq 13 -and $bytes[$index + 1] -eq 10) {
                            $BundleFailures.Add(
                                "Source snapshot contains a CRLF build script: $($OuterEntry.FullName)!$($entry.FullName)"
                            )
                            break
                        }
                    }
                }
                finally {
                    $scriptBytes.Dispose()
                    $scriptStream.Dispose()
                }
            }
        }
        finally {
            $nested.Dispose()
        }
    }
    catch {
        $BundleFailures.Add(
            "Could not inspect source snapshot build scripts in $($OuterEntry.FullName): $($_.Exception.Message)"
        )
    }
    finally {
        $memory.Dispose()
        $outerStream.Dispose()
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
            "BUILD_NATIVE_PLAYBACK.sh",
            "NATIVE_BUILD_PROVENANCE.json",
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

        $buildScriptEntry = $entries |
            Where-Object FullName -CEQ "BUILD_NATIVE_PLAYBACK.sh" |
            Select-Object -First 1
        if (
            $null -ne $buildScriptEntry -and
            (Get-ZipEntrySha256 $buildScriptEntry) -cne [string]$script:manifest.build.scriptSha256
        ) {
            $bundleFailures.Add("Bundled native build script digest differs from the manifest")
        }

        $provenanceEntry = $entries |
            Where-Object FullName -CEQ "NATIVE_BUILD_PROVENANCE.json" |
            Select-Object -First 1
        if ($null -ne $provenanceEntry) {
            try {
                $bundledProvenance = Read-ZipEntryText $provenanceEntry | ConvertFrom-Json
                if ($bundledProvenance.selfBuilt -ne $true) {
                    $bundleFailures.Add("Bundled build provenance does not assert selfBuilt=true")
                }
                if (
                    [string]$bundledProvenance.buildScriptSha256 -cne
                    [string]$script:manifest.build.scriptSha256
                ) {
                    $bundleFailures.Add("Bundled build provenance uses a different build script")
                }
                $bundledOutputText = @($bundledProvenance.outputChecksums) -join "`n"
                foreach ($artifact in $script:manifest.binaryArtifacts) {
                    if (-not $bundledOutputText.Contains("$($artifact.sha256)  $($artifact.fileName)")) {
                        $bundleFailures.Add("Bundled build provenance does not bind $($artifact.fileName)")
                    }
                }
            }
            catch {
                $bundleFailures.Add("Bundled NATIVE_BUILD_PROVENANCE.json is invalid: $($_.Exception.Message)")
            }
        }

        $sourceEntries = @($entries | Where-Object { $_.FullName.StartsWith('sources/') })
        $expectedSourceCount = @($script:manifest.sourceRoots).Count +
            @($script:manifest.libmpvDeclaredDependencyRefs).Count +
            @($script:manifest.sourceArchives).Count
        if ($sourceEntries.Count -ne $expectedSourceCount) {
            $bundleFailures.Add("Expected $expectedSourceCount source snapshots, found $($sourceEntries.Count)")
        }
        foreach ($entry in ($sourceEntries | Where-Object { $_.FullName.EndsWith('.zip') })) {
            Test-SourceZipBuildScriptsUseLf $entry $bundleFailures
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
                # Windows PowerShell 5.1 emits a top-level JSON array as one
                # pipeline object. Assign it first so @() enumerates the array;
                # wrapping ConvertFrom-Json directly would incorrectly produce
                # one record whose properties are arrays of every source value.
                $parsedResolvedRecords = Read-ZipEntryText $refsEntry | ConvertFrom-Json
                $resolvedRecords = @($parsedResolvedRecords)
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

Test-Condition ($manifest.schemaVersion -eq 2) "Unsupported native manifest schema"
Test-Condition (@($manifest.binaryArtifacts).Count -eq 5) "Native manifest must pin exactly five release binary artifacts"
Test-Condition (@($manifest.binaryArtifacts.id | Sort-Object -Unique).Count -eq 5) "Native binary artifact IDs must be unique"
Test-Condition (@($manifest.binaryArtifacts.fileName | Sort-Object -Unique).Count -eq 5) "Native binary artifact file names must be unique"
foreach ($artifact in $manifest.binaryArtifacts) {
    Test-Condition ([string]$artifact.id -match '^[a-z0-9][a-z0-9-]+$') "Native artifact ID is invalid: $($artifact.id)"
    Test-Condition ([string]$artifact.fileName -match '^[A-Za-z0-9._-]+$') "Native artifact file name is invalid: $($artifact.id)"
    Test-Condition ([string]$artifact.provider -ceq 'TetoTV source build') "Native artifact is not identified as a TetoTV source build: $($artifact.id)"
    Test-Condition ([long]$artifact.size -gt 0) "Native artifact size is invalid: $($artifact.id)"
    Test-Condition ([string]$artifact.sha256 -match '^[0-9a-f]{64}$') "Native artifact SHA-256 is invalid: $($artifact.id)"
}
Test-FileText "pubspec.lock" "media_kit_libs_android_video:"
Test-FileText "pubspec.lock" "third_party/media_kit_libs_android_video"
Test-FileText "pubspec.yaml" "assets/legal/native/NATIVE_PLAYBACK_NOTICE.txt"
Test-FileText "pubspec.yaml" "path: third_party/media_kit_libs_android_video"
Test-FileText "android/app/build.gradle.kts" "TETOTV_NATIVE_ARTIFACT_DIR"
Test-FileText "android/app/build.gradle.kts" "selfBuiltLibtorrentArtifacts"
Test-FileText "tool/native/build_native_playback.sh" "build_libmpv"
Test-FileText "tool/native/build_native_playback.sh" "build_libtorrent4j"
$pubspecText = Get-Content -Raw -LiteralPath (Join-Path $repoRoot "pubspec.yaml")

foreach ($license in $manifest.licenseAssets) {
    $path = Join-Path $repoRoot $license.path
    Test-Condition (Test-Path -LiteralPath $path -PathType Leaf) "Missing license asset $($license.path)"
    $hashProperty = $license.PSObject.Properties["sha256"]
    Test-Condition ($null -ne $hashProperty -and [string]$hashProperty.Value -match '^[0-9a-f]{64}$') "License asset is not SHA-256 pinned: $($license.path)"
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
        # package_config.json permits rootUri to be relative to the config
        # file. Resolve it before reading LocalPath; casting a relative URI
        # directly leaves LocalPath empty on Windows.
        $packageConfigUri = [Uri]::new([IO.Path]::GetFullPath($packageConfigPath))
        $rootUri = [Uri]::new($packageConfigUri, [string]$nativePackage.rootUri)
        $packageRoot = [Uri]::UnescapeDataString($rootUri.LocalPath)
        $pluginGradle = Join-Path $packageRoot "android\build.gradle"
        if (Test-Path -LiteralPath $pluginGradle) {
            $pluginText = Get-Content -Raw -LiteralPath $pluginGradle
            Test-Condition $pluginText.Contains("TETOTV_NATIVE_ARTIFACT_DIR") "Plugin does not resolve the TetoTV source-build output directory"
            Test-Condition $pluginText.Contains('"selfBuilt": true') "Plugin does not require self-build provenance"
            Test-Condition (-not $pluginText.Contains("releases/download/")) "Plugin still contains an upstream binary-download fallback"
        } else {
            $failures.Add("Missing resolved plugin Gradle file at $pluginGradle")
        }
    }
} else {
    $failures.Add("Run flutter pub get before verification; .dart_tool/package_config.json is missing")
}

$resolved = 0
$defaultResolvedDirectory = Join-Path $repoRoot "build\native-playback\outputs"
foreach ($artifact in $manifest.binaryArtifacts) {
    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($ResolvedBinaryDirectory)) {
        $candidates += Join-Path $ResolvedBinaryDirectory $artifact.fileName
    }
    $candidates += Join-Path $defaultResolvedDirectory $artifact.fileName
    $existingCandidates = @(
        $candidates |
            Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
            Sort-Object -Unique
    )
    $candidate = $null
    foreach ($possible in $existingCandidates) {
        if ((Get-Item -LiteralPath $possible).Length -ne $artifact.size) { continue }
        $possibleHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $possible).Hash.ToLowerInvariant()
        if ($possibleHash -ceq [string]$artifact.sha256) {
            $candidate = $possible
            break
        }
    }
    if ($null -ne $candidate) {
        $resolved++
    } elseif ($RequireResolvedBinaries) {
        if ($existingCandidates.Count -gt 0) {
            $failures.Add("No resolved candidate matched the pinned size and SHA-256: $($artifact.id)")
        } else {
            $failures.Add("Resolved binary not found: $($artifact.id)")
        }
    } else {
        Write-Warning "Resolved binary not present locally; hash not checked: $($artifact.id)"
    }
}

$provenanceCandidates = @()
if (-not [string]::IsNullOrWhiteSpace($ResolvedBinaryDirectory)) {
    $provenanceCandidates += Join-Path $ResolvedBinaryDirectory "NATIVE_BUILD_PROVENANCE.json"
}
$provenanceCandidates += Join-Path $defaultResolvedDirectory "NATIVE_BUILD_PROVENANCE.json"
$resolvedProvenance = $provenanceCandidates |
    Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
    Select-Object -First 1
if ($null -ne $resolvedProvenance) {
    try {
        $provenance = Get-Content -Raw -LiteralPath $resolvedProvenance | ConvertFrom-Json
        Test-Condition ($provenance.selfBuilt -eq $true) "Native build provenance does not assert selfBuilt=true"
        Test-Condition ([string]$provenance.buildScriptSha256 -ceq [string]$manifest.build.scriptSha256) "Native build provenance was produced by a different build script"
        $provenanceOutputText = @($provenance.outputChecksums) -join "`n"
        foreach ($artifact in $manifest.binaryArtifacts) {
            Test-Condition $provenanceOutputText.Contains("$($artifact.sha256)  $($artifact.fileName)") "Native build provenance does not bind $($artifact.fileName)"
        }
    }
    catch {
        $failures.Add("Native build provenance is invalid: $($_.Exception.Message)")
    }
}
elseif ($RequireResolvedBinaries) {
    $failures.Add("NATIVE_BUILD_PROVENANCE.json is required with resolved source-built artifacts")
}

if ($failures.Count -gt 0) {
    throw ("Native redistribution verification failed:`n - " + ($failures -join "`n - "))
}
if ($RequireResolvedBinaries -and $resolved -ne 5) {
    throw "Native redistribution verification requires all five pinned binary artifacts; verified $resolved."
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
Copy-Item -LiteralPath (Join-Path $repoRoot "tool\native\build_native_playback.sh") -Destination (Join-Path $outputFull "BUILD_NATIVE_PLAYBACK.sh")
$provenanceSource = if (-not [string]::IsNullOrWhiteSpace($ResolvedBinaryDirectory)) {
    Join-Path $ResolvedBinaryDirectory "NATIVE_BUILD_PROVENANCE.json"
} else {
    Join-Path $repoRoot "build\native-playback\outputs\NATIVE_BUILD_PROVENANCE.json"
}
if (-not (Test-Path -LiteralPath $provenanceSource -PathType Leaf)) {
    throw "Cannot stage native source bundle without NATIVE_BUILD_PROVENANCE.json."
}
Copy-Item -LiteralPath $provenanceSource -Destination $outputFull
foreach ($license in $manifest.licenseAssets) {
    Copy-Item -LiteralPath (Join-Path $repoRoot $license.path) -Destination $licenseDir
}

$resolvedRefs = [System.Collections.Generic.List[object]]::new()
function Assert-ArchiveBuildScriptsUseLf([string]$ArchivePath, [string]$Id) {
    $sourceArchive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        foreach ($entry in $sourceArchive.Entries) {
            if (
                $entry.FullName.EndsWith('/') -or
                $entry.FullName -notmatch '(?i)(^|/)(?:configure|autogen\.sh|bootstrap\.sh|[^/]+\.sh)$'
            ) {
                continue
            }
            $stream = $entry.Open()
            try {
                $memory = [IO.MemoryStream]::new()
                try {
                    $stream.CopyTo($memory)
                    $text = [Text.Encoding]::UTF8.GetString($memory.ToArray())
                }
                finally {
                    $memory.Dispose()
                }
            }
            finally {
                $stream.Dispose()
            }
            if ($text.Contains("`r`n")) {
                throw "$Id source archive contains a CRLF build script: $($entry.FullName)"
            }
        }
    }
    finally {
        $sourceArchive.Dispose()
    }
}

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
    # Force object-database line endings. Windows Git's checkout conversion
    # previously produced hash-valid ZIPs whose Bash shebangs ended in CRLF,
    # making the published source bundle unusable on Linux.
    & git -c core.autocrlf=false -c core.eol=lf -c core.safecrlf=true `
        -C $checkout archive --format=zip --output=$archive $resolvedRef
    if ($LASTEXITCODE -ne 0) { throw "git archive failed for $Id" }
    Assert-ArchiveBuildScriptsUseLf $archive $Id
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
the TetoTV source-build script, and the provenance record for the five native
input JARs used by this release. Read
NATIVE_PLAYBACK_REDISTRIBUTION.md, DIRECT_TORRENT_STREAMING.md, and
RESOLVED_SOURCE_REFS.json before use.
The artifacts are new TetoTV source builds. The documented lack of a second
isolated reproduction and independent license review remains an evidence
limit; this bundle does not claim legal approval or retired-prebuilt identity.
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
Write-Warning "Public and reviewed Beta releases require a qualified reviewer to resolve the manifest's provenance limits and verify complete corresponding source. An explicit unreviewed Beta must disclose that this review was not performed and must not claim compliance."
