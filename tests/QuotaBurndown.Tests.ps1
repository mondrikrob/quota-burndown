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

Describe 'Find-JsonObjectSpan' {
    It 'finds the object even with braces and escaped quotes inside strings' {
        $json = '{"a":{"x":"}{\"}"},"claudeAiOauth":{"t":"{","n":{"m":1}},"z":2}'
        $span = Find-JsonObjectSpan $json 'claudeAiOauth'
        $json.Substring($span[0], $span[1] - $span[0] + 1) | Should -Be '{"t":"{","n":{"m":1}}'
    }

    It 'returns nothing when the key is missing' {
        Find-JsonObjectSpan '{"other":{}}' 'claudeAiOauth' | Should -BeNullOrEmpty
    }
}

Describe 'Save-ClaudeTokens' {
    BeforeEach {
        # Another login (an MCP server) with token fields of its own comes first and must not change.
        $script:original = @'
{
  "mcpOAuth": { "srv|1": { "accessToken": "mcp-access-AAAA", "refreshToken": "mcp-refresh-BBBB", "expiresAt": 111, "note": "}{" } },
  "claudeAiOauth":   {"accessToken":"old-access-1234567890","refreshToken": "old-refresh-1234567890",
     "expiresAt": 1700000000000, "scopes": ["user:inference", "user:profile"], "subscriptionType": "pro"}
}
'@ -replace "`r`n", "`n"
        $script:cred = Join-Path $TestDrive '.credentials.json'
        [IO.File]::WriteAllText($cred, $original, [Text.UTF8Encoding]::new($false))
    }

    It 'changes only accessToken, refreshToken and expiresAt of claudeAiOauth' {
        Save-ClaudeTokens $cred 'old-refresh-1234567890' 'new-access-ABCDEFGHIJ' 'new-refresh-ABCDEFGHIJ' 1800000000000 | Should -BeTrue
        $expected = $original.Replace('"accessToken":"old-access-1234567890"', '"accessToken":"new-access-ABCDEFGHIJ"').
            Replace('"refreshToken": "old-refresh-1234567890"', '"refreshToken":"new-refresh-ABCDEFGHIJ"').
            Replace('"expiresAt": 1700000000000', '"expiresAt":1800000000000')
        [IO.File]::ReadAllText($cred) | Should -BeExactly $expected
    }

    It 'keeps the refresh token when the server sent no new one' {
        Save-ClaudeTokens $cred 'old-refresh-1234567890' 'new-access-ABCDEFGHIJ' '' 1800000000000 | Should -BeTrue
        $o = (Get-Content $cred -Raw | ConvertFrom-Json).claudeAiOauth
        $o.refreshToken | Should -Be 'old-refresh-1234567890'
        $o.accessToken | Should -Be 'new-access-ABCDEFGHIJ'
    }

    It 'refuses to write when the refresh token changed meanwhile' {
        Save-ClaudeTokens $cred 'someone-else-renewed-it' 'new-access-ABCDEFGHIJ' 'new-refresh-ABCDEFGHIJ' 1800000000000 | Should -BeFalse
        [IO.File]::ReadAllText($cred) | Should -BeExactly $original
    }

    It 'leaves no temporary file behind' {
        $null = Save-ClaudeTokens $cred 'old-refresh-1234567890' 'new-access-ABCDEFGHIJ' 'new-refresh-ABCDEFGHIJ' 1800000000000
        $null = Save-ClaudeTokens $cred 'stale' 'x-access-ABCDEFGHIJKLMNOP' 'x-refresh-ABCDEFGHIJKLMNOP' 1
        @(Get-ChildItem $TestDrive -Force | Where-Object Name -ne '.credentials.json') | Should -HaveCount 0
    }

    It 'throws when there is no claudeAiOauth entry, without touching the file' {
        [IO.File]::WriteAllText($cred, '{"mcpOAuth":{}}')
        { Save-ClaudeTokens $cred 'a' 'b' 'c' 1 } | Should -Throw
        [IO.File]::ReadAllText($cred) | Should -Be '{"mcpOAuth":{}}'
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
        $s.ClaudeRefreshMinutes | Should -Be 15
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
