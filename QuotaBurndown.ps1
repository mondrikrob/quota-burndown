<#
.SYNOPSIS
    Desktop widget, taskbar strip and tray icon for Claude Code and Codex usage limits.

.DESCRIPTION
    Shows the 5-hour and weekly rate-limit windows of Claude Code and OpenAI Codex,
    where you would be at an even pace, a run-out forecast, the tokens you burned
    (from local logs) and what those tokens would have cost at API prices.

    Data sources
      Claude Code  GET https://api.anthropic.com/api/oauth/usage, authenticated with the
                   OAuth access token Claude Code keeps in ~/.claude/.credentials.json.
                   The endpoint is undocumented and rate-limits hard (a 429 can carry a
                   ~1 hour Retry-After), so responses are cached on disk and fetched at
                   most every ClaudeRefreshMinutes. The Claude desktop app never renews
                   that file; if you opt in (ClaudeAutoRenewLogin), an expired token is
                   renewed here the way the claude CLI does it, and the new tokens are
                   written back to the same file (see SECURITY.md). Tokens are never
                   sent to any other host.
      Updates      Opt-in (CheckForUpdates): once a day the latest release number from
                   api.github.com. Nothing is downloaded.
      Codex        `codex app-server --stdio`, JSON-RPC method account/rateLimits/read,
                   falling back to the rate_limits blocks in ~/.codex/sessions/**/*.jsonl.
      Tokens       Parsed locally from ~/.claude/projects/**/*.jsonl and
                   ~/.codex/sessions/**/*.jsonl. Nothing is uploaded.

    Runs on the Windows PowerShell 5.1 that ships with Windows (pwsh 7 works too).
    Settings, cache, usage history and log live in ~/.quota-burndown.

.PARAMETER Once
    Print the current numbers to the console and exit.

.PARAMETER Install
    Copy this script to ~/.quota-burndown, create a Start menu shortcut and (re)start the widget.

.PARAMETER Uninstall
    Stop the widget and remove its shortcuts and installed copy. Settings and history are kept.

.PARAMETER Snapshot
    Render the widget to the given PNG (and the taskbar strip to <name>-strip.png), then exit.

.PARAMETER Theme
    Force 'light' or 'dark' (useful with -Snapshot).

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\QuotaBurndown.ps1 -Install
#>
[CmdletBinding()]
param(
    [switch]$Once,
    [switch]$Install,
    [switch]$Uninstall,
    [string]$Snapshot,
    [ValidateSet('', 'light', 'dark')][string]$Theme = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Off
$AppVersion = '1.3.1'

Add-Type -AssemblyName System.Net.Http
if ($PSVersionTable.PSEdition -ne 'Core') {
    # .NET Framework may not offer TLS 1.2 by default on older systems.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

# Outside AppData on purpose: packaged (MSIX) hosts such as Store apps virtualise
# AppData writes, which would hide these files from a normally started widget.
$DataDir = Join-Path $HOME '.quota-burndown'
$null = New-Item -ItemType Directory -Force -Path $DataDir
$SettingsPath = Join-Path $DataDir 'settings.json'

# ===========================================================================
# Settings
# ===========================================================================

$DefaultSettings = [ordered]@{
    Left                  = $null
    Top                   = $null
    Topmost               = $true
    Visible               = $true
    StripVisible          = $true
    StripOffset           = 8       # gap (DIP) between the taskbar strip and the tray area
    ClaudeRefreshMinutes  = 15      # the Claude usage endpoint rate-limits hard; keep this >= 10
    CodexRefreshMinutes   = 3
    ClaudePlanUsdPerMonth = $null   # override the detected plan price (Pro 20, Max 100/200)
    CodexPlanUsdPerMonth  = $null   # override the detected plan price (Plus 20, Pro 200)
    ClaudeAutoRenewLogin  = $null   # renew an expired Claude Code login itself; $null = not asked yet (off)
    CheckForUpdates       = $null   # ask api.github.com once a day for a newer release; $null = not asked yet (off)
}

function ConvertTo-Number($Value, $Default, [double]$Min = [double]::MinValue, [double]$Max = [double]::MaxValue) {
    if ($null -eq $Value -or '' -eq $Value -or $Value -is [bool]) { return $Default }
    try { $n = [double]$Value } catch { return $Default }
    if ([double]::IsNaN($n) -or [double]::IsInfinity($n)) { return $Default }
    [Math]::Min($Max, [Math]::Max($Min, $n))
}

function Read-Settings {
    $s = [ordered]@{}
    foreach ($k in $DefaultSettings.Keys) { $s[$k] = $DefaultSettings[$k] }
    if (Test-Path $SettingsPath) {
        try {
            $saved = Get-Content $SettingsPath -Raw | ConvertFrom-Json
            foreach ($p in $saved.PSObject.Properties) { if ($s.Contains($p.Name)) { $s[$p.Name] = $p.Value } }
        } catch { }
    }
    # The file is hand-editable: never trust its types or ranges.
    foreach ($k in 'Topmost', 'Visible', 'StripVisible') { if ($s[$k] -isnot [bool]) { $s[$k] = $DefaultSettings[$k] } }
    foreach ($k in 'ClaudeAutoRenewLogin', 'CheckForUpdates') { if ($s[$k] -isnot [bool]) { $s[$k] = $null } }   # opt-in: anything else means "not asked"
    $s.Left = ConvertTo-Number $s.Left $null -100000 100000
    $s.Top = ConvertTo-Number $s.Top $null -100000 100000
    $s.StripOffset = ConvertTo-Number $s.StripOffset 8 -10000 10000
    $s.ClaudeRefreshMinutes = [int](ConvertTo-Number $s.ClaudeRefreshMinutes 15 5 1440)
    $s.CodexRefreshMinutes = [int](ConvertTo-Number $s.CodexRefreshMinutes 3 1 1440)
    $s.ClaudePlanUsdPerMonth = ConvertTo-Number $s.ClaudePlanUsdPerMonth $null 0 100000
    $s.CodexPlanUsdPerMonth = ConvertTo-Number $s.CodexPlanUsdPerMonth $null 0 100000
    $s
}

function Save-Settings($s) {
    try { $s | ConvertTo-Json | Set-Content -Path $SettingsPath -Encoding UTF8 } catch { }
}

# ===========================================================================
# Data layer. Defined as one script block so the exact same code runs in the
# UI thread (dot-sourced below) and in the background worker runspace.
# ===========================================================================

$DataLayer = {

    function Get-DataFile([string]$Name) { Join-Path (Join-Path $HOME '.quota-burndown') $Name }

    function Write-WidgetLog([string]$Message) {
        try {
            $path = Get-DataFile 'widget.log'
            if ((Test-Path $path) -and (Get-Item $path).Length -gt 512KB) { Remove-Item $path -Force }
            Add-Content -Path $path -Value ('{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $Message)
        } catch { }
    }

    function Get-UnixNow { [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }

    function ConvertTo-Dto($v) {
        if ($null -eq $v -or '' -eq $v) { return $null }
        if ($v -is [DateTimeOffset]) { return $v }
        if ($v -is [DateTime]) { return [DateTimeOffset]::new($v) }
        if ($v -is [int] -or $v -is [long] -or $v -is [double] -or $v -is [decimal]) {
            $n = [long]$v
            if ($n -gt 100000000000) { return [DateTimeOffset]::FromUnixTimeMilliseconds($n) }
            return [DateTimeOffset]::FromUnixTimeSeconds($n)
        }
        try { [DateTimeOffset]::Parse([string]$v, [Globalization.CultureInfo]::InvariantCulture) } catch { $null }
    }

    function Format-Title([string]$s) { if ($s) { (Get-Culture).TextInfo.ToTitleCase($s.ToLowerInvariant()) } }

    function New-UsageWindow([string]$Label, $Percent, [int]$Minutes, $ResetsAt) {
        [pscustomobject]@{ Label = $Label; Percent = [double]$Percent; Minutes = $Minutes; ResetsAt = (ConvertTo-Dto $ResetsAt) }
    }

    function New-UsageResult([string]$Name) {
        [pscustomobject]@{
            Name = $Name; Plan = $null; PlanKey = $null; Windows = @(); UpdatedAt = $null
            Source = $null; Error = $null; Detail = $null; Loading = $false
        }
    }

    function Read-FileTail([string]$Path, [int]$Bytes) {
        $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite, Delete')
        try {
            $start = [Math]::Max([long]0, $fs.Length - $Bytes)
            $null = $fs.Seek($start, 'Begin')
            $buf = New-Object byte[] ($fs.Length - $start)
            $read = $fs.Read($buf, 0, $buf.Length)
            [Text.Encoding]::UTF8.GetString($buf, 0, $read)
        } finally { $fs.Dispose() }
    }

    # ----- Claude Code usage ------------------------------------------------

    function Get-ClaudeDir { if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' } }

    function Read-ClaudeCache {
        $c = @{ fetchedAt = [long]0; blockedUntil = [long]0; body = $null; renewBlockedUntil = [long]0; deadRefresh = '' }
        $path = Get-DataFile 'claude-usage.json'
        if (Test-Path $path) {
            try {
                $j = Get-Content $path -Raw | ConvertFrom-Json
                $c.fetchedAt = [long]$j.fetchedAt; $c.blockedUntil = [long]$j.blockedUntil; $c.body = [string]$j.body
                $c.renewBlockedUntil = [long]$j.renewBlockedUntil; $c.deadRefresh = [string]$j.deadRefresh
            } catch { }
        }
        $c
    }

    function Write-ClaudeCache($c) {
        try { ([pscustomobject]$c) | ConvertTo-Json -Depth 3 | Set-Content -Path (Get-DataFile 'claude-usage.json') -Encoding UTF8 } catch { }
    }

    function ConvertFrom-ClaudeBody([string]$Body) {
        $j = $Body | ConvertFrom-Json
        $wins = @()
        foreach ($l in @($j.limits)) {
            if (-not $l) { continue }
            switch ($l.kind) {
                'session' { $wins += New-UsageWindow '5-hour' $l.percent 300 $l.resets_at }
                'weekly_all' { $wins += New-UsageWindow 'Weekly' $l.percent 10080 $l.resets_at }
                'weekly_scoped' {
                    $model = 'scoped'
                    if ($l.scope -and $l.scope.model -and $l.scope.model.display_name) { $model = $l.scope.model.display_name }
                    $wins += New-UsageWindow ('Weekly ' + [char]0x00B7 + ' ' + $model) $l.percent 10080 $l.resets_at
                }
            }
        }
        if ($wins.Count -eq 0) {
            # Older response shape.
            if ($j.five_hour) { $wins += New-UsageWindow '5-hour' $j.five_hour.utilization 300 $j.five_hour.resets_at }
            if ($j.seven_day) { $wins += New-UsageWindow 'Weekly' $j.seven_day.utilization 10080 $j.seven_day.resets_at }
        }
        , $wins
    }

    # ----- Claude Code login renewal ------------------------------------------
    # The Claude desktop app keeps its own login and never updates
    # ~/.claude/.credentials.json; only the `claude` CLI renews it, and only when
    # it runs. So when that access token has expired and the user opted in
    # (ClaudeAutoRenewLogin), the widget renews it the
    # way the CLI does and writes the rotated tokens back into the same file, so
    # the CLI keeps working with them. Refresh tokens are single-use: a refresh
    # token the server rejects is never retried.

    $ClaudeOAuthClientId = '9d1c250a-e61b-44d9-88ed-5944d1962f5e'   # Claude Code's public OAuth client

    # Runs a program without a shell or window, with stdin closed (so it can never
    # wait for an answer), a timeout and capped output. Returns @{ ExitCode; Output }.
    function Invoke-QuietProcess([string]$Exe, [string]$Arguments, [int]$TimeoutSec = 15) {
        $psi = [Diagnostics.ProcessStartInfo]::new($Exe, $Arguments)
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $p = [Diagnostics.Process]::Start($psi)
        try {
            $p.StandardInput.Close()
            $out = $p.StandardOutput.ReadToEndAsync(); $null = $p.StandardError.ReadToEndAsync()
            if (-not $p.WaitForExit($TimeoutSec * 1000)) { throw "$([IO.Path]::GetFileName($Exe)) timed out" }
            $text = if ($out.Wait(2000)) { $out.Result } else { '' }
            @{ ExitCode = $p.ExitCode; Output = $(if ($text.Length -gt 65536) { $text.Substring(0, 65536) } else { $text }) }
        } finally {
            if (-not $p.HasExited) { try { $p.Kill($true) } catch { try { $p.Kill() } catch { } } }
            $p.Dispose()
        }
    }

    function Find-ClaudeExe {
        $cmd = Get-Command claude.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd) { return $cmd.Source }
        $native = Join-Path $HOME '.local\bin\claude.exe'   # the native installer's default location
        if (Test-Path $native) { return $native }
        $null
    }

    # The installed Claude Code version ("2.1.287"), read from `claude --version` and
    # remembered for a few hours. The token endpoint only accepts Claude Code's own
    # client name, and a hard-coded version would go stale.
    function Get-ClaudeCliVersion {
        if ($script:ClaudeCliVersion -and ([DateTime]::UtcNow - $script:ClaudeCliVersionAt).TotalHours -lt 6) { return $script:ClaudeCliVersion }
        $exe = Find-ClaudeExe
        if (-not $exe) { return $null }
        try { $res = Invoke-QuietProcess $exe '--version' 15 } catch { return $null }
        $m = [regex]::Match($res.Output, '\b(\d{1,4}\.\d{1,4}\.\d{1,6})\b')
        if (-not $m.Success) { return $null }
        $script:ClaudeCliVersion = $m.Groups[1].Value; $script:ClaudeCliVersionAt = [DateTime]::UtcNow
        $script:ClaudeCliVersion
    }

    function Get-TokenHash([string]$Value) {
        $sha = [Security.Cryptography.SHA256]::Create()
        try { -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value)) | Select-Object -First 8 | ForEach-Object { $_.ToString('x2') }) }
        finally { $sha.Dispose() }
    }

    # Start and end index of the object value of "$Key" (string-aware brace matching).
    function Find-JsonObjectSpan([string]$Json, [string]$Key) {
        $k = $Json.IndexOf('"' + $Key + '"')
        if ($k -lt 0) { return $null }
        $start = $Json.IndexOf('{', $k)
        if ($start -lt 0) { return $null }
        $depth = 0; $inString = $false; $escaped = $false
        for ($i = $start; $i -lt $Json.Length; $i++) {
            $c = $Json[$i]
            if ($inString) {
                if ($escaped) { $escaped = $false } elseif ($c -eq [char]92) { $escaped = $true } elseif ($c -eq [char]34) { $inString = $false }
                continue
            }
            if ($c -eq [char]34) { $inString = $true }
            elseif ($c -eq [char]123) { $depth++ }
            elseif ($c -eq [char]125) { $depth--; if ($depth -eq 0) { return , @($start, $i) } }
        }
        $null
    }

    # Replace only accessToken / refreshToken / expiresAt inside "claudeAiOauth" and
    # leave every other byte of the file (MCP logins, scopes, ...) untouched.
    # Returns $false when the file changed meanwhile (someone else renewed it).
    function Save-ClaudeTokens([string]$Path, [string]$OldRefresh, [string]$Access, [string]$Refresh, [long]$ExpiresAtMs) {
        $json = [IO.File]::ReadAllText($Path)
        $span = Find-JsonObjectSpan $json 'claudeAiOauth'
        if (-not $span) { throw 'claudeAiOauth entry not found' }
        $obj = $json.Substring($span[0], $span[1] - $span[0] + 1)
        if ([regex]::Match($obj, '"refreshToken"\s*:\s*"([^"]*)"').Groups[1].Value -ne $OldRefresh) { return $false }
        $obj = [regex]::Replace($obj, '"accessToken"\s*:\s*"[^"]*"', { param($m) '"accessToken":"' + $Access + '"' })
        if ($Refresh) { $obj = [regex]::Replace($obj, '"refreshToken"\s*:\s*"[^"]*"', { param($m) '"refreshToken":"' + $Refresh + '"' }) }
        $obj = [regex]::Replace($obj, '"expiresAt"\s*:\s*\d+', { param($m) '"expiresAt":' + $ExpiresAtMs })
        $out = $json.Substring(0, $span[0]) + $obj + $json.Substring($span[1] + 1)
        $tmp = $Path + '.quota-burndown.tmp'
        [IO.File]::WriteAllText($tmp, $out, [Text.UTF8Encoding]::new($false))
        try { [IO.File]::Replace($tmp, $Path, [NullString]::Value) }   # atomic swap that keeps the file's permissions
        catch { [IO.File]::Copy($tmp, $Path, $true); Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
        $true
    }

    # Returns @{ State = 'renewed' | 'invalid' | 'limited' | 'offline' | 'failed'; Token; RetryAt; Detail }
    function Invoke-ClaudeTokenRenewal([string]$CredPath, $Cache, [long]$Now) {
        $oauth = $null
        try { $oauth = (Get-Content $CredPath -Raw | ConvertFrom-Json).claudeAiOauth } catch { }
        $refresh = [string]$oauth.refreshToken
        if (-not $refresh) { return @{ State = 'invalid' } }
        $hash = Get-TokenHash $refresh
        if ($Cache.deadRefresh -eq $hash) { return @{ State = 'invalid' } }   # already rejected: wait for a new login
        if ($Cache.renewBlockedUntil -gt $Now) { return @{ State = 'limited'; RetryAt = $Cache.renewBlockedUntil } }
        $cliVersion = Get-ClaudeCliVersion
        if (-not $cliVersion) { return @{ State = 'failed'; Detail = "the 'claude' command was not found, so its version is unknown" } }

        $client = [Net.Http.HttpClient]::new()
        $client.Timeout = [TimeSpan]::FromSeconds(15)
        $client.MaxResponseContentBufferSize = 64KB
        try {
            $body = '{"grant_type":"refresh_token","refresh_token":' + (ConvertTo-Json $refresh) + ',"client_id":"' + $ClaudeOAuthClientId + '"}'
            $req = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post, 'https://api.anthropic.com/v1/oauth/token')
            $req.Content = [Net.Http.StringContent]::new($body, [Text.Encoding]::UTF8, 'application/json')
            $null = $req.Headers.TryAddWithoutValidation('anthropic-beta', 'oauth-2025-04-20')
            $null = $req.Headers.TryAddWithoutValidation('Accept', 'application/json')
            # The token endpoint sits behind a bot filter that rejects generic client names.
            $null = $req.Headers.TryAddWithoutValidation('User-Agent', 'claude-code/' + $cliVersion)
            $res = $client.SendAsync($req).GetAwaiter().GetResult()
            $status = [int]$res.StatusCode
            $text = $res.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        } catch {
            return @{ State = 'offline'; Detail = $_.Exception.GetBaseException().Message }
        } finally { $client.Dispose() }

        if ($status -eq 400 -or $status -eq 401 -or $status -eq 403) {
            $Cache.deadRefresh = $hash; Write-ClaudeCache $Cache
            return @{ State = 'invalid' }
        }
        if ($status -ne 200) {
            # The endpoint answers most failures with 429 and no Retry-After: back off for an hour.
            $Cache.renewBlockedUntil = $Now + $(if ($status -eq 429) { 3600 } else { 300 }); Write-ClaudeCache $Cache
            return @{ State = 'limited'; RetryAt = $Cache.renewBlockedUntil; Detail = "HTTP $status" }
        }
        try { $j = $text | ConvertFrom-Json } catch { $j = $null }
        $safe = '^[A-Za-z0-9._~+/=-]{20,4096}$'   # never write anything else into the credentials file
        $access = [string]$j.access_token; $newRefresh = [string]$j.refresh_token
        if ($access -notmatch $safe -or ($newRefresh -and $newRefresh -notmatch $safe)) { return @{ State = 'failed'; Detail = 'unexpected token response' } }
        $lifetime = [long]28800
        try { $v = [long]$j.expires_in; if ($v -ge 60 -and $v -le 31536000) { $lifetime = $v } } catch { }
        $expiresAtMs = ($Now + $lifetime) * 1000
        $saved = $false
        for ($try = 0; $try -lt 5 -and -not $saved; $try++) {
            try { $saved = Save-ClaudeTokens $CredPath $refresh $access $newRefresh $expiresAtMs; break }
            catch { Start-Sleep -Milliseconds 200 }
        }
        if ($saved) { Write-WidgetLog ('Renewed the Claude Code login (valid until {0:HH:mm}).' -f [DateTimeOffset]::FromUnixTimeMilliseconds($expiresAtMs).LocalDateTime) }
        else { Write-WidgetLog 'Renewed the Claude Code login but did not save it (the credentials file changed or was locked).' }
        $Cache.renewBlockedUntil = 0; Write-ClaudeCache $Cache
        @{ State = 'renewed'; Token = $access }
    }

    # Returns @{ Result = <usage result>; NextAt = <unix seconds of the next attempt> }
    function Update-Claude([int]$IntervalMin, [bool]$Manual, [bool]$AutoRenew) {
        $now = Get-UnixNow
        $interval = [Math]::Max(5, $IntervalMin) * 60
        $r = New-UsageResult 'Claude Code'
        $r.Source = 'api'
        $cache = Read-ClaudeCache

        $credPath = Join-Path (Get-ClaudeDir) '.credentials.json'
        $oauth = $null
        if (Test-Path $credPath) { try { $oauth = (Get-Content $credPath -Raw | ConvertFrom-Json).claudeAiOauth } catch { } }
        if ($oauth) {
            $tier = [string]$oauth.rateLimitTier
            $r.PlanKey = if ($tier -match '20x') { 'max20x' } elseif ($tier -match '5x') { 'max5x' } else { ([string]$oauth.subscriptionType).ToLowerInvariant() }
            $r.Plan = switch ($r.PlanKey) { 'max20x' { 'Max 20x' } 'max5x' { 'Max 5x' } default { Format-Title $oauth.subscriptionType } }
        }

        function Use-Cache {
            if ($cache.body) {
                try { $r.Windows = ConvertFrom-ClaudeBody $cache.body; $r.UpdatedAt = [DateTimeOffset]::FromUnixTimeSeconds($cache.fetchedAt) } catch { }
            }
        }

        if ($cache.blockedUntil -gt $now) {
            Use-Cache
            $r.Error = 'rate limited'
            $r.Detail = 'The usage API asked us to wait until {0:HH:mm}.' -f [DateTimeOffset]::FromUnixTimeSeconds($cache.blockedUntil).LocalDateTime
            return @{ Result = $r; NextAt = $cache.blockedUntil + 5 }
        }
        $minAge = if ($Manual) { 120 } else { $interval }
        if ($cache.body -and ($now - $cache.fetchedAt) -lt $minAge) {
            Use-Cache
            return @{ Result = $r; NextAt = $cache.fetchedAt + $interval }
        }
        if (-not $oauth -or -not $oauth.accessToken) {
            Use-Cache
            $r.Error = 'not signed in'
            $r.Detail = "No Claude Code login found in $credPath. Run 'claude' and sign in."
            return @{ Result = $r; NextAt = $now + 60 }
        }
        $accessToken = [string]$oauth.accessToken
        $expired = $oauth.expiresAt -and [long]$oauth.expiresAt -lt $now * 1000
        if ($expired -and -not $AutoRenew) {
            Use-Cache
            $r.Error = 'login expired'
            $r.Detail = "The Claude Code login on this PC has expired. Run 'claude' once in a terminal, or turn on 'Renew Claude login automatically' in the menu."
            return @{ Result = $r; NextAt = $now + 60 }
        }
        if ($AutoRenew -and $oauth.expiresAt -and [long]$oauth.expiresAt -lt ($now + 300) * 1000) {
            $renewal = Invoke-ClaudeTokenRenewal $credPath $cache $now
            switch ($renewal.State) {
                'renewed' { $accessToken = $renewal.Token }
                'invalid' {
                    Use-Cache
                    $r.Error = 'sign in needed'
                    $r.Detail = "Claude Code's saved login can't be renewed. Run 'claude auth login' in a terminal; the widget picks the new login up within a minute."
                    return @{ Result = $r; NextAt = $now + 60 }
                }
                'limited' {
                    Use-Cache
                    $r.Error = 'login expired'
                    $r.Detail = "Couldn't renew the Claude Code login yet; next try at {0:HH:mm}. If this keeps happening, run 'claude auth login'." -f [DateTimeOffset]::FromUnixTimeSeconds($renewal.RetryAt).LocalDateTime
                    return @{ Result = $r; NextAt = $renewal.RetryAt + 5 }
                }
                default {
                    Use-Cache
                    $r.Error = 'offline'
                    $r.Detail = "Couldn't renew the Claude Code login: $($renewal.Detail)"
                    return @{ Result = $r; NextAt = $now + 120 }
                }
            }
        }

        $client = [Net.Http.HttpClient]::new()
        $client.Timeout = [TimeSpan]::FromSeconds(15)
        $client.MaxResponseContentBufferSize = 1MB
        try {
            $req = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, 'https://api.anthropic.com/api/oauth/usage')
            $req.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $accessToken)
            $null = $req.Headers.TryAddWithoutValidation('anthropic-beta', 'oauth-2025-04-20')
            $null = $req.Headers.TryAddWithoutValidation('User-Agent', 'quota-burndown/' + $AppVersion)
            $res = $client.SendAsync($req).GetAwaiter().GetResult()
            $status = [int]$res.StatusCode
            $body = $res.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        } catch {
            Use-Cache
            $r.Error = 'offline'
            $r.Detail = 'Could not reach api.anthropic.com: ' + $_.Exception.GetBaseException().Message
            return @{ Result = $r; NextAt = $now + 120 }
        } finally { $client.Dispose() }

        if ($status -eq 200) {
            try { $wins = ConvertFrom-ClaudeBody $body } catch { $wins = $null }
            if ($null -ne $wins) {
                $cache.fetchedAt = $now; $cache.blockedUntil = 0; $cache.body = $body
                Write-ClaudeCache $cache
                $r.Windows = $wins; $r.UpdatedAt = [DateTimeOffset]::FromUnixTimeSeconds($now)
                return @{ Result = $r; NextAt = $now + $interval }
            }
            Use-Cache
            $r.Error = 'unexpected response'
            $r.Detail = 'The usage API answered with a format this widget does not understand.'
            return @{ Result = $r; NextAt = $now + $interval }
        }

        Use-Cache
        if ($status -eq 401 -or $status -eq 403) {
            $r.Error = 'login rejected'
            $r.Detail = "The usage API rejected the Claude Code token (HTTP $status). If this persists, run 'claude auth login'."
            return @{ Result = $r; NextAt = $now + 300 }
        }
        $wait = 300
        $r.Error = "API error $status"
        if ($status -eq 429) {
            $wait = 1800
            $ra = $res.Headers.RetryAfter
            if ($ra -and $ra.Delta) { $wait = [int]$ra.Delta.Value.TotalSeconds + 5 }
            elseif ($ra -and $ra.Date) { $wait = [int]($ra.Date.Value - [DateTimeOffset]::UtcNow).TotalSeconds + 5 }
            $r.Error = 'rate limited'
        }
        $wait = [Math]::Min(6 * 3600, [Math]::Max(60, $wait))
        $cache.blockedUntil = $now + $wait
        Write-ClaudeCache $cache
        $r.Detail = 'Usage API returned HTTP {0}; next try at {1:HH:mm}.' -f $status, [DateTimeOffset]::FromUnixTimeSeconds($now + $wait).LocalDateTime
        @{ Result = $r; NextAt = $now + $wait }
    }

    # ----- Codex usage ------------------------------------------------------

    function Get-CodexHome { if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' } }

    function Find-CodexExe {
        $cmd = Get-Command codex.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd) { return $cmd.Source }
        # The Codex desktop app ships the CLI in a content-hashed folder that changes on update.
        $appBin = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'
        if (Test-Path $appBin) {
            $exe = Get-ChildItem $appBin -Filter codex.exe -Recurse -Depth 1 -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($exe) { return $exe.FullName }
        }
        # npm global install: prefer the native binary over the .cmd shim.
        $shim = Get-Command codex.cmd -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($shim) {
            $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
            $triple = if ($arch -eq 'arm64') { 'aarch64-pc-windows-msvc' } else { 'x86_64-pc-windows-msvc' }
            $root = Split-Path $shim.Source
            foreach ($c in @(
                    (Join-Path $root "node_modules\@openai\codex\node_modules\@openai\codex-win32-$arch\vendor\$triple\bin\codex.exe"),
                    (Join-Path $root "node_modules\@openai\codex\vendor\$triple\bin\codex.exe"))) {
                if (Test-Path $c) { return $c }
            }
            return $shim.Source
        }
        $null
    }

    function Get-CodexLive([string]$Exe) {
        $psi = [Diagnostics.ProcessStartInfo]::new($Exe, 'app-server --stdio')
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
        $p = [Diagnostics.Process]::Start($psi)
        try {
            $null = $p.StandardError.ReadToEndAsync()   # drain so the pipe never blocks
            $p.StandardInput.NewLine = "`n"
            $p.StandardInput.AutoFlush = $true
            $p.StandardInput.WriteLine('{"id":1,"method":"initialize","params":{"clientInfo":{"name":"quota-burndown","version":"' + $AppVersion + '"}}}')
            $deadline = [DateTime]::UtcNow.AddSeconds(20)
            $received = 0
            while ($true) {
                $left = [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds
                if ($left -le 0) { throw 'Codex app-server timed out' }
                $t = $p.StandardOutput.ReadLineAsync()
                if (-not $t.Wait($left)) { throw 'Codex app-server timed out' }
                $line = $t.Result
                if ($null -eq $line) { throw 'Codex app-server exited before replying' }
                $received += $line.Length
                if ($received -gt 4MB) { throw 'Codex app-server sent too much data' }
                if (-not $line.StartsWith('{')) { continue }
                try { $m = $line | ConvertFrom-Json } catch { continue }
                if ($m.id -eq 1) {
                    if ($m.error) { throw 'Codex app-server initialization failed' }
                    $p.StandardInput.WriteLine('{"method":"initialized"}')
                    $p.StandardInput.WriteLine('{"id":2,"method":"account/rateLimits/read","params":null}')
                } elseif ($m.id -eq 2) {
                    if ($m.error) { throw ('Codex rate-limit request failed: ' + $m.error.message) }
                    return $m.result
                }
            }
        } finally {
            try { $p.StandardInput.Close() } catch { }
            if (-not $p.WaitForExit(1500)) { try { $p.Kill($true) } catch { try { $p.Kill() } catch { } } }
            $p.Dispose()
        }
    }

    function Get-CodexWindowLabel([int]$Minutes) {
        if ($Minutes -eq 300) { return '5-hour' }
        if ($Minutes -eq 10080) { return 'Weekly' }
        '{0}-hour' -f [Math]::Round($Minutes / 60)
    }

    function Get-CodexSessionFiles([int]$Days) {
        $root = Join-Path (Get-CodexHome) 'sessions'
        if (-not (Test-Path $root)) { return }
        for ($d = 0; $d -lt $Days; $d++) {
            $dir = Join-Path $root ('{0:yyyy}\{0:MM}\{0:dd}' -f (Get-Date).AddDays(-$d))
            if (Test-Path $dir) { Get-ChildItem $dir -Filter *.jsonl -File }
        }
    }

    function Get-CodexFromLogs {
        $files = @(Get-CodexSessionFiles 8 | Sort-Object LastWriteTime -Descending | Select-Object -First 8)
        $now = [DateTimeOffset]::UtcNow
        $flat = @(); $plan = $null; $newest = $null
        foreach ($f in $files) {
            try { $lines = (Read-FileTail $f.FullName 262144) -split "`n" } catch { continue }
            for ($i = $lines.Count - 1; $i -ge 0; $i--) {
                if (-not $lines[$i].Contains('"rate_limits"')) { continue }
                try { $o = $lines[$i] | ConvertFrom-Json } catch { continue }
                $rl = $o.payload.rate_limits
                if (-not $rl) { continue }
                $at = ConvertTo-Dto $o.timestamp
                if ($at -and (-not $newest -or $at -gt $newest)) { $newest = $at }
                if (-not $plan -and $rl.plan_type) { $plan = [string]$rl.plan_type }
                foreach ($k in 'primary', 'secondary') {
                    $w = $rl.$k
                    if (-not $w -or -not $w.window_minutes) { continue }
                    $reset = ConvertTo-Dto $w.resets_at
                    if (-not $reset -or $reset -le $now) { continue }
                    $flat += [pscustomobject]@{ Mins = [int]$w.window_minutes; Reset = $reset.ToUnixTimeSeconds(); Pct = [double]$w.used_percent; At = $at }
                }
                break
            }
        }
        if ($flat.Count -eq 0) { return $null }
        # Concurrent sessions report the same account pool, but a freshly started one
        # can log a zeroed block. Trust the reset time most sessions agree on and take
        # the highest percentage within it (usage only climbs inside a window).
        $wins = @()
        foreach ($g in ($flat | Group-Object Mins | Sort-Object { [int]$_.Name })) {
            $best = $g.Group | Group-Object Reset |
                Sort-Object @{ Expression = { $_.Count }; Descending = $true }, @{ Expression = { ($_.Group | Measure-Object -Property At -Maximum).Maximum }; Descending = $true } |
                Select-Object -First 1
            $pct = ($best.Group | Measure-Object -Property Pct -Maximum).Maximum
            $wins += New-UsageWindow (Get-CodexWindowLabel ([int]$g.Name)) $pct ([int]$g.Name) ([long]$best.Name)
        }
        [pscustomobject]@{ Windows = $wins; Plan = $plan; At = $newest }
    }

    function Update-Codex([int]$IntervalMin) {
        $now = Get-UnixNow
        $interval = [Math]::Max(1, $IntervalMin) * 60
        $r = New-UsageResult 'Codex'
        $liveError = $null
        $exe = Find-CodexExe
        if ($exe) {
            try {
                $live = Get-CodexLive $exe
                $rl = $live.rateLimits
                if (-not $rl -and $live.rateLimitsByLimitId) { $rl = $live.rateLimitsByLimitId.codex }
                if (-not $rl) { throw 'Codex returned no rate limits' }
                $wins = @()
                foreach ($w in @($rl.primary, $rl.secondary)) {
                    if ($w -and $w.windowDurationMins) {
                        $wins += New-UsageWindow (Get-CodexWindowLabel ([int]$w.windowDurationMins)) $w.usedPercent ([int]$w.windowDurationMins) $w.resetsAt
                    }
                }
                $r.Windows = $wins
                if ($rl.planType) { $r.PlanKey = ([string]$rl.planType).ToLowerInvariant(); $r.Plan = Format-Title $rl.planType }
                $r.UpdatedAt = [DateTimeOffset]::UtcNow
                $r.Source = 'live'
                return @{ Result = $r; NextAt = $now + $interval }
            } catch { $liveError = $_.Exception.Message }
        } else { $liveError = 'Codex CLI not found' }

        $logs = $null
        try { $logs = Get-CodexFromLogs } catch { }
        if ($logs) {
            $r.Windows = $logs.Windows
            if ($logs.Plan) { $r.PlanKey = $logs.Plan.ToLowerInvariant(); $r.Plan = Format-Title $logs.Plan }
            $r.UpdatedAt = $logs.At
            $r.Source = 'logs'
            $r.Detail = "Live query failed ($liveError); showing the latest values from Codex session logs."
            return @{ Result = $r; NextAt = $now + $interval }
        }
        $r.Error = if ($exe) { 'unavailable' } else { 'not found' }
        $r.Detail = $liveError
        @{ Result = $r; NextAt = $now + [Math]::Min($interval, 120) }
    }

    # ----- prices -----------------------------------------------------------
    # API list prices in USD per million tokens (September 2026). Used only to
    # estimate what your usage would have cost on the pay-as-you-go API.

    function Get-ClaudePrice([string]$Model) {
        # model prefix, input, output, 5-minute cache write, 1-hour cache write, cache read
        $table = @(
            @('claude-fable-5-1', 10, 50, 12.5, 20, 0.25), @('claude-mythos-5-1', 10, 50, 12.5, 20, 0.25),
            @('claude-fable-5', 10, 50, 12.5, 20, 1.0), @('claude-mythos-5', 10, 50, 12.5, 20, 1.0),
            @('claude-opus-5-5', 4, 20, 5, 8, 0.20), @('claude-opus-5', 5, 25, 6.25, 10, 0.50),
            @('claude-opus-4-1', 15, 75, 18.75, 30, 1.50), @('claude-opus-4-2025', 15, 75, 18.75, 30, 1.50),
            @('claude-opus-4', 5, 25, 6.25, 10, 0.50),
            @('claude-sonnet-5-5', 2, 10, 2.5, 4, 0.20), @('claude-sonnet-5', 2, 10, 2.5, 4, 0.20),
            @('claude-sonnet-4', 3, 15, 3.75, 6, 0.30), @('claude-haiku-4', 1, 5, 1.25, 2, 0.10)
        )
        foreach ($row in $table) { if ($Model -and $Model.StartsWith($row[0])) { return , $row } }
        , $table[4]   # unknown model: price it like the current default (Opus 5.5)
    }

    function Get-CodexPrice([string]$Model) {
        # model prefix, input, cached input, output
        $table = @(@('gpt-6.1-sol', 2, 0.10, 10), @('gpt-5.5', 5, 0.50, 30))
        foreach ($row in $table) { if ($Model -and $Model.StartsWith($row[0])) { return , $row } }
        , $table[0]
    }

    function Get-PlanUsdPerMonth([string]$Tool, [string]$PlanKey) {
        $prices = if ($Tool -eq 'Claude Code') { @{ pro = 20; max5x = 100; max20x = 200; max = 100 } } else { @{ plus = 20; pro = 200 } }
        if ($PlanKey -and $prices.ContainsKey($PlanKey)) { return [double]$prices[$PlanKey] }
        $null
    }

    # ----- burned tokens (local logs) ---------------------------------------
    # Counted from the logs Claude Code and Codex write on this PC, so usage from
    # claude.ai, ChatGPT on the web or other devices is not included. Files are
    # read incrementally: each pass parses only the lines appended since the last.

    function New-TokenState { @{ Files = @{}; List = @(); ListedAt = [DateTime]::MinValue } }

    function Read-NewLines($Files, [string]$Path) {
        $st = $Files[$Path]
        if (-not $st) { $st = @{ Offset = [long]0; Model = ''; Entries = New-Object System.Collections.ArrayList }; $Files[$Path] = $st }
        $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite, Delete')
        try {
            if ($fs.Length -lt $st.Offset) { $st.Offset = [long]0; $st.Entries.Clear() }   # file was rewritten
            if ($fs.Length -eq $st.Offset) { return }
            $null = $fs.Seek($st.Offset, 'Begin')
            $buf = New-Object byte[] ($fs.Length - $st.Offset)
            $read = $fs.Read($buf, 0, $buf.Length)
        } finally { $fs.Dispose() }
        if ($read -le 0) { return }
        $last = [Array]::LastIndexOf($buf, [byte]10, $read - 1)
        if ($last -lt 0) { return }   # no complete line yet
        $st.Offset += $last + 1
        , ([Text.Encoding]::UTF8.GetString($buf, 0, $last + 1) -split "`n")
    }

    function Get-UsageField([string]$Text, [string]$Name) {
        $m = [regex]::Match($Text, '"' + $Name + '":(\d+)')
        if ($m.Success) { [long]$m.Groups[1].Value } else { [long]0 }
    }

    function New-TokenSum { [pscustomobject]@{ Input = [long]0; Output = [long]0; CacheWrite = [long]0; CacheRead = [long]0; Total = [long]0; Cost = [double]0 } }

    function Update-ClaudeTokens($State) {
        $root = Join-Path (Get-ClaudeDir) 'projects'
        if (-not (Test-Path $root)) { return }
        $cut = [DateTimeOffset]::UtcNow.AddDays(-8)
        if (([DateTime]::UtcNow - $State.ListedAt).TotalMinutes -ge 5) {
            # Listing every project folder is the expensive part; do it every 5 minutes.
            $State.List = @(Get-ChildItem $root -Recurse -Filter *.jsonl -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.LastWriteTimeUtc -gt $cut.UtcDateTime } | ForEach-Object { $_.FullName })
            $State.ListedAt = [DateTime]::UtcNow
            foreach ($k in @($State.Files.Keys)) { if ($State.List -notcontains $k) { $State.Files.Remove($k) } }
        }
        foreach ($path in $State.List) {
            try { $lines = Read-NewLines $State.Files $path } catch { continue }
            $entries = $State.Files[$path].Entries
            foreach ($l in $lines) {
                if (-not $l.Contains('"usage":{') -or -not $l.Contains('"type":"assistant"')) { continue }
                $ts = [regex]::Match($l, '"timestamp":"([^"]+)"', 'RightToLeft')
                if (-not $ts.Success) { continue }
                $i = $l.IndexOf('"usage":{')
                $u = $l.Substring($i, [Math]::Min(800, $l.Length - $i))
                $id = [regex]::Match($l, '"id":"(msg_[^"]+)"')
                $model = [regex]::Match($l, '"model":"([^"]+)"')
                $e = [pscustomobject]@{
                    Id         = $(if ($id.Success) { $id.Groups[1].Value } else { $null })
                    At         = [DateTimeOffset]::Parse($ts.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture)
                    Input      = Get-UsageField $u 'input_tokens'
                    CacheWrite = Get-UsageField $u 'cache_creation_input_tokens'
                    CacheRead  = Get-UsageField $u 'cache_read_input_tokens'
                    Output     = Get-UsageField $u 'output_tokens'
                    Cost       = [double]0
                }
                $write1h = Get-UsageField $u 'ephemeral_1h_input_tokens'
                $write5m = [Math]::Max([long]0, $e.CacheWrite - $write1h)
                $p = Get-ClaudePrice $(if ($model.Success) { $model.Groups[1].Value } else { '' })
                $e.Cost = ($e.Input * $p[1] + $e.Output * $p[2] + $write5m * $p[3] + $write1h * $p[4] + $e.CacheRead * $p[5]) / 1e6
                $null = $entries.Add($e)
            }
            if ($entries.Count -and $entries[0].At -lt $cut) {
                $keep = @($entries | Where-Object { $_.At -ge $cut })
                $entries.Clear(); foreach ($e in $keep) { $null = $entries.Add($e) }
            }
        }
    }

    function Measure-ClaudeTokens($State, [DateTimeOffset]$Since) {
        # One API message is logged once per content block; count it once (largest output).
        $byId = @{}; $anon = New-Object System.Collections.ArrayList
        foreach ($st in $State.Files.Values) {
            foreach ($e in $st.Entries) {
                if ($e.At -lt $Since) { continue }
                if (-not $e.Id) { $null = $anon.Add($e); continue }
                $prev = $byId[$e.Id]
                if (-not $prev -or $e.Output -gt $prev.Output) { $byId[$e.Id] = $e }
            }
        }
        $s = New-TokenSum
        foreach ($e in @($byId.Values) + @($anon)) {
            $s.Input += $e.Input; $s.Output += $e.Output; $s.CacheWrite += $e.CacheWrite; $s.CacheRead += $e.CacheRead; $s.Cost += $e.Cost
        }
        $s.Total = $s.Input + $s.Output + $s.CacheWrite + $s.CacheRead
        $s
    }

    function Update-CodexTokens($State) {
        $files = @(Get-CodexSessionFiles 9)
        $live = @{}
        foreach ($f in $files) {
            $live[$f.FullName] = $true
            try { $lines = Read-NewLines $State.Files $f.FullName } catch { continue }
            $st = $State.Files[$f.FullName]
            foreach ($l in $lines) {
                if ($l.Contains('"type":"turn_context"')) {
                    $m = [regex]::Match($l, '"model":"([^"]+)"')
                    if ($m.Success) { $st.Model = $m.Groups[1].Value }
                    continue
                }
                if (-not $l.Contains('"token_count"') -or -not $l.Contains('"total_token_usage":{')) { continue }
                $ts = [regex]::Match($l, '"timestamp":"([^"]+)"')
                if (-not $ts.Success) { continue }
                $i = $l.IndexOf('"total_token_usage":{')
                $j = $l.IndexOf('}', $i)
                if ($j -lt 0) { continue }
                $u = $l.Substring($i, $j - $i)
                $null = $st.Entries.Add([pscustomobject]@{
                        At     = [DateTimeOffset]::Parse($ts.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture)
                        Input  = Get-UsageField $u 'input_tokens'
                        Cached = Get-UsageField $u 'cached_input_tokens'
                        Output = Get-UsageField $u 'output_tokens'
                        Total  = Get-UsageField $u 'total_tokens'
                        Model  = $st.Model
                    })
            }
        }
        foreach ($k in @($State.Files.Keys)) { if (-not $live[$k]) { $State.Files.Remove($k) } }
    }

    function Measure-CodexTokens($State, [DateTimeOffset]$Since) {
        # Codex logs running totals per session: sum the increments inside the window.
        $s = New-TokenSum
        foreach ($st in $State.Files.Values) {
            $prev = $null
            foreach ($e in $st.Entries) {
                if ($e.At -lt $Since) { $prev = $e; continue }
                $b = if ($prev -and $e.Total -ge $prev.Total) { $prev } else { $null }   # a drop means the counter restarted
                $cached = $e.Cached - $(if ($b) { $b.Cached } else { 0 })
                $inTok = ($e.Input - $(if ($b) { $b.Input } else { 0 })) - $cached     # Codex counts cached input inside input
                $output = $e.Output - $(if ($b) { $b.Output } else { 0 })
                $p = Get-CodexPrice $e.Model
                $s.Input += $inTok; $s.CacheRead += $cached; $s.Output += $output
                $s.Total += $e.Total - $(if ($b) { $b.Total } else { 0 })
                $s.Cost += ($inTok * $p[1] + $cached * $p[2] + $output * $p[3]) / 1e6
                $prev = $e
            }
        }
        $s
    }

    # Token sums per usage window, keyed by window label ('5-hour', 'Weekly', ...).
    function Get-WindowTokens($Result, $State, [string]$Kind) {
        $now = [DateTimeOffset]::UtcNow
        $wins = @($Result.Windows)
        if ($wins.Count -eq 0) {
            $wins = @([pscustomobject]@{ Label = '5-hour'; Minutes = 300; ResetsAt = $null },
                [pscustomobject]@{ Label = 'Weekly'; Minutes = 10080; ResetsAt = $null })
        }
        $out = @{}
        foreach ($w in $wins) {
            $since = if ($w.ResetsAt -and $w.ResetsAt -gt $now) { $w.ResetsAt.AddMinutes(-$w.Minutes) } else { $now.AddMinutes(-$w.Minutes) }
            $out[$w.Label] = if ($Kind -eq 'claude') { Measure-ClaudeTokens $State $since } else { Measure-CodexTokens $State $since }
        }
        $out
    }

    # ----- usage history & run-out forecast ---------------------------------
    # Every new reading is appended to history.csv (handy for your own analysis,
    # e.g. in Excel or Power BI) and kept in memory to estimate the burn rate.

    function Import-UsageHistory {
        $list = New-Object System.Collections.ArrayList
        $path = Get-DataFile 'history.csv'
        if (-not (Test-Path $path)) { return , $list }
        $cut = [DateTimeOffset]::UtcNow.AddDays(-8)
        $inv = [Globalization.CultureInfo]::InvariantCulture
        foreach ($line in ((Read-FileTail $path 1MB) -split "`n")) {
            $m = [regex]::Match($line.Trim(), '^([^,]+),"([^"]*)","([^"]*)",([^,]+),(.+)$')
            if (-not $m.Success) { continue }
            try {
                $at = [DateTimeOffset]::Parse($m.Groups[1].Value, $inv)
                if ($at -lt $cut) { continue }
                $null = $list.Add([pscustomobject]@{
                        Tool = $m.Groups[2].Value; Label = $m.Groups[3].Value; At = $at
                        Percent = [double]::Parse($m.Groups[4].Value, $inv)
                        ResetsAt = [DateTimeOffset]::Parse($m.Groups[5].Value, $inv).ToUnixTimeSeconds()
                    })
            } catch { }
        }
        , $list
    }

    # Labels come from the APIs: keep the CSV valid (no quotes, commas or line breaks)
    # and inert in spreadsheet apps (no leading = + - @ or tab, however many).
    function ConvertTo-CsvLabel([string]$Label) {
        ($Label -replace '[",\r\n]', ' ') -replace '^[=+\-@\t]+', ''
    }

    function Add-UsageSample($History, $Last, $Result) {
        if (-not $Result -or -not $Result.UpdatedAt) { return }
        $path = Get-DataFile 'history.csv'
        $inv = [Globalization.CultureInfo]::InvariantCulture
        foreach ($w in @($Result.Windows)) {
            if (-not $w.ResetsAt) { continue }
            $key = $Result.Name + '|' + $w.Label
            $prev = $Last[$key]
            if ($prev -and $prev.At -ge $Result.UpdatedAt) { continue }   # this reading is already recorded
            $reset = $w.ResetsAt.ToUnixTimeSeconds()
            $same = $prev -and $prev.Percent -eq $w.Percent -and $prev.ResetsAt -eq $reset
            if ($same -and ($Result.UpdatedAt - $prev.At).TotalMinutes -lt 30) { continue }   # unchanged: one row per 30 min
            $s = [pscustomobject]@{ Tool = $Result.Name; Label = $w.Label; At = $Result.UpdatedAt; Percent = $w.Percent; ResetsAt = $reset }
            $null = $History.Add($s)
            $Last[$key] = $s
            try {
                if (-not (Test-Path $path)) { [IO.File]::WriteAllText($path, "timestamp_utc,tool,window,used_percent,resets_at_utc`n") }
                $label = ConvertTo-CsvLabel $s.Label
                $row = '{0},"{1}","{2}",{3},{4}' -f $s.At.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ', $inv), $s.Tool, $label,
                    $s.Percent.ToString('0.##', $inv), $w.ResetsAt.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ', $inv)
                [IO.File]::AppendAllText($path, $row + "`n", [Text.UTF8Encoding]::new($false))
            } catch { }
        }
    }

    # Burn rate from the last hour (5-hour window) or day (weekly window); falls
    # back to the average since the window started when there is too little history.
    function Get-WindowForecast($History, [string]$Tool, $w, [Nullable[DateTimeOffset]]$UpdatedAt) {
        $now = [DateTimeOffset]::UtcNow
        if (-not $w.ResetsAt -or $w.ResetsAt -le $now) { return $null }
        $reset = $w.ResetsAt.ToUnixTimeSeconds()
        $short = $w.Minutes -le 300
        $lookback = if ($short) { 60 } else { 1440 }
        $pts = @($History | Where-Object {
                $_.Tool -eq $Tool -and $_.Label -eq $w.Label -and [Math]::Abs($_.ResetsAt - $reset) -le 120 -and $_.At -ge $now.AddMinutes(-$lookback)
            } | Sort-Object At)
        if ($UpdatedAt) { $pts += [pscustomobject]@{ At = $UpdatedAt; Percent = $w.Percent } }
        $rate = $null; $method = 'recent'
        if ($pts.Count -ge 2) {
            $span = ($pts[-1].At - $pts[0].At).TotalMinutes
            if ($span -ge $(if ($short) { 10 } else { 60 })) { $rate = [Math]::Max(0.0, ($pts[-1].Percent - $pts[0].Percent) / $span) }
        }
        if ($null -eq $rate) {
            $elapsed = $w.Minutes - ($w.ResetsAt - $now).TotalMinutes
            if ($elapsed -lt 5) { return $null }
            $rate = $w.Percent / $elapsed; $method = 'average'
        }
        $minsLeft = ($w.ResetsAt - $now).TotalMinutes
        $basis = if ($method -eq 'average') { 'average rate' } elseif ($short) { "last hour's rate" } else { "today's rate" }
        $f = [pscustomobject]@{
            RunsOut = $false; HitAt = $null; RatePerHour = $rate * 60; Method = $method; Lookback = $lookback; Basis = $basis
            Projected = [Math]::Min(100.0, $w.Percent + $rate * $minsLeft); Level = 'ok'
        }
        if ($w.Percent -ge 100) { $f.RunsOut = $true; $f.HitAt = $now }
        elseif ($rate -gt 0) {
            $hit = $now.AddMinutes((100 - $w.Percent) / $rate)
            if ($hit -lt $w.ResetsAt) { $f.RunsOut = $true; $f.HitAt = $hit }
        }
        if ($f.RunsOut) {
            # 'alert' only when it is real: already over the even pace AND running out with a
            # margin (at least 15% of the remaining time, min 15 min). Otherwise 'tight':
            # e.g. under pace overall but today was heavier than average.
            $evenPace = 100 * (1 - $minsLeft / $w.Minutes)
            $margin = ($w.ResetsAt - $f.HitAt).TotalMinutes
            $real = $margin -ge [Math]::Max(15.0, 0.15 * $minsLeft)
            $f.Level = if ($w.Percent -ge 100 -or ($w.Percent -gt $evenPace + 0.5 -and $real)) { 'alert' } else { 'tight' }
        }
        $f
    }

    function Get-Forecasts($History, $Result) {
        $out = @{}
        if (-not $Result) { return $out }
        foreach ($w in @($Result.Windows)) { $out[$w.Label] = Get-WindowForecast $History $Result.Name $w $Result.UpdatedAt }
        $out
    }

    # ----- update check (opt-in) --------------------------------------------
    # Only reads the latest release's version number. Nothing is downloaded or run;
    # the widget just offers a link to the release page.

    function ConvertTo-ReleaseVersion([string]$Tag) {
        $m = [regex]::Match([string]$Tag, '^v?(\d{1,4}\.\d{1,4}\.\d{1,6})$')
        if ($m.Success) { $m.Groups[1].Value } else { $null }
    }

    # Returns @{ Version = '1.3.1' } when a newer release exists, otherwise $null.
    # Asks GitHub at most once a day; the answer is remembered in update-check.json.
    function Get-AvailableUpdate([string]$Current) {
        $path = Get-DataFile 'update-check.json'
        $now = Get-UnixNow
        $c = @{ checkedAt = [long]0; latest = '' }
        try { if (Test-Path $path) { $j = Get-Content $path -Raw | ConvertFrom-Json; $c.checkedAt = [long]$j.checkedAt; $c.latest = [string]$j.latest } } catch { }
        if ($c.checkedAt -gt $now -or ($now - $c.checkedAt) -ge 86400) {
            $client = [Net.Http.HttpClient]::new()
            $client.Timeout = [TimeSpan]::FromSeconds(10)
            $client.MaxResponseContentBufferSize = 512KB
            try {
                $req = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, 'https://api.github.com/repos/mondrikrob/quota-burndown/releases/latest')
                $null = $req.Headers.TryAddWithoutValidation('Accept', 'application/vnd.github+json')
                $null = $req.Headers.TryAddWithoutValidation('User-Agent', 'quota-burndown/' + $Current)
                $res = $client.SendAsync($req).GetAwaiter().GetResult()
                $status = [int]$res.StatusCode
                $text = $res.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                $c.checkedAt = $now
                if ($status -eq 200) {
                    $v = ConvertTo-ReleaseVersion ($text | ConvertFrom-Json).tag_name
                    if ($v) { $c.latest = $v }
                } else {
                    $c.checkedAt = $now - 86400 + 3600   # try again in an hour
                    Write-WidgetLog "Update check: HTTP $status"
                }
            } catch {
                $c.checkedAt = $now - 86400 + 3600
                Write-WidgetLog ('Update check: ' + $_.Exception.GetBaseException().Message)
            } finally { $client.Dispose() }
            try { ([pscustomobject]$c) | ConvertTo-Json | Set-Content -Path $path -Encoding UTF8 } catch { }
        }
        $cur = ConvertTo-ReleaseVersion $Current
        if ($c.latest -and $cur -and ([version]$c.latest -gt [version]$cur)) { return @{ Version = $c.latest } }
        $null
    }

    # ----- formatting -------------------------------------------------------

    function Format-Tokens([double]$n) {
        if ($n -ge 1e9) { return '{0:0.0}B' -f ($n / 1e9) }
        if ($n -ge 1e6) { return '{0:0.0}M' -f ($n / 1e6) }
        if ($n -ge 1e3) { return '{0:0}k' -f ($n / 1e3) }
        '{0:0}' -f $n
    }

    function Format-Usd([double]$n) {
        $inv = [Globalization.CultureInfo]::InvariantCulture
        if ($n -ge 100) { '$' + $n.ToString('#,0', $inv) } else { '$' + $n.ToString('0.00', $inv) }
    }

    function Format-Span([TimeSpan]$s) {
        if ($s.TotalMinutes -lt 1) { return '<1m' }
        if ($s.TotalHours -lt 1) { return '{0}m' -f [int][Math]::Floor($s.TotalMinutes) }
        if ($s.TotalDays -lt 1) { return '{0}h {1}m' -f [int][Math]::Floor($s.TotalHours), $s.Minutes }
        '{0}d {1}h' -f [int][Math]::Floor($s.TotalDays), $s.Hours
    }
}

. $DataLayer
$Settings = Read-Settings

function Get-PlanPrice($Result) {
    $override = if ($Result.Name -eq 'Claude Code') { $Settings.ClaudePlanUsdPerMonth } else { $Settings.CodexPlanUsdPerMonth }
    if ($null -ne $override) { return [double]$override }
    Get-PlanUsdPerMonth $Result.Name $Result.PlanKey
}

# ===========================================================================
# Logo: two pairs of signal bars (red = used, grey = remaining, white = even
# pace), the same look as the taskbar strip. Drawn in code so the script stays
# a single file; written out as a multi-size .ico for the tray and shortcuts.
# ===========================================================================

Add-Type -AssemblyName System.Drawing

function New-LogoBitmap([int]$Size) {
    $k = $Size / 32.0
    $bmp = [Drawing.Bitmap]::new($Size, $Size)
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([Drawing.Color]::Transparent)
    $color = { param($hex) [Drawing.ColorTranslator]::FromHtml($hex) }
    $rounded = {
        param($brush, [double]$x, [double]$y, [double]$w, [double]$h, [double]$r)
        $p = [Drawing.Drawing2D.GraphicsPath]::new(); $d = [Math]::Max(0.1, 2 * $r)
        $p.AddArc($x, $y, $d, $d, 180, 90); $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
        $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90); $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
        $p.CloseFigure(); $g.FillPath($brush, $p); $p.Dispose()
    }
    $bg = [Drawing.SolidBrush]::new((& $color '#1E1F22')); $red = [Drawing.SolidBrush]::new((& $color '#F85149'))
    $grey = [Drawing.SolidBrush]::new((& $color '#55585E')); $white = [Drawing.SolidBrush]::new((& $color '#FFFFFF'))
    & $rounded $bg 0 0 $Size $Size (7 * $k)
    $used = 0.75, 0.35, 0.20, 0.55; $pace = 0.50, 0.60, 0.30, 0.40
    $bw = 4 * $k; $top = 6 * $k; $base = 26 * $k; $h = $base - $top
    $xs = 4, 10, 18, 24   # two pairs, centred: 4 + (4+2+4) + 4 + (4+2+4) + 4
    for ($i = 0; $i -lt 4; $i++) {
        $x = $xs[$i] * $k
        & $rounded $grey $x $top $bw $h (1.5 * $k)
        & $rounded $red $x ($base - $h * $used[$i]) $bw ($h * $used[$i]) (1.5 * $k)
        $g.FillRectangle($white, [float]($x - 0.5 * $k), [float]($base - $h * $pace[$i] - 0.8 * $k), [float]($bw + $k), [float](1.6 * $k))
    }
    foreach ($o in $bg, $red, $grey, $white, $g) { $o.Dispose() }
    $bmp
}

function Save-LogoIcon([string]$Path) {
    # A .ico file is a small directory followed by PNG images, one per size.
    $sizes = 16, 20, 24, 32, 40, 48, 64, 256
    $pngs = foreach ($s in $sizes) {
        $b = New-LogoBitmap $s; $ms = [IO.MemoryStream]::new()
        $b.Save($ms, [Drawing.Imaging.ImageFormat]::Png); $b.Dispose()
        , $ms.ToArray()
    }
    $out = [IO.MemoryStream]::new(); $w = [IO.BinaryWriter]::new($out)
    $w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$sizes.Count)
    $offset = 6 + 16 * $sizes.Count
    for ($i = 0; $i -lt $sizes.Count; $i++) {
        $s = $sizes[$i]
        $w.Write([byte]$(if ($s -ge 256) { 0 } else { $s })); $w.Write([byte]$(if ($s -ge 256) { 0 } else { $s }))
        $w.Write([byte]0); $w.Write([byte]0); $w.Write([uint16]1); $w.Write([uint16]32)
        $w.Write([uint32]$pngs[$i].Length); $w.Write([uint32]$offset)
        $offset += $pngs[$i].Length
    }
    foreach ($p in $pngs) { $w.Write($p) }
    $w.Flush()
    [IO.File]::WriteAllBytes($Path, $out.ToArray())
    $w.Dispose()
}

# ===========================================================================
# Command-line modes
# ===========================================================================

if ($Once) {
    $history = Import-UsageHistory
    foreach ($kind in 'claude', 'codex') {
        $r = if ($kind -eq 'claude') { (Update-Claude $Settings.ClaudeRefreshMinutes $false ([bool]$Settings.ClaudeAutoRenewLogin)).Result } else { (Update-Codex $Settings.CodexRefreshMinutes).Result }
        $st = New-TokenState
        if ($kind -eq 'claude') { Update-ClaudeTokens $st } else { Update-CodexTokens $st }
        $tokens = Get-WindowTokens $r $st $kind
        $forecasts = Get-Forecasts $history $r
        $hdr = $r.Name + $(if ($r.Plan) { " ($($r.Plan))" }) + $(if ($r.Source) { " [$($r.Source)]" }) + $(if ($r.Error) { " ERROR: $($r.Error)" })
        Write-Output $hdr
        if ($r.Detail) { Write-Output "  $($r.Detail)" }
        foreach ($w in $r.Windows) {
            $t = $tokens[$w.Label]; $f = $forecasts[$w.Label]
            $line = '  {0,-16} {1,5:0}%  resets {2:ddd HH:mm}  tokens {3,7}  ~{4} API' -f $w.Label, $w.Percent, $w.ResetsAt.LocalDateTime, (Format-Tokens $t.Total), (Format-Usd $t.Cost)
            if ($f -and $f.Level -eq 'alert') { $line += '  RUNS OUT ~{0:ddd HH:mm} ({1})' -f $f.HitAt.LocalDateTime, $f.Basis }
            elseif ($f -and $f.Level -eq 'tight') { $line += '  tight: out ~{0:ddd HH:mm} ({1})' -f $f.HitAt.LocalDateTime, $f.Basis }
            elseif ($f) { $line += '  ~{0:0}% by reset' -f $f.Projected }
            Write-Output $line
        }
    }
    return
}

$StartupLink = Join-Path ([Environment]::GetFolderPath('Startup')) 'Quota Burndown.lnk'
$StartMenuLink = Join-Path ([Environment]::GetFolderPath('Programs')) 'Quota Burndown.lnk'
$InstalledScript = Join-Path $DataDir 'QuotaBurndown.ps1'
$MutexName = 'Local\QuotaBurndown'
$ExitEventName = 'Local\QuotaBurndown-Exit'

function New-LaunchShortcut([string]$Path, [string]$Script = $PSCommandPath) {
    # conhost --headless keeps a console window from flashing up, even when
    # Windows Terminal is the default terminal host.
    $sh = New-Object -ComObject WScript.Shell
    $lnk = $sh.CreateShortcut($Path)
    $lnk.TargetPath = Join-Path $env:WINDIR 'System32\conhost.exe'
    $lnk.Arguments = '--headless "{0}" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{1}"' -f
        (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'), $Script
    $lnk.WorkingDirectory = Split-Path $Script
    $ico = Join-Path $DataDir 'quota-burndown.ico'
    try { Save-LogoIcon $ico } catch { }
    $lnk.IconLocation = if (Test-Path $ico) { $ico + ',0' } else { (Join-Path $env:WINDIR 'System32\imageres.dll') + ',-1024' }
    $lnk.Description = 'Quota Burndown - Claude Code and Codex usage limits'
    $lnk.Save()
}

function Stop-RunningWidget {
    # Ask politely first (the widget then removes its tray icon), then make sure.
    $ev = $null
    if ([Threading.EventWaitHandle]::TryOpenExisting($ExitEventName, [ref]$ev)) { $null = $ev.Set(); $ev.Dispose() }
    $m = [Threading.Mutex]::new($false, $MutexName)
    try { $free = $m.WaitOne(5000) } catch [Threading.AbandonedMutexException] { $free = $true }
    if ($free) { $m.ReleaseMutex() }
    $m.Dispose()
    if ($free) { return }
    # Only processes running the installed copy are touched.
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" |
        Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -and $_.CommandLine.IndexOf($InstalledScript, [StringComparison]::OrdinalIgnoreCase) -ge 0 } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
}

# Asks a yes/no question at install time. Returns $null when nobody can answer
# (no console input), so the question is asked again at the next interactive install.
function Read-YesNo([string]$Text) {
    try { if ([Console]::IsInputRedirected -or -not [Environment]::UserInteractive) { return $null } } catch { return $null }
    Write-Host ''
    Write-Host $Text
    while ($true) {
        try { $a = Read-Host '  Your choice [y/N]' } catch { return $null }
        if ($a -match '^\s*(y|yes)\s*$') { return $true }
        if ($a -match '^\s*(n|no)?\s*$') { return $false }
    }
}

function Request-InstallChoices {
    $changed = $false
    if ($null -eq $Settings.ClaudeAutoRenewLogin) {
        $Settings.ClaudeAutoRenewLogin = Read-YesNo @'
Renew the Claude Code login automatically?
  Claude Code's login on this PC lasts about 8 hours. The Claude desktop app does
  not renew it; only the 'claude' command does, when you run it. Quota Burndown can
  renew it for you by talking to Anthropic's login server the way Claude Code does
  (it presents itself as Claude Code). This is not an official Anthropic feature: it
  may stop working, and Anthropic could consider it against their terms of service.
  If you answer no, the widget shows "login expired" and you run 'claude' once.
'@
        $changed = $changed -or ($null -ne $Settings.ClaudeAutoRenewLogin)
    }
    if ($null -eq $Settings.CheckForUpdates) {
        $Settings.CheckForUpdates = Read-YesNo @'
Check for new versions once a day?
  The widget asks api.github.com for the latest Quota Burndown release number and,
  if it is newer, shows a link to the release page. Nothing is downloaded or
  installed automatically, and nothing about you or your usage is sent.
'@
        $changed = $changed -or ($null -ne $Settings.CheckForUpdates)
    }
    if ($changed) { Save-Settings $Settings }
}

if ($Install) {
    Stop-RunningWidget
    $Settings = Read-Settings   # the old widget saved its own settings while exiting
    Request-InstallChoices
    if ((Resolve-Path $PSCommandPath).Path -ne $InstalledScript) { Copy-Item $PSCommandPath $InstalledScript -Force }
    New-LaunchShortcut $StartMenuLink $InstalledScript
    if (Test-Path $StartupLink) { New-LaunchShortcut $StartupLink $InstalledScript }
    # Launch through Explorer so the widget never inherits another app's sandbox.
    Start-Process explorer.exe -ArgumentList ('"{0}"' -f $StartMenuLink)
    Write-Output "Quota Burndown $AppVersion installed to $InstalledScript and started."
    $state = { param($v) if ($v -eq $true) { 'on' } elseif ($v -eq $false) { 'off' } else { 'off (not asked: no console)' } }
    Write-Output ('  Renew Claude login automatically: {0}' -f (& $state $Settings.ClaudeAutoRenewLogin))
    Write-Output ('  Check for updates daily:          {0}' -f (& $state $Settings.CheckForUpdates))
    Write-Output '  You can change both later from the widget menu (right-click).'
    return
}

if ($Uninstall) {
    Stop-RunningWidget
    foreach ($p in $StartMenuLink, $StartupLink, $InstalledScript) { if (Test-Path $p) { Remove-Item $p -Force } }
    Write-Output "Quota Burndown removed. Settings, cache and history are still in $DataDir; delete that folder to remove them too."
    return
}

# ===========================================================================
# UI
# ===========================================================================

$mutex = [Threading.Mutex]::new($false, $MutexName)
try { $owned = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned = $true }
if (-not $Snapshot -and -not $owned) { return }
$exitEvent = [Threading.EventWaitHandle]::new($false, 'AutoReset', $ExitEventName)

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing
if (-not ('QuotaBurndown.Native' -as [type])) {
    Add-Type -Namespace QuotaBurndown -Name Native -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindow(string cls, string name);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string name);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int max);
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
[DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int index);
[DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr h, int index, int value);
'@
}

# ----- background worker ---------------------------------------------------

$sync = [hashtable]::Synchronized(@{
        Claude = $null; Codex = $null; Tokens = @{}; Forecast = @{}
        Version = 0; RefreshRequested = $false; Stop = $false
        ClaudeInterval = $Settings.ClaudeRefreshMinutes; CodexInterval = $Settings.CodexRefreshMinutes
        AutoRenew = [bool]$Settings.ClaudeAutoRenewLogin; CheckUpdates = [bool]$Settings.CheckForUpdates; Update = $null; AppVersion = $AppVersion
    })
$sync.Claude = New-UsageResult 'Claude Code'; $sync.Claude.Loading = $true
$sync.Codex = New-UsageResult 'Codex'; $sync.Codex.Loading = $true

$WorkerLoop = {
    $ErrorActionPreference = 'Stop'
    Set-Variable -Name AppVersion -Value $sync.AppVersion -Scope Script   # read by the data layer
    $claudeNext = 0; $codexNext = 0; $derivedNext = 0; $updateNext = 0
    $tokClaude = New-TokenState; $tokCodex = New-TokenState
    $history = Import-UsageHistory; $last = @{}
    foreach ($s in $history) { $last[$s.Tool + '|' + $s.Label] = $s }
    while (-not $sync.Stop) {
        $manual = $false
        if ($sync.RefreshRequested) { $sync.RefreshRequested = $false; $manual = $true; $claudeNext = 0; $codexNext = 0 }
        $now = Get-UnixNow
        if ($now -ge $claudeNext) {
            try {
                $u = Update-Claude $sync.ClaudeInterval $manual ([bool]$sync.AutoRenew)
                $sync.Claude = $u.Result; $claudeNext = $u.NextAt
                Add-UsageSample $history $last $u.Result
                if ($u.Result.Error) { Write-WidgetLog ('Claude: {0} - {1}' -f $u.Result.Error, $u.Result.Detail) }
            } catch { Write-WidgetLog "Claude worker: $_"; $claudeNext = $now + 120 }
            $derivedNext = 0; $sync.Version++
        }
        if ($now -ge $codexNext) {
            try {
                $u = Update-Codex $sync.CodexInterval
                $prev = $sync.Codex
                if ($u.Result.Source -ne 'live' -and $prev -and $prev.Source -eq 'live' -and ([DateTimeOffset]::UtcNow - $prev.UpdatedAt).TotalMinutes -lt 20) {
                    $codexNext = $now + 60   # a blip in the live query: a recent live reading beats stale log values
                } else {
                    $sync.Codex = $u.Result; $codexNext = $u.NextAt
                    Add-UsageSample $history $last $u.Result
                }
                if ($u.Result.Detail) { Write-WidgetLog ('Codex: {0}' -f $u.Result.Detail) }
            } catch { Write-WidgetLog "Codex worker: $_"; $codexNext = $now + 120 }
            $derivedNext = 0; $sync.Version++
        }
        if ($now -ge $derivedNext) {
            # Tokens, value and forecasts: recomputed after every reading and once a minute.
            try {
                Update-ClaudeTokens $tokClaude
                Update-CodexTokens $tokCodex
                $sync.Tokens = @{ 'Claude Code' = (Get-WindowTokens $sync.Claude $tokClaude 'claude'); 'Codex' = (Get-WindowTokens $sync.Codex $tokCodex 'codex') }
                $cut = [DateTimeOffset]::UtcNow.AddDays(-8)
                if ($history.Count -and $history[0].At -lt $cut) {
                    $keep = @($history | Where-Object { $_.At -ge $cut }); $history.Clear(); foreach ($s in $keep) { $null = $history.Add($s) }
                }
                $sync.Forecast = @{ 'Claude Code' = (Get-Forecasts $history $sync.Claude); 'Codex' = (Get-Forecasts $history $sync.Codex) }
            } catch { Write-WidgetLog "Derived values: $_" }
            $derivedNext = $now + 60
            $sync.Version++
        }
        if ($sync.CheckUpdates -and $now -ge $updateNext) {
            # Get-AvailableUpdate itself asks GitHub at most once a day.
            try { $sync.Update = Get-AvailableUpdate $sync.AppVersion; $sync.Version++ } catch { Write-WidgetLog "Update check: $_" }
            $updateNext = $now + 3600
        }
        Start-Sleep -Milliseconds 500
    }
}

$iss = [Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
$iss.Variables.Add([Management.Automation.Runspaces.SessionStateVariableEntry]::new('sync', $sync, ''))
$workerRunspace = [runspacefactory]::CreateRunspace($iss)
$workerRunspace.Open()
$worker = [powershell]::Create()
$worker.Runspace = $workerRunspace
$null = $worker.AddScript($DataLayer.ToString() + "`n" + $WorkerLoop.ToString())
if (-not $Snapshot) { $workerHandle = $worker.BeginInvoke() }

# ----- theme -----------------------------------------------------------------

function New-Brush([string]$Hex) { $b = [Windows.Media.BrushConverter]::new().ConvertFromString($Hex); $b.Freeze(); $b }

$PersonalizeKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
$lightTheme = $false; $lightTaskbar = $false
if ($Theme) { $lightTheme = $lightTaskbar = $Theme -eq 'light' }
else {
    try { $lightTheme = (Get-ItemPropertyValue $PersonalizeKey 'AppsUseLightTheme') -eq 1 } catch { }
    try { $lightTaskbar = (Get-ItemPropertyValue $PersonalizeKey 'SystemUsesLightTheme') -eq 1 } catch { }
}
$Light = @{ Card = '#F5F9F9F9'; Border = '#1F000000'; Text = '#1B1B1B'; Muted = '#5E6369'; Track = '#1A000000'; Tick = '#8C000000'
    Hover = '#14000000'; Ok = '#1A7F37'; Warn = '#9A6700'; Bad = '#CF222E'; Claude = '#C15F3C'; Codex = '#1B1B1B' }
$Dark = @{ Card = '#EB1E1F22'; Border = '#26FFFFFF'; Text = '#F0F0F0'; Muted = '#9AA0A6'; Track = '#33FFFFFF'; Tick = '#B3FFFFFF'
    Hover = '#1FFFFFFF'; Ok = '#3FB950'; Warn = '#D29922'; Bad = '#F85149'; Claude = '#E08A6D'; Codex = '#F0F0F0' }
$T = if ($lightTheme) { $Light } else { $Dark }
$B = @{}; foreach ($k in $T.Keys) { $B[$k] = New-Brush $T[$k] }
$TT = if ($lightTaskbar) { $Light } else { $Dark }    # the strip follows the taskbar's own theme
$SB = @{}; foreach ($k in $TT.Keys) { $SB[$k] = New-Brush $TT[$k] }
$HitBrush = New-Brush '#01000000'    # near-transparent, but still receives clicks
$IconFont = [Windows.Media.FontFamily]::new('Segoe Fluent Icons, Segoe MDL2 Assets')
$Glyph = @{ Refresh = [string][char]0xE72C; Minimize = [string][char]0xE921; Clock = [string][char]0xE823 }
$Sym = @{ Dot = [string][char]0x00B7; Ellipsis = [string][char]0x2026; Dash = [string][char]0x2013; Warn = [string][char]0x26A0; Approx = [string][char]0x2248; Times = [string][char]0x00D7 }

function Get-Severity([double]$Pct) { if ($Pct -ge 90) { 'Bad' } elseif ($Pct -ge 70) { 'Warn' } else { 'Ok' } }

# Local clock time of a reset: "19:00" today, otherwise "Sun 19:35".
function Format-ResetTime([DateTimeOffset]$At) {
    $local = $At.LocalDateTime
    if ($local.Date -le [DateTime]::Today) { '{0:HH:mm}' -f $local } else { '{0:ddd HH:mm}' -f $local }
}

function New-Text([string]$Text, $Brush, [double]$Size = 12) {
    $t = [Windows.Controls.TextBlock]::new()
    $t.Text = $Text; $t.Foreground = $Brush; $t.FontSize = $Size
    $t
}

function Add-Run($TextBlock, [string]$Text, $Brush, [double]$Size, $Weight) {
    $run = [Windows.Documents.Run]::new($Text)
    $run.Foreground = $Brush
    if ($Size) { $run.FontSize = $Size }
    if ($Weight) { $run.FontWeight = $Weight }
    $TextBlock.Inlines.Add($run)
}

function Get-Derived([string]$Key, [string]$Tool, [string]$Label) {
    $all = $sync[$Key]
    if ($all -and $all[$Tool]) { $all[$Tool][$Label] }
}

# Flat icon button. The action lives in Tag because event handlers run after this
# function has returned, so they cannot see its local variables.
function New-IconButton([string]$Glyph, [string]$Tip, [scriptblock]$Action, $Brushes, [double]$Size = 24) {
    $b = [Windows.Controls.Border]::new()
    $b.Width = $Size; $b.Height = $Size - 2; $b.CornerRadius = 4; $b.Background = $HitBrush
    $b.Cursor = [Windows.Input.Cursors]::Hand
    $b.ToolTip = $Tip
    $b.Tag = @{ Action = $Action; Hover = $Brushes.Hover }
    $t = New-Text $Glyph $Brushes.Muted 10
    $t.FontFamily = $IconFont
    $t.HorizontalAlignment = 'Center'; $t.VerticalAlignment = 'Center'
    $b.Child = $t
    $b.Add_MouseEnter({ param($s, $e) $s.Background = $s.Tag.Hover })
    $b.Add_MouseLeave({ param($s, $e) $s.Background = $HitBrush })
    $b.Add_MouseLeftButtonDown({ param($s, $e) $e.Handled = $true })
    $b.Add_MouseLeftButtonUp({ param($s, $e) $e.Handled = $true; & $s.Tag.Action })
    $b
}

# ----- widget window ---------------------------------------------------------

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Quota Burndown" WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ShowInTaskbar="False" ResizeMode="NoResize" SizeToContent="WidthAndHeight"
        FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="12" UseLayoutRounding="True">
  <Border x:Name="Card" CornerRadius="10" Padding="14,6,8,12" BorderThickness="1" Margin="8">
    <Border.Effect>
      <DropShadowEffect BlurRadius="14" ShadowDepth="2" Opacity="0.35"/>
    </Border.Effect>
    <StackPanel>
      <DockPanel Margin="0,0,0,4">
        <StackPanel x:Name="TopButtons" DockPanel.Dock="Right" Orientation="Horizontal"/>
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <TextBlock x:Name="TopTitle" Text="QUOTA BURNDOWN" FontSize="10" VerticalAlignment="Center"/>
          <TextBlock x:Name="UpdateLink" FontSize="10" Margin="8,0,0,0" VerticalAlignment="Center" Cursor="Hand"
                     TextDecorations="Underline" Visibility="Collapsed"/>
        </StackPanel>
      </DockPanel>
      <StackPanel x:Name="Root" Width="236" Margin="0,0,6,0"/>
    </StackPanel>
  </Border>
</Window>
"@
$window = [Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($xaml))
$card = $window.FindName('Card')
$root = $window.FindName('Root')
$card.Background = $B.Card
$card.BorderBrush = $B.Border
$window.FindName('TopTitle').Foreground = $B.Muted
$updateLink = $window.FindName('UpdateLink')
$updateLink.Foreground = $B.Ok
$updateLink.Add_MouseLeftButtonDown({ param($s, $e) $e.Handled = $true })
$updateLink.Add_MouseLeftButtonUp({ param($s, $e) $e.Handled = $true; Open-ReleasePage })

# The page address is built here from a validated version number, never taken from the response.
function Open-ReleasePage {
    $u = $sync.Update
    $url = 'https://github.com/mondrikrob/quota-burndown/releases'
    if ($u -and $u.Version -match '^\d{1,4}\.\d{1,4}\.\d{1,6}$') { $url += '/tag/v' + $u.Version }
    try { Start-Process $url } catch { Write-WidgetLog "Open release page: $_" }
}

function Update-UpdateLink {
    $u = $sync.Update
    if ($u -and $Settings.CheckForUpdates) {
        $updateLink.Text = "v$($u.Version) available"
        $updateLink.ToolTip = "Quota Burndown $($u.Version) is out (you have $AppVersion). Click to open the release page."
        $updateLink.Visibility = 'Visible'
    } else { $updateLink.Visibility = 'Collapsed' }
}
$window.Topmost = [bool]$Settings.Topmost
$BarWidth = 236.0

$topButtons = $window.FindName('TopButtons')
$null = $topButtons.Children.Add((New-IconButton $Glyph.Refresh 'Refresh now' { Request-Refresh } $B))
$null = $topButtons.Children.Add((New-IconButton $Glyph.Minimize 'Minimize to the taskbar' { Show-Widget $false } $B))

function Format-UsdShort([double]$n) { if ($n -ge 10) { '$' + [Math]::Round($n).ToString('#,0', [Globalization.CultureInfo]::InvariantCulture) } else { Format-Usd $n } }

# One window, compact: "Label  24%  9% under ... (reset) 19:00 . 3h 19m", then the bar.
# A third line appears only for a forecast warning; everything else is in the tooltip.
function Add-WindowRow($r, $w, [DateTimeOffset]$Now) {
    $row = [Windows.Controls.StackPanel]::new()
    $row.Margin = '0,8,0,0'
    $row.Background = $HitBrush   # so hovering anywhere on the row shows its tooltip
    [Windows.Controls.ToolTipService]::SetShowDuration($row, 60000)
    $expired = (-not $w.ResetsAt) -or ($w.ResetsAt -le $Now)
    $sev = Get-Severity $w.Percent
    $elapsed = 0.0; $diff = 0
    if (-not $expired) {
        $elapsed = [Math]::Max(0.0, [Math]::Min(1.0, 1 - (($w.ResetsAt - $Now).TotalMinutes / $w.Minutes)))
        $diff = [Math]::Round($w.Percent - $elapsed * 100)
    }

    # Line 1: label, % used, pace; reset time on the right.
    $line = [Windows.Controls.DockPanel]::new()
    $right = [Windows.Controls.TextBlock]::new()
    $right.VerticalAlignment = 'Bottom'
    [Windows.Controls.DockPanel]::SetDock($right, 'Right')
    if ($expired) { Add-Run $right 'window reset' $B.Muted 11 $null }
    else {
        $icon = [Windows.Documents.Run]::new($Glyph.Clock + ' ')   # clock = when it resets (not the refresh arrow)
        $icon.FontFamily = $IconFont; $icon.FontSize = 9; $icon.Foreground = $B.Muted
        $right.Inlines.Add($icon)
        Add-Run $right (Format-ResetTime $w.ResetsAt) $B.Text 11 $null
        Add-Run $right (' ' + $Sym.Dot + ' ' + (Format-Span ($w.ResetsAt - $Now))) $B.Muted 11 $null
    }
    $null = $line.Children.Add($right)
    $left = [Windows.Controls.TextBlock]::new()
    Add-Run $left $w.Label $B.Text 12 $null
    if (-not $expired) {
        Add-Run $left ('  {0:0}%' -f $w.Percent) $B[$sev] 12 ([Windows.FontWeights]::SemiBold)
        if ($diff -ge 1) { Add-Run $left ('  {0}% over' -f $diff) $B[$(if ($diff -ge 10) { 'Bad' } else { 'Warn' })] 11 $null }
        elseif ($diff -le -1) { Add-Run $left ('  {0}% under' -f (-$diff)) $B.Ok 11 $null }
        else { Add-Run $left '  on pace' $B.Ok 11 $null }
    }
    $null = $line.Children.Add($left)
    $null = $row.Children.Add($line)

    # Line 2: bar with the even-pace tick.
    $bar = [Windows.Controls.Grid]::new()
    $bar.Height = 10; $bar.Margin = '0,3,0,0'; $bar.Width = $BarWidth; $bar.HorizontalAlignment = 'Left'
    $track = [Windows.Controls.Border]::new()
    $track.Height = 6; $track.CornerRadius = 3; $track.Background = $B.Track; $track.VerticalAlignment = 'Center'
    $null = $bar.Children.Add($track)
    if (-not $expired) {
        $frac = [Math]::Max(0.0, [Math]::Min(1.0, $w.Percent / 100.0))
        if ($frac -gt 0) {
            $fill = [Windows.Controls.Border]::new()
            $fill.Height = 6; $fill.CornerRadius = 3; $fill.Background = $B[$sev]
            $fill.VerticalAlignment = 'Center'; $fill.HorizontalAlignment = 'Left'
            $fill.Width = [Math]::Max(6.0, $frac * $BarWidth)
            $null = $bar.Children.Add($fill)
        }
        $tick = [Windows.Controls.Border]::new()
        $tick.Width = 2; $tick.Height = 10; $tick.CornerRadius = 1; $tick.Background = $B.Tick
        $tick.HorizontalAlignment = 'Left'
        $tick.Margin = [Windows.Thickness]::new([Math]::Max(0.0, [Math]::Min($BarWidth - 2.0, $elapsed * $BarWidth - 1.0)), 0, 0, 0)
        $null = $bar.Children.Add($tick)
    }
    $null = $row.Children.Add($bar)

    # Line 3, only when it matters: the run-out warning.
    $f = Get-Derived 'Forecast' $r.Name $w.Label
    if ($f -and -not $expired -and $f.RunsOut) {
        $fc = [Windows.Controls.TextBlock]::new()
        $fc.Margin = '0,2,0,0'; $fc.TextWrapping = 'Wrap'
        $when = if (($f.HitAt - $Now).TotalHours -lt 18) { '{0:HH:mm}' -f $f.HitAt.LocalDateTime } else { '{0:ddd HH:mm}' -f $f.HitAt.LocalDateTime }
        $early = Format-Span ($w.ResetsAt - $f.HitAt)
        if ($f.Level -eq 'alert') {
            Add-Run $fc ($Sym.Warn + ' runs out ~' + $when) $B.Bad 11 ([Windows.FontWeights]::SemiBold)
            Add-Run $fc ("  $early before reset") $B.Bad 11 $null
        } else {
            Add-Run $fc 'tight: ' $B.Warn 11 ([Windows.FontWeights]::SemiBold)
            Add-Run $fc ("at $($f.Basis), out ~$when") $B.Warn 11 $null
        }
        $null = $row.Children.Add($fc)
    }

    # Everything else on hover.
    $tip = @()
    if ($expired) { $tip += "$($w.Label): this window has reset; waiting for the next reading." }
    else {
        $tip += '{0}: {1:0}% used' -f $w.Label, $w.Percent
        $tip += 'Should be at {0:0}% at an even pace ({1})' -f ($elapsed * 100), $(if ($diff -ge 1) { "$diff% over" } elseif ($diff -le -1) { "$(-$diff)% under" } else { 'on pace' })
        $tip += 'Resets {0:dddd HH:mm} (in {1})' -f $w.ResetsAt.LocalDateTime, (Format-Span ($w.ResetsAt - $Now))
        if ($f) {
            if ($f.RunsOut) { $tip += 'Forecast: at {0} ({1:0.#}%/h) you run out ~{2:ddd HH:mm}, {3} before the reset' -f $f.Basis, $f.RatePerHour, $f.HitAt.LocalDateTime, (Format-Span ($w.ResetsAt - $f.HitAt)) }
            elseif ($f.RatePerHour -gt 0) { $tip += 'Forecast: at {0} ({1:0.#}%/h) ~{2:0}% by reset' -f $f.Basis, $f.RatePerHour, $f.Projected }
            else { $tip += 'Forecast: no use in the last ' + $(if ($f.Lookback -le 60) { 'hour' } else { 'day' }) }
        }
    }
    $tok = Get-Derived 'Tokens' $r.Name $w.Label
    if ($tok) {
        $tip += ''
        $tip += 'Tokens burned on this PC in this window: {0} (~{1} at API prices)' -f (Format-Tokens $tok.Total), (Format-Usd $tok.Cost)
        $tip += '  input {0}, output {1}, cache write {2}, cache read {3}' -f (Format-Tokens $tok.Input), (Format-Tokens $tok.Output), (Format-Tokens $tok.CacheWrite), (Format-Tokens $tok.CacheRead)
    }
    $tip += ''
    $tip += 'The white tick on the bar marks the even pace.'
    $row.ToolTip = $tip -join "`n"
    $null = $root.Children.Add($row)
}

function Add-ProviderSection($r, [bool]$First) {
    $now = [DateTimeOffset]::UtcNow
    $header = [Windows.Controls.DockPanel]::new()
    $header.Margin = if ($First) { '0' } else { '0,16,0,0' }
    $status = New-Text '' $B.Muted 11
    $status.VerticalAlignment = 'Bottom'
    if ($r.Loading) { $status.Text = 'loading' + $Sym.Ellipsis }
    elseif ($r.Error) { $status.Text = $r.Error; $status.Foreground = $B.Warn }
    elseif ($r.UpdatedAt) {
        $age = $now - $r.UpdatedAt
        $status.Text = if ($age.TotalMinutes -lt 1) { 'just now' } else { (Format-Span $age) + ' ago' }
        if ($r.Source -eq 'logs') { $status.Text = 'from logs ' + $Sym.Dot + ' ' + $status.Text }
    }
    $tips = @()
    if ($r.Detail) { $tips += $r.Detail }
    if ($r.UpdatedAt) { $tips += 'Last updated {0:ddd HH:mm}' -f $r.UpdatedAt.LocalDateTime }
    if ($tips.Count) { $status.ToolTip = ($tips -join "`n") }
    [Windows.Controls.DockPanel]::SetDock($status, 'Right')
    $null = $header.Children.Add($status)
    $title = [Windows.Controls.TextBlock]::new()
    Add-Run $title $r.Name $(if ($r.Name -eq 'Claude Code') { $B.Claude } else { $B.Codex }) 13 ([Windows.FontWeights]::SemiBold)
    if ($r.Plan) { Add-Run $title ('  ' + $r.Plan) $B.Muted 11 $null }
    $null = $header.Children.Add($title)
    $null = $root.Children.Add($header)

    if (-not $r.Loading -and @($r.Windows).Count -eq 0) {
        $msg = New-Text $(if ($r.Detail) { $r.Detail } else { 'No usage data yet.' }) $B.Muted 11
        $msg.TextWrapping = 'Wrap'; $msg.Margin = '0,4,0,0'
        $null = $root.Children.Add($msg)
        return
    }
    foreach ($w in @($r.Windows)) { Add-WindowRow $r $w $now }

    # One summary line: this week's tokens and what they'd cost on the API.
    $week = Get-Derived 'Tokens' $r.Name 'Weekly'
    if ($week -and $week.Total -gt 0) {
        $plan = Get-PlanPrice $r
        $v = [Windows.Controls.TextBlock]::new()
        $v.Margin = '0,8,0,0'; $v.TextWrapping = 'Wrap'; $v.Background = $HitBrush
        [Windows.Controls.ToolTipService]::SetShowDuration($v, 60000)
        Add-Run $v 'This week ' $B.Muted 11 $null
        Add-Run $v (Format-Tokens $week.Total) $B.Text 11 ([Windows.FontWeights]::SemiBold)
        Add-Run $v (' tokens ' + $Sym.Approx + ' ') $B.Muted 11 $null
        Add-Run $v (Format-UsdShort $week.Cost) $B.Text 11 ([Windows.FontWeights]::SemiBold)
        $tip = @("What the tokens {0} burned on this PC in the current weekly window would cost at API list prices: {1}." -f $r.Name, (Format-Usd $week.Cost))
        $tip += '  input {0}, output {1}, cache write {2}, cache read {3}' -f (Format-Tokens $week.Input), (Format-Tokens $week.Output), (Format-Tokens $week.CacheWrite), (Format-Tokens $week.CacheRead)
        if ($plan) {
            $weekly = $plan * 12 / 52
            $ratio = $week.Cost / $weekly
            Add-Run $v (' ' + $Sym.Dot + ' ') $B.Muted 11 $null
            Add-Run $v ('{0:0.0}{1} plan' -f $ratio, $Sym.Times) $B[$(if ($ratio -ge 1) { 'Ok' } else { 'Muted' })] 11 $null
            $tip += 'Your plan: {0}/month = {1}/week, so this is {2:0.0}{3} its price.' -f (Format-Usd $plan), (Format-Usd $weekly), $ratio, $Sym.Times
        } else {
            $tip += 'Set {0}PlanUsdPerMonth in settings.json to compare with your plan.' -f $(if ($r.Name -eq 'Claude Code') { 'Claude' } else { 'Codex' })
        }
        $tip += $(if ($r.Name -eq 'Claude Code') { "The % limits also count claude.ai chats and other devices; these tokens don't." }
                  else { "The % limits also count Codex in ChatGPT on the web and other devices; these tokens don't, so the real value is higher." })
        $v.ToolTip = $tip -join "`n"
        $null = $root.Children.Add($v)
    }
}

# ----- taskbar strip ---------------------------------------------------------
# Windows 11 has no API for taskbar widgets (deskbands are gone), so the strip is
# a small topmost window kept on top of the taskbar, left of the tray area.

[xml]$stripXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Usage Strip" WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ShowInTaskbar="False" ResizeMode="NoResize" SizeToContent="Width" Height="48" Topmost="True"
        ShowActivated="False" FontFamily="Segoe UI Variable Text, Segoe UI" UseLayoutRounding="True">
  <Border x:Name="StripCard" CornerRadius="6" Padding="6,0" Margin="0,4" ToolTipService.InitialShowDelay="250">
    <StackPanel x:Name="StripRows" Orientation="Horizontal" VerticalAlignment="Center"/>
  </Border>
</Window>
"@
$strip = [Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($stripXaml))
$stripCard = $strip.FindName('StripCard')
$stripRows = $strip.FindName('StripRows')
$stripCard.Background = $HitBrush
$SignalHeight = 22.0
$SignalWidth = 6.0
$SignalUsed = $SB.Bad                                                             # red = used
$SignalLeft = New-Brush $(if ($lightTaskbar) { '#40000000' } else { '#5CFFFFFF' })   # grey = remaining
$AlertText = New-Brush '#FFFFFFFF'

# One vertical "signal" bar: red fill = % used, grey = remaining, white line = even
# pace. Below it a tiny "5h" / "7d" label in the tool's colour (red when the
# forecast says the window runs out before it resets).
function New-SignalBar($w, [DateTimeOffset]$Now, [string]$Label, $LabelBrush, [string]$Level) {
    $g = [Windows.Controls.Grid]::new()
    $g.Width = $SignalWidth + 2; $g.Height = $SignalHeight
    $track = [Windows.Controls.Border]::new()
    $track.Width = $SignalWidth; $track.CornerRadius = 2; $track.Background = $SignalLeft
    $null = $g.Children.Add($track)
    if ($w -and $w.ResetsAt -and $w.ResetsAt -gt $Now) {
        $frac = [Math]::Max(0.0, [Math]::Min(1.0, $w.Percent / 100.0))
        if ($frac -gt 0) {
            $fill = [Windows.Controls.Border]::new()
            $fill.Width = $SignalWidth; $fill.CornerRadius = 2; $fill.Background = $SignalUsed
            $fill.VerticalAlignment = 'Bottom'; $fill.Height = [Math]::Max(3.0, $frac * $SignalHeight)
            $null = $g.Children.Add($fill)
        }
        $elapsed = [Math]::Max(0.0, [Math]::Min(1.0, 1 - (($w.ResetsAt - $Now).TotalMinutes / $w.Minutes)))
        $pace = [Windows.Controls.Border]::new()
        $pace.Height = 2; $pace.CornerRadius = 1; $pace.Background = $SB.Tick; $pace.VerticalAlignment = 'Bottom'
        $pace.Margin = [Windows.Thickness]::new(0, 0, 0, [Math]::Max(0.0, [Math]::Min($SignalHeight - 2.0, $elapsed * $SignalHeight - 1.0)))
        $null = $g.Children.Add($pace)
    }
    $lbl = New-Text $Label $(if ($Level -eq 'alert') { $AlertText } else { $LabelBrush }) 8.5
    $lbl.FontWeight = [Windows.FontWeights]::SemiBold
    $lbl.HorizontalAlignment = 'Center'
    $tag = [Windows.Controls.Border]::new()
    $tag.Margin = '0,1,0,0'; $tag.CornerRadius = 2; $tag.Child = $lbl
    # Red pill = will run out before the reset; amber outline = tight.
    if ($Level -eq 'alert') { $tag.Background = $SB.Bad }
    elseif ($Level -eq 'tight') { $tag.BorderBrush = $SB.Warn; $tag.BorderThickness = '1' }
    $col = [Windows.Controls.StackPanel]::new()
    $col.Width = 13; $col.Margin = '0.5,0'
    $null = $col.Children.Add($g); $null = $col.Children.Add($tag)
    $col
}

function Update-Strip {
    $now = [DateTimeOffset]::UtcNow
    $stripRows.Children.Clear()
    $tips = @()
    $first = $true
    foreach ($r in @($sync.Claude, $sync.Codex)) {
        if (-not $r) { continue }
        $wins = @($r.Windows)
        $tone = if ($r.Name -eq 'Claude Code') { $SB.Claude } else { $SB.Text }
        if ($r.Error -and $wins.Count -eq 0) { $tone = $SB.Warn }
        $pair = [Windows.Controls.StackPanel]::new(); $pair.Orientation = 'Horizontal'; $pair.VerticalAlignment = 'Center'
        if (-not $first) { $pair.Margin = '5,0,0,0' }
        $first = $false
        foreach ($spec in @(@('5h', ($wins | Where-Object { $_.Minutes -eq 300 } | Select-Object -First 1)), @('7d', ($wins | Where-Object { $_.Label -eq 'Weekly' } | Select-Object -First 1)))) {
            $w = $spec[1]
            $f = if ($w) { Get-Derived 'Forecast' $r.Name $w.Label }
            $null = $pair.Children.Add((New-SignalBar $w $now $spec[0] $tone $(if ($f) { $f.Level } else { 'ok' })))
        }
        $null = $stripRows.Children.Add($pair)

        $tips += $r.Name + $(if ($r.Plan) { " ($($r.Plan))" })
        foreach ($w in $wins) {
            if (-not $w.ResetsAt -or $w.ResetsAt -le $now) { continue }
            $el = [Math]::Max(0.0, [Math]::Min(1.0, 1 - (($w.ResetsAt - $now).TotalMinutes / $w.Minutes)))
            $line = '    {0}: {1:0}% used (should be at {2:0}%), resets in {3} ({4})' -f $w.Label, $w.Percent, ($el * 100), (Format-Span ($w.ResetsAt - $now)), (Format-ResetTime $w.ResetsAt)
            $tok = Get-Derived 'Tokens' $r.Name $w.Label
            if ($tok) { $line += ', ' + (Format-Tokens $tok.Total) + ' tokens' }
            $f = Get-Derived 'Forecast' $r.Name $w.Label
            if ($f -and $f.Level -eq 'alert') { $line += "`n      " + $Sym.Warn + (' runs out ~{0:ddd HH:mm} at {1}' -f $f.HitAt.LocalDateTime, $f.Basis) }
            elseif ($f -and $f.Level -eq 'tight') { $line += "`n      tight: at {1}, out ~{0:ddd HH:mm} ({2} before reset)" -f $f.HitAt.LocalDateTime, $f.Basis, (Format-Span ($w.ResetsAt - $f.HitAt)) }
            $tips += $line
        }
        if ($r.Loading) { $tips += '    loading' + $Sym.Ellipsis } elseif ($r.Error) { $tips += "    $($r.Error)" }
    }
    $tips += ''
    $tips += '5h = 5-hour window, 7d = weekly. Orange labels = Claude Code, white = Codex.'
    $tips += 'Red = used, grey = remaining, white line = even pace. Red label = runs out before the reset; amber outline = tight.'
    $tips += 'Click to ' + $(if ($window.IsVisible) { 'hide' } else { 'show' }) + ' the widget; drag to move.'
    $stripCard.ToolTip = $tips -join "`n"
}

$script:stripHwnd = [IntPtr]::Zero
$script:stripSource = $null

function Initialize-StripWindow {
    $helper = [Windows.Interop.WindowInteropHelper]::new($strip)
    $script:stripHwnd = $helper.EnsureHandle()
    $script:stripSource = [Windows.Interop.HwndSource]::FromHwnd($script:stripHwnd)
    # Tool window (no Alt+Tab entry) that never takes focus from the app you are using.
    $ex = [QuotaBurndown.Native]::GetWindowLong($script:stripHwnd, -20)
    $null = [QuotaBurndown.Native]::SetWindowLong($script:stripHwnd, -20, ($ex -bor 0x80 -bor 0x08000000))
}

function Get-Rect([IntPtr]$h) {
    $r = New-Object QuotaBurndown.Native+RECT
    if (-not [QuotaBurndown.Native]::GetWindowRect($h, [ref]$r)) { return $null }
    $r
}

function Test-FullscreenForeground($Screen) {
    $fg = [QuotaBurndown.Native]::GetForegroundWindow()
    if ($fg -eq [IntPtr]::Zero) { return $false }
    $sb = New-Object Text.StringBuilder 64
    $null = [QuotaBurndown.Native]::GetClassName($fg, $sb, 64)
    if (@('Progman', 'WorkerW', 'Shell_TrayWnd', 'Shell_SecondaryTrayWnd') -contains $sb.ToString()) { return $false }
    $r = Get-Rect $fg
    $r -and $r.Left -le $Screen.Left -and $r.Top -le $Screen.Top -and $r.Right -ge $Screen.Right -and $r.Bottom -ge $Screen.Bottom
}

function Update-StripPlacement {
    $show = [bool]$Settings.StripVisible
    $tb = [QuotaBurndown.Native]::FindWindow('Shell_TrayWnd', $null)
    $tr = if ($tb -ne [IntPtr]::Zero) { Get-Rect $tb } else { $null }
    if (-not $tr) { $show = $false }
    if ($show) {
        $screen = [Windows.Forms.Screen]::FromHandle($tb).Bounds
        $horizontal = ($tr.Right - $tr.Left) -gt ($tr.Bottom - $tr.Top)
        $onScreen = ($tr.Bottom - $tr.Top) -gt 16 -and $tr.Top -lt $screen.Bottom - 8 -and $tr.Bottom -gt $screen.Top + 8
        if (-not $horizontal -or -not $onScreen -or (Test-FullscreenForeground $screen)) { $show = $false }
    }
    if (-not $show) { if ($strip.IsVisible) { $strip.Hide() }; return }

    $notify = [QuotaBurndown.Native]::FindWindowEx($tb, [IntPtr]::Zero, 'TrayNotifyWnd', $null)
    $nr = if ($notify -ne [IntPtr]::Zero) { Get-Rect $notify } else { $null }
    $anchorPx = if ($nr -and $nr.Left -gt $tr.Left) { $nr.Left } else { $tr.Right - 360 }

    $m = $script:stripSource.CompositionTarget.TransformFromDevice
    $topLeft = $m.Transform([Windows.Point]::new($tr.Left, $tr.Top))
    $bottom = $m.Transform([Windows.Point]::new($tr.Right, $tr.Bottom))
    $anchor = $m.Transform([Windows.Point]::new($anchorPx, $tr.Top)).X

    $height = $bottom.Y - $topLeft.Y
    $width = if ($strip.ActualWidth -gt 0) { $strip.ActualWidth } else { 60 }
    $left = $anchor - $width - [double]$Settings.StripOffset
    $left = [Math]::Max($topLeft.X, [Math]::Min($bottom.X - $width, $left))
    if ([Math]::Abs($strip.Height - $height) -gt 0.5) { $strip.Height = $height }
    if ([Math]::Abs($strip.Top - $topLeft.Y) -gt 0.5) { $strip.Top = $topLeft.Y }
    if ([Math]::Abs($strip.Left - $left) -gt 0.5) { $strip.Left = $left }
    if (-not $strip.IsVisible) { $strip.Show() }
    # Clicking the taskbar raises it above us; put the strip back on top without stealing focus.
    $null = [QuotaBurndown.Native]::SetWindowPos($script:stripHwnd, [IntPtr](-1), 0, 0, 0, 0, 0x0013)
}

# Click toggles the widget, drag slides the strip along the taskbar.
$script:stripDrag = $null
$strip.Add_MouseEnter({ $stripCard.Background = $SB.Hover })
$strip.Add_MouseLeave({ $stripCard.Background = $HitBrush })
$strip.Add_MouseLeftButtonDown({
        $script:stripDrag = @{ X = [Windows.Forms.Cursor]::Position.X; Offset = [double]$Settings.StripOffset; Moved = $false }
        $null = $strip.CaptureMouse()
    })
$strip.Add_MouseMove({
        if (-not $script:stripDrag) { return }
        $dxPx = [Windows.Forms.Cursor]::Position.X - $script:stripDrag.X
        if ([Math]::Abs($dxPx) -lt 4 -and -not $script:stripDrag.Moved) { return }
        $script:stripDrag.Moved = $true
        $dx = $script:stripSource.CompositionTarget.TransformFromDevice.Transform([Windows.Point]::new($dxPx, 0)).X
        $Settings.StripOffset = $script:stripDrag.Offset - $dx
        Update-StripPlacement
    })
$strip.Add_MouseLeftButtonUp({
        $drag = $script:stripDrag
        $script:stripDrag = $null
        $strip.ReleaseMouseCapture()
        if (-not $drag) { return }
        if ($drag.Moved) { Save-Settings $Settings } else { Show-Widget (-not $window.IsVisible) }
    })

# ----- tray icon -------------------------------------------------------------

# The tray icon is just the app logo; the numbers live in its tooltip.
$tray = [Windows.Forms.NotifyIcon]::new()
$IconPath = Join-Path $DataDir 'quota-burndown.ico'
try { Save-LogoIcon $IconPath } catch { Write-WidgetLog "Logo: $_" }
if (Test-Path $IconPath) { $tray.Icon = [Drawing.Icon]::new($IconPath, [Windows.Forms.SystemInformation]::SmallIconSize) }

function Update-Tray {
    $now = [DateTimeOffset]::UtcNow
    $parts = @()
    foreach ($r in @($sync.Claude, $sync.Codex)) {
        if (-not $r) { continue }
        $vals = @()
        foreach ($w in @($r.Windows)) {
            if (-not $w.ResetsAt -or $w.ResetsAt -le $now) { continue }
            if ($w.Label -eq '5-hour') { $vals += '5h {0:0}%' -f $w.Percent } elseif ($w.Label -eq 'Weekly') { $vals += 'wk {0:0}%' -f $w.Percent }
        }
        $short = if ($r.Name -eq 'Claude Code') { 'Claude' } else { 'Codex' }
        if ($vals.Count) { $parts += "$short  " + ($vals -join ' / ') } elseif ($r.Error) { $parts += "$short  $($r.Error)" }
    }
    $tip = if ($parts.Count) { 'Quota Burndown' + "`n" + ($parts -join "`n") } else { 'Quota Burndown' }
    $tray.Text = if ($tip.Length -gt 127) { $tip.Substring(0, 127) } else { $tip }
}

# ----- actions & menus -------------------------------------------------------

function Set-Autostart([bool]$On) {
    if ($On) { New-LaunchShortcut $StartupLink } elseif (Test-Path $StartupLink) { Remove-Item $StartupLink -Force }
}

function Save-Position {
    if ($window.IsVisible) { $Settings.Left = [int]$window.Left; $Settings.Top = [int]$window.Top }
    Save-Settings $Settings
}

function Show-Widget([bool]$Show) {
    if ($Show) { $window.Show(); $null = $window.Activate() } else { Save-Position; $window.Hide() }
    $Settings.Visible = $Show
    Save-Settings $Settings
    Update-Strip
}

function Request-Refresh { $sync.RefreshRequested = $true }

function Exit-Widget {
    Save-Position
    $sync.Stop = $true
    $tray.Visible = $false
    $tray.Dispose()
    try { $null = $workerHandle.AsyncWaitHandle.WaitOne(3000) } catch { }
    try { $worker.Dispose(); $workerRunspace.Dispose() } catch { }
    try { $exitEvent.Dispose() } catch { }
    try { $mutex.ReleaseMutex() } catch { }
    [Windows.Application]::Current.Shutdown()
}

$menu = [Windows.Forms.ContextMenuStrip]::new()
$miUpdate = $menu.Items.Add('Update available')
$miUpdateSep = [Windows.Forms.ToolStripSeparator]::new(); $null = $menu.Items.Add($miUpdateSep)
$miShow = $menu.Items.Add('Show widget')
$miRefresh = $menu.Items.Add('Refresh now')
$null = $menu.Items.Add('-')
$miTop = [Windows.Forms.ToolStripMenuItem]::new('Always on top')
$miStrip = [Windows.Forms.ToolStripMenuItem]::new('Show on taskbar')
$miStripReset = [Windows.Forms.ToolStripMenuItem]::new('Reset taskbar position')
$miStart = [Windows.Forms.ToolStripMenuItem]::new('Start with Windows')
foreach ($mi in $miTop, $miStrip, $miStripReset, $miStart) { $null = $menu.Items.Add($mi) }
$null = $menu.Items.Add('-')
$miRenew = [Windows.Forms.ToolStripMenuItem]::new('Renew Claude login automatically')
$miRenew.ToolTipText = "Renews an expired Claude Code login the way Claude Code does. Unofficial; see SECURITY.md."
$miUpdates = [Windows.Forms.ToolStripMenuItem]::new('Check for updates daily')
$miUpdates.ToolTipText = 'Asks api.github.com for the latest release number once a day. Nothing is downloaded.'
foreach ($mi in $miRenew, $miUpdates) { $null = $menu.Items.Add($mi) }
$miData = $menu.Items.Add('Open data folder')
$null = $menu.Items.Add('-')
$miExit = $menu.Items.Add('Exit')

$menu.Add_Opening({
        $miShow.Text = if ($window.IsVisible) { 'Hide widget' } else { 'Show widget' }
        $miTop.Checked = $window.Topmost
        $miStrip.Checked = [bool]$Settings.StripVisible
        $miStripReset.Enabled = [bool]$Settings.StripVisible
        $miStart.Checked = Test-Path $StartupLink
        $miRenew.Checked = [bool]$Settings.ClaudeAutoRenewLogin
        $miUpdates.Checked = [bool]$Settings.CheckForUpdates
        $u = $sync.Update
        $hasUpdate = [bool]($u -and $Settings.CheckForUpdates)
        $miUpdate.Visible = $hasUpdate; $miUpdateSep.Visible = $hasUpdate
        if ($u) { $miUpdate.Text = "Update available: version $($u.Version)" + $Sym.Ellipsis }
    })
$miUpdate.Add_Click({ Open-ReleasePage })
$miRenew.Add_Click({
        $Settings.ClaudeAutoRenewLogin = -not [bool]$Settings.ClaudeAutoRenewLogin; Save-Settings $Settings
        $sync.AutoRenew = $Settings.ClaudeAutoRenewLogin; Request-Refresh
    })
$miUpdates.Add_Click({
        $Settings.CheckForUpdates = -not [bool]$Settings.CheckForUpdates; Save-Settings $Settings
        $sync.CheckUpdates = $Settings.CheckForUpdates
        if (-not $Settings.CheckForUpdates) { $sync.Update = $null; $sync.Version++ }
    })
$miShow.Add_Click({ Show-Widget (-not $window.IsVisible) })
$miRefresh.Add_Click({ Request-Refresh })
$miTop.Add_Click({ $window.Topmost = -not $window.Topmost; $Settings.Topmost = $window.Topmost; Save-Settings $Settings })
$miStrip.Add_Click({ $Settings.StripVisible = -not $Settings.StripVisible; Save-Settings $Settings; Update-StripPlacement })
$miStripReset.Add_Click({ $Settings.StripOffset = 8; Save-Settings $Settings; Update-StripPlacement })
$miStart.Add_Click({ try { Set-Autostart (-not (Test-Path $StartupLink)) } catch { Write-WidgetLog "Autostart: $_" } })
$miData.Add_Click({ Start-Process explorer.exe -ArgumentList ('"{0}"' -f $DataDir) })
$miExit.Add_Click({ Exit-Widget })

$tray.ContextMenuStrip = $menu
$tray.Add_MouseClick({ param($s, $e) if ($e.Button -eq 'Left') { Show-Widget (-not $window.IsVisible) } })

$window.Add_MouseLeftButtonDown({
        param($s, $e)
        if ($e.ClickCount -eq 2) { Request-Refresh; return }
        try { $window.DragMove() } catch { }
        Save-Position
    })
$window.Add_MouseRightButtonUp({ $menu.Show([Windows.Forms.Cursor]::Position) })
$strip.Add_MouseRightButtonUp({ $menu.Show([Windows.Forms.Cursor]::Position) })

$window.Add_Loaded({
        $vl = [Windows.SystemParameters]::VirtualScreenLeft; $vt = [Windows.SystemParameters]::VirtualScreenTop
        $vw = [Windows.SystemParameters]::VirtualScreenWidth; $vh = [Windows.SystemParameters]::VirtualScreenHeight
        $l = $Settings.Left; $t = $Settings.Top
        $onScreen = ($null -ne $l) -and ($null -ne $t) -and ($l -ge $vl - 50) -and ($t -ge $vt - 20) -and
                    ($l -le $vl + $vw - 80) -and ($t -le $vt + $vh - 60)
        if ($onScreen) { $window.Left = $l; $window.Top = $t }
        else {
            $wa = [Windows.SystemParameters]::WorkArea
            $window.Left = $wa.Right - $window.ActualWidth - 8
            $window.Top = $wa.Bottom - $window.ActualHeight - 8
        }
    })

# ----- render loop -----------------------------------------------------------

$script:shownVersion = -1
$script:lastRender = [DateTime]::MinValue

function Update-View {
    $root.Children.Clear()
    Add-ProviderSection $sync.Claude $true
    Add-ProviderSection $sync.Codex $false
    Update-UpdateLink
    Update-Strip
    Update-Tray
    $script:lastRender = [DateTime]::UtcNow
}

$timer = [Windows.Threading.DispatcherTimer]::new()
$timer.Interval = [TimeSpan]::FromSeconds(1)
$timer.Add_Tick({
        try {
            if ($exitEvent.WaitOne(0)) { Exit-Widget; return }
            $v = $sync.Version
            if ($v -ne $script:shownVersion -or ([DateTime]::UtcNow - $script:lastRender).TotalSeconds -ge 20) {
                $script:shownVersion = $v
                Update-View
            }
        } catch { Write-WidgetLog "Render: $_" }
    })

# A faster loop just for keeping the strip glued to (and above) the taskbar.
$stripTimer = [Windows.Threading.DispatcherTimer]::new()
$stripTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$stripTimer.Add_Tick({ try { if (-not $script:stripDrag) { Update-StripPlacement } } catch { Write-WidgetLog "Strip: $_" } })

$app = [Windows.Application]::new()
$app.ShutdownMode = 'OnExplicitShutdown'
$app.Add_DispatcherUnhandledException({ param($s, $e) Write-WidgetLog ('UI: ' + $e.Exception.Message); $e.Handled = $true })

function Save-ElementPng($Element, [string]$Path) {
    $Element.Measure([Windows.Size]::new([double]::PositiveInfinity, [double]::PositiveInfinity))
    $Element.Arrange([Windows.Rect]::new(0, 0, $Element.DesiredSize.Width, $Element.DesiredSize.Height))
    $Element.UpdateLayout()
    $rtb = [Windows.Media.Imaging.RenderTargetBitmap]::new([int]($Element.ActualWidth * 2) + 4, [int]($Element.ActualHeight * 2) + 4, 192, 192, [Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($Element)
    $enc = [Windows.Media.Imaging.PngBitmapEncoder]::new()
    $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($rtb))
    $fs = [IO.File]::Create($Path)
    try { $enc.Save($fs) } finally { $fs.Dispose() }
}

if ($Snapshot) {
    $sync.Claude = (Update-Claude $Settings.ClaudeRefreshMinutes $false ([bool]$Settings.ClaudeAutoRenewLogin)).Result
    $sync.Codex = (Update-Codex $Settings.CodexRefreshMinutes).Result
    $tc = New-TokenState; $tx = New-TokenState; Update-ClaudeTokens $tc; Update-CodexTokens $tx
    $sync.Tokens = @{ 'Claude Code' = (Get-WindowTokens $sync.Claude $tc 'claude'); 'Codex' = (Get-WindowTokens $sync.Codex $tx 'codex') }
    $hist = Import-UsageHistory
    $sync.Forecast = @{ 'Claude Code' = (Get-Forecasts $hist $sync.Claude); 'Codex' = (Get-Forecasts $hist $sync.Codex) }
    Update-View
    Save-ElementPng $card $Snapshot
    # The strip is transparent on screen; give it a taskbar-coloured backdrop for the preview.
    $stripCard.Background = New-Brush $(if ($lightTaskbar) { '#FFEEEEEE' } else { '#FF1C1C1C' })
    $stripCard.Height = 40; $stripCard.Padding = '14,0'
    Save-ElementPng $stripCard ([IO.Path]::ChangeExtension($Snapshot, $null).TrimEnd('.') + '-strip.png')
    $tray.Dispose()
    return
}

Initialize-StripWindow
Update-View
$tray.Visible = $true
$timer.Start()
$stripTimer.Start()
if ($Settings.Visible) { $window.Show() }
Update-StripPlacement
Write-WidgetLog "Started $AppVersion"
$null = $app.Run()
