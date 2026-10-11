# Release packaging needs PowerShell 7, as declared by tools/Build-Release.ps1.
Describe 'Release packaging' {
    BeforeAll {
        $repo = Split-Path $PSScriptRoot
        $stage = Join-Path $TestDrive 'release'
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $stage 'tools'), (Join-Path $stage 'bucket')
        foreach ($name in 'QuotaBurndown.ps1', 'Install.cmd', 'README.md', 'LICENSE', 'SECURITY.md') {
            Copy-Item -LiteralPath (Join-Path $repo $name) -Destination $stage
        }
        Copy-Item -LiteralPath (Join-Path $repo 'tools\Build-Release.ps1') -Destination (Join-Path $stage 'tools')
        Copy-Item -LiteralPath (Join-Path $repo 'bucket\quota-burndown.json') -Destination (Join-Path $stage 'bucket')
        Copy-Item -LiteralPath (Join-Path $repo 'docs') -Destination (Join-Path $stage 'docs') -Recurse
        $version = [regex]::Match([IO.File]::ReadAllText((Join-Path $stage 'QuotaBurndown.ps1')), "(?m)^\`$AppVersion = '([^']+)'").Groups[1].Value
        $builder = Join-Path $stage 'tools\Build-Release.ps1'
    }
    It 'ships matching standalone and zipped script bytes, docs and checksums' -Skip:($PSVersionTable.PSVersion.Major -lt 7) {
        $null = & $builder -Version $version
        $dist = Join-Path $stage 'dist'
        $hash = (Get-FileHash (Join-Path $dist 'QuotaBurndown.ps1') -Algorithm SHA256).Hash.ToLowerInvariant()
        (Get-Content (Join-Path $stage 'bucket\quota-burndown.json') -Raw | ConvertFrom-Json).hash | Should -Be $hash
        $zip = [IO.Compression.ZipFile]::OpenRead((Join-Path $dist "QuotaBurndown-$version.zip"))
        try {
            foreach ($name in 'QuotaBurndown.ps1', 'Install.cmd', 'README.md', 'LICENSE', 'SECURITY.md', 'docs/logo.png', 'docs/limit-reached-dark.png', 'docs/RELEASE_REVIEW.md') { $zip.GetEntry($name) | Should -Not -BeNullOrEmpty }
            $stream = $zip.GetEntry('QuotaBurndown.ps1').Open(); $hasher = [Security.Cryptography.SHA256]::Create()
            try { ([BitConverter]::ToString($hasher.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() | Should -Be $hash }
            finally { $hasher.Dispose(); $stream.Dispose() }
            $reader = [IO.StreamReader]::new($zip.GetEntry('Install.cmd').Open())
            try { $reader.ReadToEnd() | Should -Not -Match '(?<!\r)\n' } finally { $reader.Dispose() }
        } finally { $zip.Dispose() }
        foreach ($line in (Get-Content (Join-Path $dist 'SHA256SUMS.txt'))) {
            $parts = $line -split '\s+', 2
            (Get-FileHash (Join-Path $dist $parts[1]) -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $parts[0]
        }
    }
    It 'rejects a version containing a path before writing release files' -Skip:($PSVersionTable.PSVersion.Major -lt 7) {
        { & $builder -Version '../outside' } | Should -Throw '*pattern*'
    }
}
