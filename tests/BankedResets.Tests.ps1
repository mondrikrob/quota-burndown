#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
Describe 'Banked reset notifications' {
    It 'parses provider grants and delivers new/expiry alerts once across restarts' {
        $ErrorActionPreference = 'Stop'
        $tokens = $null; $errors = $null
        $path = Join-Path $PSScriptRoot '..\QuotaBurndown.ps1'
        $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
        if ($errors.Count) { throw ($errors.Message -join '; ') }
        $assignment = $ast.Find({ param($n)
            $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$DataLayer'
        }, $true)
        . ([scriptblock]::Create($assignment.Right.Expression.ScriptBlock.EndBlock.Extent.Text))
        function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }
        $AppVersion = '1.7.0'
        $script:claudeUsageUserAgent = $null; $script:versionCalls = 0
        function Find-ClaudeExe { 'claude.exe' }
        function Invoke-QuietProcess {
            $script:versionCalls++
            @{ ExitCode = 0; Output = '2.1.283 (Claude Code)' }
        }
        Assert ((Get-ClaudeUsageUserAgent) -eq 'claude-cli/2.1.283 (external, cli) quota-burndown/1.7.0') 'Installed Claude version was not used'
        $null = Get-ClaudeUsageUserAgent
        Assert ($script:versionCalls -eq 1) 'Version detection repeated on every refresh'
        $script:claudeUsageUserAgent = $null
        function Invoke-QuietProcess { @{ ExitCode = 1; Output = 'invalid' } }
        Assert ((Get-ClaudeUsageUserAgent) -eq 'quota-burndown/1.7.0') 'Failed version detection guessed a Claude version'
        $now = [DateTimeOffset]::Parse('2026-10-13T12:00:00Z')
        $expiry = $now.AddHours(25)
        $codex = [pscustomobject]@{ rateLimitResetCredits = [pscustomobject]@{
            availableCount = 1; credits = @([pscustomobject]@{ id = 'a'; status = 'available'; expiresAt = $expiry.ToUnixTimeSeconds() })
        } }
        $parsed = ConvertTo-BankedResets $codex 'Codex' $now
        Assert ($parsed.Count -eq 1 -and $parsed.Credits[0].ExpiresAt -eq $expiry) 'Codex count/expiry parsing failed'
        $first = Get-BankedResetEvents $parsed $null $now
        Assert ($first.Events.Count -eq 0) 'Existing resets must not be announced as new on first start'
        $soon = Get-BankedResetEvents $parsed $first.State $now.AddHours(1)
        Assert ($soon.Events.Count -eq 1 -and $soon.Events[0].Kind -eq 'expiry') '24-hour boundary failed'
        $restored = $soon.State | ConvertTo-Json -Depth 5 | ConvertFrom-Json
        $again = Get-BankedResetEvents $parsed $restored $now.AddHours(2)
        Assert ($again.Events.Count -eq 0) 'Reminder repeated after restart'
        $codex.rateLimitResetCredits.availableCount = 2
        $codex.rateLimitResetCredits.credits += [pscustomobject]@{ id = 'b'; status = 'available'; expiresAt = $now.AddDays(5).ToUnixTimeSeconds() }
        $added = Get-BankedResetEvents (ConvertTo-BankedResets $codex 'Codex' $now) $again.State $now
        Assert ($added.Events.Count -eq 1 -and $added.Events[0].Kind -eq 'new' -and $added.Events[0].Count -eq 1) 'New reset detection failed'
        $expired = Get-BankedResetEvents $parsed $first.State $now.AddDays(2)
        Assert ($expired.Events.Count -eq 0) 'Expired reset produced an alert'
        $missing = ConvertTo-BankedResets ([pscustomobject]@{}) 'Codex' $now
        Assert ($null -eq $missing) 'Missing information was treated as zero'
        $claude = [pscustomobject]@{ cedar_ember = [pscustomobject]@{ eligible = $true; grants = @(
            [pscustomobject]@{ id = 'c'; resets_left = 2; ends_at = $expiry.ToString('o') },
            [pscustomobject]@{ id = 'expired'; resets_left = 1; ends_at = $now.AddDays(-1).ToString('o') }
        ) } }
        $parsedClaude = ConvertTo-BankedResets $claude 'Claude Code' $now
        Assert ($parsedClaude.Count -eq 2 -and $parsedClaude.Credits.Count -eq 1) 'Claude grant count or expiry filtering failed'
        $claude.cedar_ember.eligible = $false
        Assert ($null -eq (ConvertTo-BankedResets $claude 'Claude Code' $now)) 'Ineligible Claude surface was treated as zero'
        $claude.cedar_ember.eligible = $true
        $claude.cedar_ember.grants[0].resets_left = -1
        Assert ($null -eq (ConvertTo-BankedResets $claude 'Claude Code' $now)) 'Invalid count accepted'
        $codex.rateLimitResetCredits.credits[0].expiresAt = [long]::MaxValue
        Assert ($null -eq (ConvertTo-BankedResets $codex 'Codex' $now)) 'Invalid timestamp accepted'
        $countsOnly = [pscustomobject]@{ Count = 1; Credits = @() }
        $baseline = Get-BankedResetEvents $countsOnly $null $now
        $enriched = Get-BankedResetEvents $parsed $baseline.State $now
        Assert ($enriched.Events.Count -eq 0) 'Arrival of detail rows was mistaken for a new reset'
        $increase = Get-BankedResetEvents ([pscustomobject]@{ Count = 2; Credits = @() }) $baseline.State $now
        Assert ($increase.Events.Count -eq 1 -and $increase.Events[0].Count -eq 1) 'Count-only increase was missed'
        foreach ($name in @('Get-BankedResetText', 'Update-BankedResetNotifications')) {
            $functionAst = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
            . ([scriptblock]::Create($functionAst.Extent.Text))
        }
        Add-Type -AssemblyName System.Windows.Forms
        $script:resetState = @{}
        $script:resetQueue = [Collections.Generic.Queue[object]]::new()
        $script:resetNoticeAt = [DateTimeOffset]::MinValue
        $resetStatePath = Join-Path $TestDrive ('test-state-' + [guid]::NewGuid().ToString() + '.json')
        $Settings = @{ BankedResetNotifications = $true }; $Snapshot = $null
        $tray = [pscustomobject]@{ Calls = @() }
        $tray | Add-Member ScriptMethod ShowBalloonTip { param($duration, $title, $body, $icon) $this.Calls += $body }
        $fresh = [DateTimeOffset]::UtcNow
        $sync = @{ Claude = [pscustomobject]@{
            Name = 'Claude Code'; Error = $null; UpdatedAt = $fresh
            BankedResets = [pscustomobject]@{ Count = 1; Credits = @([pscustomobject]@{ Id = 'near'; Count = 1; ExpiresAt = $fresh.AddHours(23) }) }
        }; Codex = $null }
        try {
            Update-BankedResetNotifications
            Assert ($tray.Calls.Count -eq 1 -and $tray.Calls[0] -match 'within 24 hours') 'Expiry event did not reach the notification API'
            $script:resetState = @{}
            $diskState = Get-Content $resetStatePath -Raw | ConvertFrom-Json
            foreach ($property in $diskState.PSObject.Properties) { $script:resetState[$property.Name] = $property.Value }
            $script:resetNoticeAt = [DateTimeOffset]::MinValue
            Update-BankedResetNotifications
            Assert ($tray.Calls.Count -eq 1) 'Notification repeated after reloading disk history'
            $sync.Claude.BankedResets.Count = 2
            $sync.Claude.BankedResets.Credits += [pscustomobject]@{ Id = 'new'; Count = 1; ExpiresAt = $fresh.AddDays(5) }
            Update-BankedResetNotifications
            Assert ($tray.Calls.Count -eq 2 -and $tray.Calls[1] -match 'new banked') 'New grant did not reach the notification API'
            $text = Get-BankedResetText $sync.Claude $fresh
            Assert ($text -match '2 banked resets' -and $text -match 'expires') 'Widget reset information missing'
            $Settings.BankedResetNotifications = $false
            $sync.Claude.BankedResets.Count = 3
            Update-BankedResetNotifications
            Assert ($tray.Calls.Count -eq 2 -and $script:resetQueue.Count -eq 0) 'Disabled notifications still delivered'
            $Settings.BankedResetNotifications = $true
            $sync.Claude.Error = 'offline'; $sync.Claude.BankedResets.Count = 4
            Update-BankedResetNotifications
            Assert ($script:resetState['Claude Code'].Count -eq 3) 'Error reading changed notification baseline'
        } finally {
            Remove-Item -LiteralPath $resetStatePath -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath ($resetStatePath + '.tmp') -Force -ErrorAction SilentlyContinue
        }
        'Banked-reset parsing, grant detection, expiry boundary, restart and notification delivery tests passed.'
        
    }
}
