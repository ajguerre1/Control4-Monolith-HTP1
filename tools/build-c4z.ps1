#Requires -Version 5.1
<#
.SYNOPSIS
    Package the driver as a .c4z for Composer Pro.

.DESCRIPTION
    A .c4z is a plain zip. This script names every file it packs explicitly
    rather than sweeping the working tree, so a development file added later
    cannot leak into a release by accident -- it has to be added here first.

    Entry names use forward slashes regardless of host platform, because that is
    what the controller expects inside the archive.

    The build fails, rather than warns, on three conditions:

      1. A payload file that does not exist.
      2. A module required by a packaged file that is not itself packaged. An
         archive that loads on the bench and fails on a controller is worse than
         one that refuses to build.
      3. A payload file that git does not track. A sibling driver shipped two
         builds containing files a *global* gitignore silently excluded.

    This script never installs. It writes to build/ and stops there.

.PARAMETER OutputName
    File name of the packaged driver. Composer identifies a driver by file name,
    so building under a different one adds a second driver instead of updating
    the installed one.

.EXAMPLE
    powershell -File tools/build-c4z.ps1
#>
[CmdletBinding()]
param(
    [string]$OutputName = 'Monolith.HTP1.c4z'
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.IO.Compression | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null

$repoRoot = Split-Path -Parent $PSScriptRoot

# The exact archive layout the controller expects. Order is the order printed.
$payload = @(
    'driver.xml'
    'driver.lua'
    'htp1/frame.lua'
    'htp1/protocol.lua'
    'htp1/mapping.lua'
    'htp1/state.lua'
    'htp1/transport.lua'
    'htp1/session.lua'
    'htp1/proxy.lua'
    'htp1/log.lua'
    'module/json.lua'
    # Rendered in Composer's Documentation tab; declared by
    # <documentation> in driver.xml, and pinned by tests/test_manifest.lua.
    'www/documentation/index.html'
)

function Get-SourcePath([string]$entry) {
    return (Join-Path $repoRoot ($entry -replace '/', '\'))
}

# --- 1. Every payload file exists --------------------------------------------

$missing = @()
foreach ($entry in $payload) {
    if (-not (Test-Path -LiteralPath (Get-SourcePath $entry) -PathType Leaf)) {
        $missing += $entry
    }
}
if ($missing.Count -gt 0) {
    throw ("Cannot package: missing $($missing.Count) required file(s):`n  " +
           ($missing -join "`n  "))
}

# --- 2. The require graph is closed over the payload -------------------------

$packagedModules = @{}
foreach ($entry in $payload) {
    if ($entry -like '*.lua') {
        $packagedModules[($entry -replace '\.lua$', '') -replace '/', '.'] = $entry
    }
}

$unresolved = @()
foreach ($entry in $payload) {
    if ($entry -notlike '*.lua') { continue }
    $text = Get-Content -LiteralPath (Get-SourcePath $entry) -Raw
    foreach ($match in [regex]::Matches($text, "require\s*\(?\s*['""]([^'""]+)['""]")) {
        $module = $match.Groups[1].Value
        if (-not $packagedModules.ContainsKey($module)) {
            $unresolved += "$entry requires '$module', which is not in the payload"
        }
    }
}
if ($unresolved.Count -gt 0) {
    throw ("Cannot package: the require graph is incomplete:`n  " + ($unresolved -join "`n  "))
}

# --- 3. Git tracks every payload file ----------------------------------------

$untracked = @()
foreach ($entry in $payload) {
    & git -C $repoRoot ls-files --error-unmatch -- $entry | Out-Null
    if ($LASTEXITCODE -ne 0) {
        $untracked += "$entry is not tracked by git (check: git check-ignore -v '$entry')"
    }
}
if ($untracked.Count -gt 0) {
    throw ("Cannot package: $($untracked.Count) payload file(s) git does not track:`n  " +
           ($untracked -join "`n  "))
}

# --- Build the archive -------------------------------------------------------

$buildDir = Join-Path $repoRoot 'build'
if (-not (Test-Path -LiteralPath $buildDir)) {
    New-Item -ItemType Directory -Path $buildDir | Out-Null
}

$outputPath = Join-Path $buildDir $OutputName

# Build to a temporary name and move it into place only once it is complete.
# Writing straight to $outputPath means a failure mid-write -- a full disk, a
# locked file -- leaves a truncated but structurally valid archive under the
# exact name Composer installs from, with the previous good build already
# deleted. Nothing on disk would mark it as partial.
$tempPath = "$outputPath.partial"
if (Test-Path -LiteralPath $tempPath) {
    Remove-Item -LiteralPath $tempPath -Force
}

$archive = [System.IO.Compression.ZipFile]::Open(
    $tempPath, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($entry in $payload) {
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $archive, (Get-SourcePath $entry), $entry,
            [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
    }
}
finally {
    $archive.Dispose()
}

Move-Item -LiteralPath $tempPath -Destination $outputPath -Force

# --- Report ------------------------------------------------------------------

$driverXml = [xml](Get-Content -LiteralPath (Join-Path $repoRoot 'driver.xml') -Raw)

Write-Host ''
Write-Host "Packaged: $outputPath"
Write-Host "Driver version: $($driverXml.devicedata.version)"
Write-Host "Auto update: $($driverXml.devicedata.auto_update)"
Write-Host ''
Write-Host 'Archive contents:'

$reader = [System.IO.Compression.ZipFile]::OpenRead($outputPath)
try {
    foreach ($item in $reader.Entries) {
        Write-Host ('  {0,8}  {1}' -f $item.Length, $item.FullName)
    }
    $entryCount = $reader.Entries.Count
}
finally {
    $reader.Dispose()
}

Write-Host ''
Write-Host "$entryCount entries, $([math]::Round((Get-Item -LiteralPath $outputPath).Length / 1KB, 1)) KB"
Write-Host ''
Write-Host 'The build never installs. Copy the archive into Composer by hand.'
