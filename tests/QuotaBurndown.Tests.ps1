#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Unit tests for QuotaBurndown.ps1. The script is never run: its functions are
# loaded from the parsed source (the $DataLayer block plus a few named functions).
#   Invoke-Pester -Path .\tests

BeforeAll {
    $scriptPath = (Resolve-Path (Join-Path $PSScriptRoot '..\QuotaBurndown.ps1')).Path
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$errors)
    if ($errors) { throw "QuotaBurndown.ps1 does not parse: $($errors[0].Message)" }
    $top = $ast.EndBlock.Statements

    # The data layer is one script block of functions; dot-source its body.
    $dl = $top | Where-Object { $_ -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -eq '$DataLayer' }
    . $dl.Right.Expression.ScriptBlock.GetScriptBlock()

    # Settings and formatting helpers live outside the data layer.
    $top | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -in 'ConvertTo-Number', 'Read-Settings', 'Format-ResetTime' } |
        ForEach-Object { . ([scriptblock]::Create($_.Extent.Text)) }
    $defaults = $top | Where-Object { $_ -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -eq '$DefaultSettings' }
    . ([scriptblock]::Create($defaults.Extent.Text))
}

Describe 'Invoke-ClaudeLoginRenewal' {
    BeforeEach {
        # Stand-ins, defined in the test's scope: nothing real is run or written.
        $script:runs = @()
        $script:logged = @()
        function Find-ClaudeExe { 'claude.exe' }
        function Write-ClaudeCache($c) { }
        function Write-WidgetLog([string]$Message) { $script:logged += $Message }
        function Start-Sleep { }
        $script:cred = Join-Path $TestDrive '.credentials.json'
        $script:now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $script:expired = '{"claudeAiOauth":{"accessToken":"a","refreshToken":"r","expiresAt":' + (($now - 3600) * 1000) + '}}'
        Set-Content $cred $expired
        $script:cache = @{ renewTriedAt = [long]0; renewFailures = 0 }
    }

    It 'runs claude doctor in the widget folder and reports a renewed login' {
        function Invoke-QuietProcess($Exe, $Arguments, $TimeoutSec, $WorkingDirectory) {
            $script:runs += "$Exe $Arguments in $WorkingDirectory"
            # What Claude Code does: write a fresh login.
            Set-Content $script:cred ('{"claudeAiOauth":{"accessToken":"b","refreshToken":"s","expiresAt":' + (($script:now + 28800) * 1000) + '}}')
            @{ ExitCode = 0; Output = '' }
        }
        (Invoke-ClaudeLoginRenewal $cred $cache $now).State | Should -Be 'renewed'
        $script:runs | Should -HaveCount 1
        $script:runs[0] | Should -Be ('claude.exe doctor in ' + (Join-Path $HOME '.quota-burndown'))
        $cache.renewTriedAt | Should -Be 0
        $cache.renewFailures | Should -Be 0
        $script:logged -join ' ' | Should -Match 'Renewed the Claude Code login'
    }

    It 'reports failure when the login is still expired afterwards' {
        function Invoke-QuietProcess($Exe, $Arguments, $TimeoutSec, $WorkingDirectory) { $script:runs += 1; @{ ExitCode = 1; Output = '' } }
        $res = Invoke-ClaudeLoginRenewal $cred $cache $now
        $res.State | Should -Be 'failed'
        $res.Detail | Should -Match 'exit code 1'
        $res.RetryAt | Should -Be ($now + 300)   # first failure: try again in 5 minutes
        $cache.renewFailures | Should -Be 1
    }

    It 'retries after 5 minutes twice, then every 30 minutes' {
        function Invoke-QuietProcess($Exe, $Arguments, $TimeoutSec, $WorkingDirectory) { $script:runs += 1; @{ ExitCode = 0; Output = '' } }
        $cache.renewFailures = 1; $cache.renewTriedAt = $now - 120
        $res = Invoke-ClaudeLoginRenewal $cred $cache $now
        $res.State | Should -Be 'waiting'
        $res.RetryAt | Should -Be ($now - 120 + 300)
        $script:runs | Should -HaveCount 0

        $cache.renewTriedAt = $now - 301
        $res = Invoke-ClaudeLoginRenewal $cred $cache $now
        $res.State | Should -Be 'failed'
        $cache.renewFailures | Should -Be 2
        $res.RetryAt | Should -Be ($now + 300)

        $cache.renewTriedAt = $now - 301
        $res = Invoke-ClaudeLoginRenewal $cred $cache $now
        $cache.renewFailures | Should -Be 3
        $res.RetryAt | Should -Be ($now + 1800)
        $script:runs | Should -HaveCount 2

        $cache.renewTriedAt = $now - 600
        (Invoke-ClaudeLoginRenewal $cred $cache $now).State | Should -Be 'waiting'
    }

    It 'counts a claude doctor that hangs or fails to start as a failure' {
        function Invoke-QuietProcess($Exe, $Arguments, $TimeoutSec, $WorkingDirectory) { throw 'claude.exe timed out after 60 s' }
        $res = Invoke-ClaudeLoginRenewal $cred $cache $now
        $res.State | Should -Be 'failed'
        $res.Detail | Should -Match 'timed out'
        $cache.renewFailures | Should -Be 1
    }

    It 'says so when the claude command is not installed' {
        function Find-ClaudeExe { $null }
        (Invoke-ClaudeLoginRenewal $cred $cache $now).State | Should -Be 'missing'
    }

    It 'never changes the credentials file itself' {
        function Invoke-QuietProcess($Exe, $Arguments, $TimeoutSec, $WorkingDirectory) { @{ ExitCode = 0; Output = '' } }
        $null = Invoke-ClaudeLoginRenewal $cred $cache $now
        (Get-Content $cred -Raw).Trim() | Should -BeExactly $expired
    }
}

Describe 'Get-WindowForecast' {
    BeforeAll {
        function New-Window([double]$Percent, [double]$MinutesLeft, [int]$Minutes = 300) {
            [pscustomobject]@{ Label = '5-hour'; Percent = $Percent; Minutes = $Minutes; ResetsAt = [DateTimeOffset]::UtcNow.AddMinutes($MinutesLeft) }
        }
        function New-History($Window, [double]$MinutesAgo, [double]$Percent) {
            $h = New-Object System.Collections.ArrayList
            $null = $h.Add([pscustomobject]@{
                    Tool = 'Claude Code'; Label = $Window.Label; At = [DateTimeOffset]::UtcNow.AddMinutes(-$MinutesAgo)
                    Percent = $Percent; ResetsAt = $Window.ResetsAt.ToUnixTimeSeconds()
                })
            , $h
        }
    }

    It 'is ok when the recent rate stays well inside the window' {
        $w = New-Window 30 150                       # half the window gone, 30% used
        $f = Get-WindowForecast (New-History $w 50 25) 'Claude Code' $w ([DateTimeOffset]::UtcNow)
        $f.Level | Should -Be 'ok'
        $f.RunsOut | Should -BeFalse
        $f.Method | Should -Be 'recent'
        $f.Projected | Should -BeLessThan 100
    }

    It 'alerts when over the even pace and running out well before the reset' {
        $w = New-Window 70 150                       # even pace would be 50%
        $f = Get-WindowForecast (New-History $w 30 55) 'Claude Code' $w ([DateTimeOffset]::UtcNow)
        $f.Level | Should -Be 'alert'
        $f.RunsOut | Should -BeTrue
        $f.HitAt | Should -BeLessThan $w.ResetsAt
    }

    It 'is tight when under the even pace but running out shortly before the reset' {
        $w = New-Window 40 150
        $f = Get-WindowForecast (New-History $w 20 31) 'Claude Code' $w ([DateTimeOffset]::UtcNow)
        $f.RunsOut | Should -BeTrue
        $f.Level | Should -Be 'tight'
    }

    It 'alerts when the window is already used up' {
        $w = New-Window 100 60
        (Get-WindowForecast (New-History $w 30 90) 'Claude Code' $w ([DateTimeOffset]::UtcNow)).Level | Should -Be 'alert'
    }

    It 'falls back to the average rate without enough history' {
        $w = New-Window 10 150
        $f = Get-WindowForecast (New-Object System.Collections.ArrayList) 'Claude Code' $w $null
        $f.Method | Should -Be 'average'
        $f.Level | Should -Be 'ok'
    }

    It 'ignores history from another tool or an earlier window' {
        $w = New-Window 40 150
        $h = New-History $w 20 31
        $h[0].Tool = 'Codex'
        (Get-WindowForecast $h 'Claude Code' $w ([DateTimeOffset]::UtcNow)).Method | Should -Be 'average'
    }

    It 'returns nothing for a window that has already reset' {
        $w = New-Window 50 -5
        Get-WindowForecast (New-Object System.Collections.ArrayList) 'Claude Code' $w $null | Should -BeNullOrEmpty
    }
}

Describe 'Update-Claude with an expired login' {
    BeforeEach {
        $script:savedConfigDir = $env:CLAUDE_CONFIG_DIR
        $env:CLAUDE_CONFIG_DIR = $TestDrive
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        Set-Content (Join-Path $TestDrive '.credentials.json') ('{"claudeAiOauth":{"accessToken":"a","refreshToken":"r","expiresAt":' + (($now - 3600) * 1000) + ',"subscriptionType":"pro"}}')
        function Read-ClaudeCache { @{ fetchedAt = [long]0; blockedUntil = [long]0; body = $null; renewTriedAt = [long]0; renewFailures = 0 } }
        function Write-ClaudeCache($c) { }
    }
    AfterEach { $env:CLAUDE_CONFIG_DIR = $script:savedConfigDir }

    It 'looks at the login file again a minute after a failed renewal' {
        function Invoke-ClaudeLoginRenewal($CredPath, $Cache, $Now) { @{ State = 'failed'; RetryAt = $Now + 300; Detail = 'offline' } }
        $u = Update-Claude 5 $false $true
        $u.Result.Error | Should -Be 'login expired'
        ($u.NextAt - [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) | Should -BeLessOrEqual 61
        $u.Result.Detail | Should -Match 'Next try at'
    }

    It 'does not run claude doctor when renewal is off' {
        function Invoke-ClaudeLoginRenewal($CredPath, $Cache, $Now) { throw 'must not be called' }
        $u = Update-Claude 5 $false $false
        $u.Result.Error | Should -Be 'login expired'
        $u.Result.Detail | Should -Match "Run 'claude' once"
    }
}

Describe 'Get-CodexLive timeout' {
    It 'gives up on a program that never answers, on time' {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        { Get-CodexLive (Join-Path $env:WINDIR 'System32\cmd.exe') 2 } | Should -Throw '*timed out after*waiting for initialize*'
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 8
    }
}

Describe 'Update-Codex retry' {
    BeforeEach {
        # Stand-ins, defined in the test's scope so Update-Codex calls them instead.
        $script:calls = 0
        $script:logged = @()
        function Find-CodexExe { 'codex.exe' }
        function Write-WidgetLog([string]$Message) { $script:logged += $Message }
        function Get-CodexFromLogs { $null }
        function New-LiveAnswer {
            [pscustomobject]@{ rateLimits = [pscustomobject]@{
                    planType = 'plus'
                    primary  = [pscustomobject]@{ windowDurationMins = 300; usedPercent = 12; resetsAt = [DateTimeOffset]::UtcNow.AddHours(2).ToUnixTimeSeconds() }
                } }
        }
    }

    It 'retries once after a stall and uses the second answer' {
        function Get-CodexLive([string]$Exe, [int]$TimeoutSec) {
            $script:calls++
            if ($script:calls -eq 1) { throw 'Codex app-server timed out after 30s waiting for rate limits' }
            New-LiveAnswer
        }
        $r = (Update-Codex 3).Result
        $script:calls | Should -Be 2
        $r.Source | Should -Be 'live'
        $r.Windows[0].Percent | Should -Be 12
        $script:logged -join ' ' | Should -Match 'second try.*timed out after 30s waiting for rate limits'
    }

    It 'does not retry a real error answer from Codex' {
        function Get-CodexLive([string]$Exe, [int]$TimeoutSec) { $script:calls++; throw 'Codex rate-limit request failed: not signed in' }
        $r = (Update-Codex 3).Result
        $script:calls | Should -Be 1
        $r.Error | Should -Be 'unavailable'
        $r.Detail | Should -Match 'not signed in'
    }

    It 'reports both causes when the retry fails too' {
        function Get-CodexLive([string]$Exe, [int]$TimeoutSec) { $script:calls++; throw "Codex app-server exited (code 1) after 0.2s during initialize" }
        $r = (Update-Codex 3).Result
        $script:calls | Should -Be 2
        $r.Detail | Should -Match 'exited.*retry: .*exited'
    }
}

Describe 'Read-Settings' {
    BeforeEach { $SettingsPath = Join-Path $TestDrive 'settings.json' }
    AfterEach { Remove-Item $SettingsPath -ErrorAction SilentlyContinue }

    It 'returns the defaults when there is no file' {
        $s = Read-Settings
        $s.ClaudeRefreshMinutes | Should -Be 5
        $s.Topmost | Should -BeTrue
        $s.ClaudeAutoRenewLogin | Should -BeNullOrEmpty
        $s.CheckForUpdates | Should -BeNullOrEmpty
        $s.StripAllTaskbars | Should -BeFalse
    }

    It 'returns the defaults when the file is not JSON' {
        Set-Content $SettingsPath 'not json {'
        (Read-Settings).CodexRefreshMinutes | Should -Be 3
    }

    It 'clamps numbers, rejects wrong types and drops unknown keys' {
        Set-Content $SettingsPath '{"Topmost":"yes","ClaudeRefreshMinutes":1,"CodexRefreshMinutes":"abc","Left":1e12,"StripOffset":true,"ClaudePlanUsdPerMonth":-5,"Unknown":1}'
        $s = Read-Settings
        $s.Topmost | Should -BeTrue
        $s.ClaudeRefreshMinutes | Should -Be 5
        $s.CodexRefreshMinutes | Should -Be 3
        $s.Left | Should -Be 100000
        $s.StripOffset | Should -Be 8
        $s.ClaudePlanUsdPerMonth | Should -Be 0
        $s.Contains('Unknown') | Should -BeFalse
    }

    It 'moves the old default refresh of 15 minutes to 5 once' {
        Set-Content $SettingsPath '{"ClaudeRefreshMinutes":15}'
        (Read-Settings).ClaudeRefreshMinutes | Should -Be 5
    }

    It 'keeps a refresh of 15 minutes chosen after the migration, and other values' {
        Set-Content $SettingsPath '{"ClaudeRefreshMinutes":15,"SettingsVersion":2}'
        (Read-Settings).ClaudeRefreshMinutes | Should -Be 15
        Set-Content $SettingsPath '{"ClaudeRefreshMinutes":30}'
        (Read-Settings).ClaudeRefreshMinutes | Should -Be 30
    }

    It 'keeps the opt-in switches only when they are real booleans' {
        Set-Content $SettingsPath '{"ClaudeAutoRenewLogin":"true","CheckForUpdates":true}'
        $s = Read-Settings
        $s.ClaudeAutoRenewLogin | Should -BeNullOrEmpty
        $s.CheckForUpdates | Should -BeTrue
    }
}

Describe 'ConvertTo-CsvLabel' {
    It 'removes <Name>' -ForEach @(
        @{ Name = 'a leading formula character'; In = '=SUM(A1)'; Out = 'SUM(A1)' }
        @{ Name = 'repeated formula characters'; In = '==1+1'; Out = '1+1' }
        @{ Name = 'mixed formula characters'; In = '+-@cmd'; Out = 'cmd' }
        @{ Name = 'a leading tab'; In = "`t=1"; Out = '1' }
        @{ Name = 'quotes, commas and line breaks'; In = "a,`"b`"`r`nc"; Out = 'a  b   c' }
    ) {
        ConvertTo-CsvLabel $In | Should -Be $Out
    }

    It 'leaves normal labels alone' {
        ConvertTo-CsvLabel ('Weekly ' + [char]0x00B7 + ' Opus') | Should -Be ('Weekly ' + [char]0x00B7 + ' Opus')
        ConvertTo-CsvLabel '5-hour' | Should -Be '5-hour'
    }
}

Describe 'Format-ResetTime' {
    It 'shows only the time for today' {
        $at = [DateTimeOffset]::new([DateTime]::Today.AddHours(19).AddMinutes(5))
        Format-ResetTime $at | Should -Be '19:05'
    }

    It 'adds the weekday for a later day' {
        $local = [DateTime]::Today.AddDays(2).AddHours(7).AddMinutes(30)
        Format-ResetTime ([DateTimeOffset]::new($local)) | Should -Be ('{0:ddd} 07:30' -f $local)
    }
}

Describe 'ConvertTo-ReleaseVersion' {
    It 'accepts <Tag>' -ForEach @(@{ Tag = 'v1.3.0'; Out = '1.3.0' }, @{ Tag = '1.10.2'; Out = '1.10.2' }) {
        ConvertTo-ReleaseVersion $Tag | Should -Be $Out
    }
    It 'rejects <Tag>' -ForEach @(@{ Tag = 'v1.3' }, @{ Tag = 'v1.3.0-beta' }, @{ Tag = 'v1.3.0; calc' }, @{ Tag = '' }) {
        ConvertTo-ReleaseVersion $Tag | Should -BeNullOrEmpty
    }
}
