#Requires -Version 7
<#
.SYNOPSIS
    Builds the release assets into .\dist and pins them in the Scoop manifest.

.DESCRIPTION
    dist\QuotaBurndown.ps1                the script, byte for byte
    dist\QuotaBurndown-<version>.zip      the script plus Install.cmd
    dist\SHA256SUMS.txt                   SHA-256 of both, in `sha256sum` format
    bucket\quota-burndown.json            version, URL and hash updated

    Then: commit, push, and
    gh release create v<version> dist\QuotaBurndown.ps1 dist\QuotaBurndown-<version>.zip dist\SHA256SUMS.txt
#>
param([Parameter(Mandatory)][string]$Version)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$script = Join-Path $root 'QuotaBurndown.ps1'

$m = [regex]::Match([IO.File]::ReadAllText($script), "(?m)^\`$AppVersion = '([^']+)'")
if ($m.Groups[1].Value -ne $Version) { throw "QuotaBurndown.ps1 says version '$($m.Groups[1].Value)', not '$Version'." }

$dist = Join-Path $root 'dist'
if (Test-Path $dist) { Remove-Item $dist -Recurse -Force }
$null = New-Item -ItemType Directory $dist
Copy-Item $script $dist

# Install.cmd must have CRLF line endings for cmd.exe, whatever the checkout uses.
$cmdText = ([IO.File]::ReadAllText((Join-Path $root 'Install.cmd')) -replace "`r`n", "`n") -replace "`n", "`r`n"
$zipName = "QuotaBurndown-$Version.zip"
$zipPath = Join-Path $dist $zipName
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::Open($zipPath, 'Create')
try {
    $null = [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $script, 'QuotaBurndown.ps1')
    $entry = $zip.CreateEntry('Install.cmd')
    $w = [IO.StreamWriter]::new($entry.Open(), [Text.Encoding]::ASCII)
    try { $w.Write($cmdText) } finally { $w.Dispose() }
} finally { $zip.Dispose() }

$sums = foreach ($f in 'QuotaBurndown.ps1', $zipName) {
    '{0}  {1}' -f (Get-FileHash (Join-Path $dist $f) -Algorithm SHA256).Hash.ToLowerInvariant(), $f
}
[IO.File]::WriteAllText((Join-Path $dist 'SHA256SUMS.txt'), (($sums -join "`n") + "`n"))

$manifestPath = Join-Path $root 'bucket\quota-burndown.json'
$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
$manifest.version = $Version
$manifest.url = "https://github.com/mondrikrob/quota-burndown/releases/download/v$Version/QuotaBurndown.ps1"
$manifest.hash = ($sums[0] -split '\s+')[0]
[IO.File]::WriteAllText($manifestPath, (($manifest | ConvertTo-Json -Depth 5) -replace "`r`n", "`n") + "`n")

$sums
"Scoop manifest pinned to $Version."
