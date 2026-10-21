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
    $top | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -in 'ConvertTo-Number', 'Read-Settings', 'Format-ResetTime', 'Get-LimitState', 'Get-TrayText', 'Request-InstallChoices' } |
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

    It 'does not forecast from a stale reading' {
        $w = New-Window 40 150
        Get-WindowForecast (New-History $w 50 20) 'Claude Code' $w ([DateTimeOffset]::UtcNow.AddMinutes(-30)) | Should -BeNullOrEmpty
    }

    It 'does not forecast a cached result with an error' {
        $r = New-UsageResult 'Claude Code'
        $r.Windows = @(New-Window 80 150); $r.UpdatedAt = [DateTimeOffset]::UtcNow; $r.Error = 'offline'
        (Get-Forecasts (New-Object System.Collections.ArrayList) $r).Count | Should -Be 0
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
        $u.Result.Detail | Should -Match "Run 'claude' in a terminal and sign in if prompted"
    }
}

Describe 'Get-CodexLive timeout' {
    It 'gives up on a program that never answers, on time' {
        # Loading only functions skips the startup that creates the data folder.
        # Use an existing isolated folder, including on a clean CI runner.
        Mock Join-Path { $TestDrive } -ParameterFilter { $ChildPath -eq '.quota-burndown' }
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

    It 'prefers the named Codex pool over the legacy pool' {
        function Get-CodexLive {
            $answer = New-LiveAnswer
            $answer | Add-Member NoteProperty rateLimitsByLimitId ([pscustomobject]@{ codex = [pscustomobject]@{
                limitId = 'codex'; primary = [pscustomobject]@{ windowDurationMins = 300; usedPercent = 73; resetsAt = [DateTimeOffset]::UtcNow.AddHours(2).ToUnixTimeSeconds() }
            } })
            $answer
        }
        (Update-Codex 3).Result.Windows[0].Percent | Should -Be 73
    }

    It 'does not present another model-specific pool as the shared Codex limit' {
        function Get-CodexLive {
            $answer = New-LiveAnswer
            $answer | Add-Member NoteProperty rateLimitsByLimitId ([pscustomobject]@{ another = $answer.rateLimits })
            $answer
        }
        (Update-Codex 3).Result.Error | Should -Be 'unavailable'
    }

    It 'rejects a live response with no windows' {
        function Get-CodexLive { [pscustomobject]@{ rateLimits = [pscustomobject]@{ planType = 'plus' } } }
        (Update-Codex 3).Result.Error | Should -Be 'unavailable'
    }
}

Describe 'Read-Settings' {
    BeforeEach { $SettingsPath = Join-Path $TestDrive 'settings.json' }
    AfterEach { Remove-Item $SettingsPath -ErrorAction SilentlyContinue }

    It 'returns the defaults when there is no file' {
        $s = Read-Settings
        $s.ClaudeRefreshMinutes | Should -Be 5
        $s.CodexRefreshMinutes | Should -Be 3
        $s.GeminiRefreshMinutes | Should -Be 3
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
        Set-Content $SettingsPath '{"Topmost":"yes","ClaudeRefreshMinutes":1,"CodexRefreshMinutes":"abc","GeminiRefreshMinutes":0,"Left":1e12,"StripOffset":true,"ClaudePlanUsdPerMonth":-5,"GeminiPlanUsdPerMonth":20,"Unknown":1}'
        $s = Read-Settings
        $s.Topmost | Should -BeTrue
        $s.ClaudeRefreshMinutes | Should -Be 5
        $s.CodexRefreshMinutes | Should -Be 3
        $s.GeminiRefreshMinutes | Should -Be 1
        $s.Left | Should -Be 100000
        $s.StripOffset | Should -Be 8
        $s.ClaudePlanUsdPerMonth | Should -Be 0
        $s.GeminiPlanUsdPerMonth | Should -Be 20
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
        @{ Name = 'a leading space before a formula'; In = ' =1+1'; Out = '1+1' }
        @{ Name = 'mixed control characters before a formula'; In = "`r`n`t@cmd"; Out = 'cmd' }
        @{ Name = 'quotes, commas and line breaks'; In = "a,`"b`"`r`nc"; Out = 'a  b   c' }
    ) {
        ConvertTo-CsvLabel $In | Should -Be $Out
    }

    It 'leaves normal labels alone' {
        ConvertTo-CsvLabel ('Weekly ' + [char]0x00B7 + ' Opus') | Should -Be ('Weekly ' + [char]0x00B7 + ' Opus')
        ConvertTo-CsvLabel '5-hour' | Should -Be '5-hour'
    }
}

Describe 'Usage response validation' {
    It 'rejects invalid percentages: <Name>' -ForEach @(
        @{ Name = 'missing'; Value = $null }, @{ Name = 'boolean'; Value = $true },
        @{ Name = 'negative'; Value = -1 }, @{ Name = 'infinite'; Value = 'Infinity' },
        @{ Name = 'not numeric'; Value = 'abc' }, @{ Name = 'NaN'; Value = 'NaN' }
    ) {
        { New-UsageWindow '5-hour' $Value 300 $null } | Should -Throw '*invalid*'
    }
    It 'accepts a real zero and exactly 100' {
        (New-UsageWindow '5-hour' 0 300 $null).Percent | Should -Be 0
        (New-UsageWindow '5-hour' 100 300 $null).Percent | Should -Be 100
    }
    It 'treats over-limit usage as exhausted rather than unavailable' {
        (New-UsageWindow '5-hour' 101 300 $null).Percent | Should -Be 100
    }
    It 'rejects a nonpositive window duration' {
        { New-UsageWindow 'Weekly' 20 0 $null } | Should -Throw '*invalid*'
    }
    It 'rejects an unknown Claude response instead of caching it as success' {
        { ConvertFrom-ClaudeBody '{"new_schema":true}' } | Should -Throw '*no recognised windows*'
    }
    It 'handles both supported Claude response shapes' {
        $old = ConvertFrom-ClaudeBody '{"five_hour":{"utilization":42,"resets_at":"2026-10-12T12:00:00Z"}}'
        $new = ConvertFrom-ClaudeBody '{"limits":[{"kind":"session","percent":42,"resets_at":"2026-10-12T12:00:00Z"}]}'
        $old[0].Percent | Should -Be 42
        $new[0].Label | Should -Be '5-hour'
    }
}

Describe 'Reached limit state' {
    It 'marks exactly 100 percent as reached even without a forecast' {
        $now = [DateTimeOffset]::UtcNow
        $w = New-UsageWindow 'Weekly' 100 10080 $now.AddDays(1)
        Get-LimitState $w $now 'ok' | Should -Be 'reached'
    }
    It 'keeps 99 percent distinct from reached' {
        $now = [DateTimeOffset]::UtcNow
        $w = New-UsageWindow '5-hour' 99 300 $now.AddHours(1)
        Get-LimitState $w $now 'alert' | Should -Be 'alert'
    }
    It 'clears the reached state after reset' {
        $now = [DateTimeOffset]::UtcNow
        $w = New-UsageWindow '5-hour' 100 300 $now.AddMinutes(-1)
        Get-LimitState $w $now 'alert' | Should -Be 'unknown'
    }
    It 'does not confuse missing data with zero usage' {
        Get-LimitState $null ([DateTimeOffset]::UtcNow) 'ok' | Should -Be 'unknown'
    }
}

Describe 'Tray text compatibility' {
    It 'fits all four exhausted windows in the PowerShell 5.1 tooltip limit' {
        $now = [DateTimeOffset]::UtcNow
        $results = foreach ($name in 'Claude Code', 'Codex') {
            $r = New-UsageResult $name; $r.UpdatedAt = $now
            $r.Windows = @(
                (New-UsageWindow '5-hour' 100 300 $now.AddHours(1))
                (New-UsageWindow 'Weekly' 100 10080 $now.AddDays(1))
            )
            $r
        }
        $text = Get-TrayText $results $now
        $text.Length | Should -BeLessOrEqual 63
        ([regex]::Matches($text, 'FULL')).Count | Should -Be 4
    }
    It 'fits all six exhausted windows across Claude, Codex, and Gemini in the PowerShell 5.1 tooltip limit' {
        $now = [DateTimeOffset]::UtcNow
        $results = foreach ($name in 'Claude Code', 'Codex', 'Gemini') {
            $r = New-UsageResult $name; $r.UpdatedAt = $now
            $r.Windows = @(
                (New-UsageWindow '5-hour' 100 300 $now.AddHours(1))
                (New-UsageWindow 'Weekly' 100 10080 $now.AddDays(1))
            )
            $r
        }
        $text = Get-TrayText $results $now
        $text.Length | Should -BeLessOrEqual 63
        ([regex]::Matches($text, 'FULL')).Count | Should -Be 6
    }
    It 'marks stale values in the tooltip' {
        $now = [DateTimeOffset]::UtcNow
        $r = New-UsageResult 'Codex'; $r.UpdatedAt = $now.AddMinutes(-30)
        $r.Windows = @((New-UsageWindow '5-hour' 40 300 $now.AddHours(1)))
        Get-TrayText @($r) $now | Should -Match 'Codex\?'
    }
}

Describe 'Installer consent defaults' {
    It 'defaults both consent choices to no, autostart to yes, and persists explicit choices' {
        $StartupLink = Join-Path $TestDrive 'missing.lnk'
        $Settings = [ordered]@{ ClaudeAutoRenewLogin = $null; CheckForUpdates = $null; StartWithWindows = $null }
        $script:choices = @(); $script:saves = 0
        function Read-YesNo([string]$Text, [bool]$Default = $false) { $script:choices += $Default; $false }
        function Save-Settings($s) { $script:saves++ }
        Request-InstallChoices
        $script:choices | Should -HaveCount 3
        $script:choices[0] | Should -BeFalse
        $script:choices[1] | Should -BeFalse
        $script:choices[2] | Should -BeTrue
        $Settings.StartWithWindows | Should -BeFalse
        $script:saves | Should -Be 1
    }

    It 'does not ask about autostart when the Startup shortcut already exists' {
        $StartupLink = Join-Path $TestDrive 'existing.lnk'
        Set-Content $StartupLink ''
        $Settings = [ordered]@{ ClaudeAutoRenewLogin = $false; CheckForUpdates = $false; StartWithWindows = $null }
        $script:choices = @()
        function Read-YesNo([string]$Text, [bool]$Default = $false) { $script:choices += $Default; $false }
        function Save-Settings($s) { }
        Request-InstallChoices
        $script:choices | Should -HaveCount 0
        $Settings.StartWithWindows | Should -BeTrue
    }
}

Describe 'Model prices and token accounting' {
    It 'does not attribute all Claude model tokens to a scoped quota' {
        $r = New-UsageResult 'Claude Code'
        $r.Windows = @((New-UsageWindow ('Weekly ' + [char]0x00B7 + ' Opus') 40 10080 ([DateTimeOffset]::UtcNow.AddDays(1))))
        $tokens = Get-WindowTokens $r (New-TokenState) 'claude'
        $tokens.Count | Should -Be 0
    }
    It 'does not guess prices for unknown models or similarly named variants' {
        Get-ClaudePrice 'claude-future-99' | Should -BeNullOrEmpty
        Get-ClaudePrice 'claude-opus-4-9' | Should -BeNullOrEmpty
        Get-CodexPrice 'gpt-future-99' | Should -BeNullOrEmpty
        Get-CodexPrice 'gpt-5.5-pro' | Should -BeNullOrEmpty
        Get-GeminiPrice 'gemini-future-99' | Should -BeNullOrEmpty
        Get-GeminiPrice 'claude-opus-4-6' | Should -BeNullOrEmpty
    }
    It 'prices legacy Opus 4 correctly and accepts its dated ID' {
        (Get-ClaudePrice 'claude-opus-4-20250514')[1] | Should -Be 15
        (Get-ClaudePrice 'claude-opus-4-5')[1] | Should -Be 5
        (Get-ClaudePrice 'claude-sonnet-5-5')[5] | Should -Be 0.10
        (Get-ClaudePrice 'claude-haiku-5-5')[1] | Should -Be 1.0
        (Get-CodexPrice 'codex-auto-review')[1] | Should -Be 0
    }
    It 'prices Gemini models and subscription plans accurately' {
        (Get-GeminiPrice 'Gemini 4 Argon (Medium)')[1] | Should -Be 2.00
        (Get-GeminiPrice 'Gemini 4 Argon (Medium)')[2] | Should -Be 0.10
        (Get-GeminiPrice 'Gemini 4 Argon (Medium)')[3] | Should -Be 10.00
        (Get-GeminiPrice 'gemini-3.8-flash')[1] | Should -Be 0.75
        (Get-GeminiPrice 'gemini-3.8-flash')[3] | Should -Be 3.75
        (Get-PlanUsdPerMonth 'Gemini' 'pro') | Should -Be 20
        (Get-PlanUsdPerMonth 'Gemini' 'ultra') | Should -Be 250
    }
    It 'counts cumulative Codex increments once and separates cached input' {
        $now = [DateTimeOffset]::UtcNow
        $st = New-TokenState
        $st.Files['fixture'] = @{ Entries = @(
            [pscustomobject]@{ At = $now.AddHours(-2); Input = 100; Cached = 20; Output = 10; Total = 110; Model = 'gpt-6.1-sol' },
            [pscustomobject]@{ At = $now; Input = 300; Cached = 70; Output = 50; Total = 350; Model = 'gpt-6.1-sol' },
            [pscustomobject]@{ At = $now.AddSeconds(1); Input = 300; Cached = 70; Output = 50; Total = 350; Model = 'gpt-6.1-sol' }
        ) }
        $sum = Measure-CodexTokens $st $now.AddHours(-1)
        $sum.Input | Should -Be 150
        $sum.CacheRead | Should -Be 50
        $sum.Output | Should -Be 40
        $sum.Total | Should -Be 240
        $sum.Cost | Should -Be 0.000705
    }
    It 'counts unknown model tokens while leaving them unpriced' {
        $now = [DateTimeOffset]::UtcNow
        $st = New-TokenState
        $st.Files['fixture'] = @{ Entries = @([pscustomobject]@{ At = $now; Input = 100; Cached = 20; Output = 10; Total = 110; Model = 'unknown' }) }
        $sum = Measure-CodexTokens $st $now.AddHours(-1)
        $sum.Total | Should -Be 110
        $sum.Unpriced | Should -Be 110
        $sum.Cost | Should -Be 0
    }
    It 'formats since date strings cleanly for today, this week, and older dates' {
        $now = [DateTimeOffset]::Parse('2026-10-21T12:00:00Z')
        Format-SinceDate $null $now | Should -Be ''
        Format-SinceDate ($now.AddHours(-3)) $now | Should -Be ('{0:HH:mm}' -f ($now.AddHours(-3)).LocalDateTime)
        Format-SinceDate ($now.AddDays(-2)) $now | Should -Be ('{0:ddd HH:mm}' -f ($now.AddDays(-2)).LocalDateTime)
        Format-SinceDate ($now.AddDays(-7)) $now | Should -Be ('{0:d MMM HH:mm}' -f ($now.AddDays(-7)).LocalDateTime)
    }
    It 'detects reset drops in history, identifies last reset time, and tracks mid-window resets' {
        $now = [DateTimeOffset]::UtcNow
        $resetTime = $now.AddDays(4)
        $w = New-UsageWindow 'Weekly' 10 10080 $resetTime
        $nominalStart = $resetTime.AddMinutes(-10080)

        # Without history, uses nominal window start and scheduled reset
        $sinceDefault = Get-WindowSince $null 'Claude Code' $w $now
        $sinceDefault.Nominal | Should -Be $nominalStart
        $sinceDefault.LastReset | Should -Be $nominalStart
        $sinceDefault.IsMidWindow | Should -BeFalse

        # With steady usage (no reset drop), uses nominal window start and scheduled reset
        $steadyHistory = @(
            [pscustomobject]@{ Tool = 'Claude Code'; Label = 'Weekly'; At = $now.AddDays(-2); Percent = 20.0; ResetsAt = $resetTime.ToUnixTimeSeconds() },
            [pscustomobject]@{ Tool = 'Claude Code'; Label = 'Weekly'; At = $now.AddDays(-1); Percent = 40.0; ResetsAt = $resetTime.ToUnixTimeSeconds() }
        )
        $sinceSteady = Get-WindowSince $steadyHistory 'Claude Code' $w $now
        $sinceSteady.Nominal | Should -Be $nominalStart
        $sinceSteady.LastReset | Should -Be $nominalStart
        $sinceSteady.IsMidWindow | Should -BeFalse

        # With a reset drop (e.g. from 85% to 2% at 3 hours ago), detects mid-window reset timestamp
        $resetAt = $now.AddHours(-3)
        $resetHistory = @(
            [pscustomobject]@{ Tool = 'Claude Code'; Label = 'Weekly'; At = $now.AddDays(-1); Percent = 85.0; ResetsAt = $resetTime.ToUnixTimeSeconds() },
            [pscustomobject]@{ Tool = 'Claude Code'; Label = 'Weekly'; At = $resetAt; Percent = 2.0; ResetsAt = $resetTime.ToUnixTimeSeconds() },
            [pscustomobject]@{ Tool = 'Claude Code'; Label = 'Weekly'; At = $now.AddHours(-1); Percent = 10.0; ResetsAt = $resetTime.ToUnixTimeSeconds() }
        )
        $sinceReset = Get-WindowSince $resetHistory 'Claude Code' $w $now
        $sinceReset.Nominal | Should -Be $nominalStart
        $sinceReset.LastReset | Should -Be $resetAt
        $sinceReset.IsMidWindow | Should -BeTrue
    }
    It 'retains cumulative tokens while tracking tokens since last reset and reset timestamp' {
        $now = [DateTimeOffset]::UtcNow
        $resetTime = $now.AddDays(3)
        $resetAt = $now.AddHours(-2)
        $r = New-UsageResult 'Codex'
        $r.Windows = @((New-UsageWindow 'Weekly' 5 10080 $resetTime))

        $st = New-TokenState
        $st.Files['fixture'] = @{ Entries = @(
            [pscustomobject]@{ At = $now.AddHours(-4); Input = 500; Cached = 0; Output = 100; Total = 600; Model = 'gpt-6.1-sol' },
            [pscustomobject]@{ At = $now.AddHours(-1); Input = 100; Cached = 0; Output = 20; Total = 120; Model = 'gpt-6.1-sol' }
        ) }

        $history = @(
            [pscustomobject]@{ Tool = 'Codex'; Label = 'Weekly'; At = $now.AddHours(-3); Percent = 95.0; ResetsAt = $resetTime.ToUnixTimeSeconds() },
            [pscustomobject]@{ Tool = 'Codex'; Label = 'Weekly'; At = $resetAt; Percent = 0.0; ResetsAt = $resetTime.ToUnixTimeSeconds() }
        )
        $tokens = Get-WindowTokens $r $st 'codex' $history
        $tok = $tokens['Weekly']
        $tok.Total | Should -Be 720
        $tok.LastReset | Should -Be $resetAt
        $tok.IsMidWindow | Should -BeTrue
        $tok.SinceReset.Total | Should -Be 120
    }
}

Describe 'Gemini quota and token parsing' {
    It 'parses RetrieveUserQuotaSummary groups into 5-hour, Weekly, and scoped Weekly · Argon windows' {
        $now = [DateTimeOffset]::UtcNow
        $r5 = $now.AddHours(4).ToString('o')
        $rw = $now.AddDays(5).ToString('o')
        $payload = [pscustomobject]@{
            userStatus = [pscustomobject]@{
                userTier = [pscustomobject]@{ description = 'Google AI Pro' }
                planStatus = [pscustomobject]@{ planInfo = [pscustomobject]@{ planName = 'Pro' } }
            }
            quotaSummary = [pscustomobject]@{
                groups = @(
                    [pscustomobject]@{
                        displayName = 'Gemini Models'
                        buckets = @(
                            [pscustomobject]@{ bucketId = 'gemini-weekly'; window = 'weekly'; remainingFraction = 0.995345; resetTime = $rw }
                            [pscustomobject]@{ bucketId = 'gemini-5h'; window = '5h'; remainingFraction = 0.9837074; resetTime = $r5 }
                        )
                    }
                    [pscustomobject]@{
                        displayName = 'Claude and GPT models'
                        buckets = @(
                            [pscustomobject]@{ bucketId = '3p-weekly'; window = 'weekly'; remainingFraction = 0.25; resetTime = $rw }
                        )
                    }
                    [pscustomobject]@{
                        displayName = 'Gemini 4 Argon'
                        buckets = @(
                            [pscustomobject]@{ bucketId = 'gemini-argon-wtu-weekly'; window = 'weekly'; remainingFraction = 0.29805547; resetTime = $rw }
                        )
                    }
                )
            }
        }
        $parsed = ConvertFrom-GeminiPayload $payload
        $parsed.Plan | Should -Be 'Pro'
        $parsed.PlanKey | Should -Be 'pro'
        $parsed.Windows | Should -HaveCount 3
        $parsed.Windows[0].Label | Should -Be '5-hour'
        [Math]::Round($parsed.Windows[0].Percent, 2) | Should -Be 1.63
        $parsed.Windows[1].Label | Should -Be 'Weekly'
        [Math]::Round($parsed.Windows[1].Percent, 2) | Should -Be 0.47
        $parsed.Windows[2].Label | Should -Be ('Weekly ' + [char]0x00B7 + ' Argon')
        [Math]::Round($parsed.Windows[2].Percent, 2) | Should -Be 70.19
    }

    It 'parses Antigravity transcript token steps, tracks Model Selection, and ignores non-Gemini models' {
        $savedGeminiDir = (Get-Item Function:\Get-GeminiDir).ScriptBlock
        $savedDataDir = (Get-Item Function:\Get-DataFile).ScriptBlock
        try {
            function Get-GeminiDir { $TestDrive }
            function Get-DataFile([string]$Name) { Join-Path $TestDrive $Name }
            $logDir = Join-Path $TestDrive 'antigravity\brain\conv-1\.system_generated\logs'
            $null = New-Item -ItemType Directory -Force $logDir
            $logFile = Join-Path $logDir 'transcript.jsonl'
            $now = [DateTimeOffset]::UtcNow
            $lines = @(
                ('{"step_index":1,"type":"USER_INPUT","created_at":"' + $now.AddMinutes(-10).ToString('o') + '","content":"changed setting `Model Selection` from None to Gemini 4 Argon (Medium). No need to comment"}')
                ('{"step_index":2,"type":"PLANNER_RESPONSE","created_at":"' + $now.AddMinutes(-9).ToString('o') + '","input_tokens":1000,"cache_read_tokens":2000,"output_tokens":500}')
                ('{"step_index":2,"type":"PLANNER_RESPONSE","created_at":"' + $now.AddMinutes(-9).ToString('o') + '","input_tokens":1000,"cache_read_tokens":2000,"output_tokens":500}')
                ('{"step_index":3,"type":"USER_INPUT","created_at":"' + $now.AddMinutes(-5).ToString('o') + '","content":"changed setting `Model Selection` from Gemini 4 Argon (Medium) to Claude Opus 4.6 (Thinking). No need to comment"}')
                ('{"step_index":4,"type":"PLANNER_RESPONSE","created_at":"' + $now.AddMinutes(-4).ToString('o') + '","input_tokens":9000,"cache_read_tokens":9000,"output_tokens":9000}')
            )
            [IO.File]::WriteAllLines($logFile, $lines)
            $st = New-TokenState
            Update-GeminiTokens $st
            $sum = Measure-GeminiTokens $st $now.AddHours(-1)
            $sum.Input | Should -Be 1000
            $sum.CacheRead | Should -Be 2000
            $sum.Output | Should -Be 500
            $sum.Total | Should -Be 3500
            [Math]::Round($sum.Cost, 6) | Should -Be 0.0072
        } finally {
            Set-Item Function:\Get-GeminiDir -Value $savedGeminiDir
            Set-Item Function:\Get-DataFile -Value $savedDataDir
        }
    }

    It 'parses Scout MCP scout-usage.jsonl tokens and prices them as Gemini 3.8 Flash' {
        $savedGeminiDir = (Get-Item Function:\Get-GeminiDir).ScriptBlock
        $savedDataDir = (Get-Item Function:\Get-DataFile).ScriptBlock
        try {
            function Get-GeminiDir { Join-Path $TestDrive 'scout-gemini' }
            function Get-DataFile([string]$Name) { Join-Path $TestDrive $Name }
            $scoutFile = Join-Path $TestDrive 'scout-usage.jsonl'
            $now = [DateTimeOffset]::UtcNow
            $lines = @(
                ('{"timestamp":"' + $now.AddMinutes(-5).ToString('o') + '","model":"Gemini 3.8 Flash","input_tokens":10000,"cache_read_tokens":2000,"output_tokens":1000,"conversation_id":"scout-conv-1","tool":"scout_files"}')
            )
            [IO.File]::WriteAllLines($scoutFile, $lines)
            $st = New-TokenState
            Update-GeminiTokens $st
            $sum = Measure-GeminiTokens $st $now.AddHours(-1)
            $sum.Input | Should -Be 10000
            $sum.CacheRead | Should -Be 2000
            $sum.Output | Should -Be 1000
            $sum.Total | Should -Be 13000
            # Gemini 3.8 Flash: input $0.75/M, cache read $0.075/M, output $3.75/M
            # Cost = (10000*0.75 + 2000*0.075 + 1000*3.75) / 1e6 = 0.0114
            [Math]::Round($sum.Cost, 6) | Should -Be 0.0114
        } finally {
            Set-Item Function:\Get-GeminiDir -Value $savedGeminiDir
            Set-Item Function:\Get-DataFile -Value $savedDataDir
        }
    }
}

Describe 'Incremental log reading' {
    It 'preserves an incomplete UTF-8 line until the newline arrives' {
        $file = Join-Path $TestDrive 'partial.jsonl'
        $state = @{}
        [IO.File]::WriteAllText($file, 'first' + [char]0x00E9, [Text.UTF8Encoding]::new($false))
        Read-NewLines $state $file | Should -BeNullOrEmpty
        $state[$file].Offset | Should -Be 0
        [IO.File]::AppendAllText($file, "`nnext`n", [Text.UTF8Encoding]::new($false))
        $lines = Read-NewLines $state $file
        $lines[0] | Should -Be ('first' + [char]0x00E9)
        $lines[1] | Should -Be 'next'
        Read-NewLines $state $file | Should -BeNullOrEmpty
    }
    It 'resets entries and model when a file is truncated' {
        $file = Join-Path $TestDrive 'truncated.jsonl'
        [IO.File]::WriteAllText($file, "long initial line`n")
        $state = @{}; $null = Read-NewLines $state $file
        $state[$file].Model = 'old'; $null = $state[$file].Entries.Add(1)
        [IO.File]::WriteAllText($file, "new`n")
        $lines = Read-NewLines $state $file
        $lines[0] | Should -Be 'new'
        $state[$file].Model | Should -Be ''
        $state[$file].Entries.Count | Should -Be 0
    }
    It 'reads a large file in bounded chunks without losing complete records' {
        $file = Join-Path $TestDrive 'large.jsonl'
        [IO.File]::WriteAllText($file, ('a' * 8MB) + "`ntail`n")
        $state = @{}
        $null = Read-NewLines $state $file
        $state[$file].Offset | Should -Be 8MB
        $lines = Read-NewLines $state $file
        $lines[0] | Should -Be 'tail'
    }
}

Describe 'Bounded process output' {
    BeforeAll { Initialize-ProcessReader }
    It 'rejects a long line without waiting for a newline' {
        $bytes = [Text.Encoding]::UTF8.GetBytes(('x' * 10000))
        $reader = [IO.StreamReader]::new([IO.MemoryStream]::new($bytes))
        try {
            $pump = [QuotaBurndown.ProcessReader]::new($reader, 100)
            $deadline = [DateTime]::UtcNow.AddSeconds(3)
            while (-not $pump.Completed -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 10 }
            $pump.Completed | Should -BeTrue
            $pump.Error | Should -Match 'exceeded'
        } finally { $reader.Dispose() }
    }
    It 'returns complete CRLF lines and a trailing partial line' {
        $reader = [IO.StreamReader]::new([IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes("one`r`ntwo")))
        try {
            $pump = [QuotaBurndown.ProcessReader]::new($reader, 100)
            $deadline = [DateTime]::UtcNow.AddSeconds(3)
            while (-not $pump.Completed -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 10 }
            $line = $null
            $pump.TryReadLine([ref]$line) | Should -BeTrue
            $line | Should -Be 'one'
            $pump.TryReadLine([ref]$line) | Should -BeTrue
            $line | Should -Be 'two'
            $pump.Error | Should -BeNullOrEmpty
        } finally { $reader.Dispose() }
    }
}

Describe 'Forced stop process selection' {
    BeforeAll { Initialize-ProcessReader }
    It 'matches the installed script as an actual quoted File argument' {
        $file = 'C:\Users\Example User\.quota-burndown\QuotaBurndown.ps1'
        [QuotaBurndown.ProcessReader]::RunsScript(('powershell.exe -NoProfile -File "' + $file + '"'), $file) | Should -BeTrue
        [QuotaBurndown.ProcessReader]::RunsScript(('powershell.exe -File "' + $file + '.backup"'), $file) | Should -BeFalse
    }
    It 'does not stop another command that only mentions the installed path' {
        $file = 'C:\Users\Example User\.quota-burndown\QuotaBurndown.ps1'
        [QuotaBurndown.ProcessReader]::RunsScript(('powershell.exe -Command "Write-Output -File ' + $file + '"'), $file) | Should -BeFalse
        [QuotaBurndown.ProcessReader]::RunsScript(('powershell.exe -c Write-Output -File "' + $file + '"'), $file) | Should -BeFalse
        [QuotaBurndown.ProcessReader]::RunsScript(('powershell.exe -File "C:\other.ps1" "' + $file + '"'), $file) | Should -BeFalse
    }
}

Describe 'Update cache validation' {
    It 'ignores a malformed cached version without making a network request' {
        $script:cachePath = Join-Path $TestDrive 'update-check.json'
        function Get-DataFile { $script:cachePath }
        [IO.File]::WriteAllText($cachePath, ('{"checkedAt":' + [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + ',"latest":"broken"}'))
        Get-AvailableUpdate '1.5.0' | Should -BeNullOrEmpty
    }
}

Describe 'Credential error privacy' {
    It 'rejects malformed access tokens without echoing them or making a request' {
        $savedDir = $env:CLAUDE_CONFIG_DIR
        $env:CLAUDE_CONFIG_DIR = $TestDrive
        function Read-ClaudeCache { @{ fetchedAt = [long]0; blockedUntil = [long]0; body = $null; renewTriedAt = [long]0; renewFailures = 0 } }
        try {
            $fake = 'private-fixture' + "`r`n" + 'value'
            @{ claudeAiOauth = @{ accessToken = $fake; expiresAt = [DateTimeOffset]::UtcNow.AddHours(1).ToUnixTimeMilliseconds() } } |
                ConvertTo-Json | Set-Content (Join-Path $TestDrive '.credentials.json')
            $res = (Update-Claude 5 $false $false).Result
            $res.Error | Should -Be 'invalid login'
            $res.Detail | Should -Not -Match 'private-fixture'
        } finally { $env:CLAUDE_CONFIG_DIR = $savedDir }
    }
}

Describe 'Codex session dates' {
    It 'searches UTC dated folders even when the local date differs' {
        function Get-CodexHome { $TestDrive }
        function Get-Date { [DateTime]::UtcNow.AddDays(-1) }
        $dir = Join-Path (Join-Path $TestDrive 'sessions') ('{0:yyyy}\{0:MM}\{0:dd}' -f [DateTime]::UtcNow)
        $null = New-Item -ItemType Directory -Force $dir
        Set-Content (Join-Path $dir 'today.jsonl') '{}'
        @(Get-CodexSessionFiles 1).Count | Should -Be 1
    }
}

Describe 'Codex log fallback trust' {
    BeforeEach {
        $script:fallbackFixtureDir = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory $script:fallbackFixtureDir
        function Get-CodexSessionFiles { Get-ChildItem $script:fallbackFixtureDir -Filter *.jsonl -File }
    }
    It 'does not give an old selected window the timestamp of a newer expired record' {
        $now = [DateTimeOffset]::UtcNow
        foreach ($spec in @(@('old', -90, 60, 55), @('expired', 0, -2, 0))) {
            @{ timestamp = $now.AddMinutes($spec[1]).ToString('o'); payload = @{ rate_limits = @{
                primary = @{ window_minutes = 300; used_percent = $spec[3]; resets_at = $now.AddMinutes($spec[2]).ToUnixTimeSeconds() }
            } } } | ConvertTo-Json -Depth 5 -Compress | Set-Content (Join-Path $script:fallbackFixtureDir ($spec[0] + '.jsonl'))
        }
        $logs = Get-CodexFromLogs
        $logs.Windows[0].Percent | Should -Be 55
        ($now - $logs.At).TotalMinutes | Should -BeGreaterThan 89
    }
    It 'ignores a model-specific pool in fallback logs' {
        $now = [DateTimeOffset]::UtcNow
        @{ timestamp = $now.ToString('o'); payload = @{ rate_limits = @{ limit_id = 'codex_other';
            primary = @{ window_minutes = 300; used_percent = 99; resets_at = $now.AddHours(1).ToUnixTimeSeconds() }
        } } } | ConvertTo-Json -Depth 5 -Compress | Set-Content (Join-Path $script:fallbackFixtureDir 'other.jsonl')
        Get-CodexFromLogs | Should -BeNullOrEmpty
    }
    It 'withholds forecasts for a fallback rather than treating it as live' {
        $r = New-UsageResult 'Codex'; $r.Source = 'logs'; $r.UpdatedAt = [DateTimeOffset]::UtcNow
        $r.Windows = @((New-UsageWindow '5-hour' 80 300 ([DateTimeOffset]::UtcNow.AddHours(1))))
        (Get-Forecasts (New-Object System.Collections.ArrayList) $r).Count | Should -Be 0
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

Describe 'Get-WindowHistory and Get-ToolHistoryMap' {
    It 'extracts window history within the active window span and reset timestamp' {
        $now = [DateTimeOffset]::UtcNow
        $reset = $now.AddHours(2)
        $w = [pscustomobject]@{
            Label = '5-hour'
            Minutes = 300
            ResetsAt = $reset
        }
        $history = @(
            [pscustomobject]@{ Tool = 'Claude Code'; Label = '5-hour'; At = $now.AddMinutes(-350); Percent = 5.0; ResetsAt = $reset.ToUnixTimeSeconds() }
            [pscustomobject]@{ Tool = 'Claude Code'; Label = '5-hour'; At = $now.AddMinutes(-120); Percent = 30.0; ResetsAt = $reset.ToUnixTimeSeconds() }
            [pscustomobject]@{ Tool = 'Claude Code'; Label = '5-hour'; At = $now.AddMinutes(-30); Percent = 55.0; ResetsAt = $reset.ToUnixTimeSeconds() }
            [pscustomobject]@{ Tool = 'Claude Code'; Label = '5-hour'; At = $now.AddMinutes(-10); Percent = 60.0; ResetsAt = $reset.AddDays(7).ToUnixTimeSeconds() }
            [pscustomobject]@{ Tool = 'Codex'; Label = '5-hour'; At = $now.AddMinutes(-20); Percent = 15.0; ResetsAt = $reset.ToUnixTimeSeconds() }
        )
        $pts = Get-WindowHistory $history 'Claude Code' $w
        $pts | Should -HaveCount 2
        $pts[0].Percent | Should -Be 30.0
        $pts[1].Percent | Should -Be 55.0
    }

    It 'builds tool history map across all windows for a provider' {
        $now = [DateTimeOffset]::UtcNow
        $reset = $now.AddHours(2)
        $res = [pscustomobject]@{
            Name = 'Claude Code'
            Windows = @(
                [pscustomobject]@{ Label = '5-hour'; Minutes = 300; ResetsAt = $reset }
                [pscustomobject]@{ Label = 'Weekly'; Minutes = 10080; ResetsAt = $reset.AddDays(5) }
            )
        }
        $history = @(
            [pscustomobject]@{ Tool = 'Claude Code'; Label = '5-hour'; At = $now.AddMinutes(-60); Percent = 40.0; ResetsAt = $reset.ToUnixTimeSeconds() }
            [pscustomobject]@{ Tool = 'Claude Code'; Label = 'Weekly'; At = $now.AddDays(-1); Percent = 25.0; ResetsAt = $reset.AddDays(5).ToUnixTimeSeconds() }
        )
        $map = Get-ToolHistoryMap $history $res
        $map.Keys | Should -Contain '5-hour'
        $map.Keys | Should -Contain 'Weekly'
        $map['5-hour'] | Should -HaveCount 1
        $map['Weekly'] | Should -HaveCount 1
    }
}

