# Security and privacy

Quota Burndown is a single PowerShell script (`QuotaBurndown.ps1`) that you can read in full before running it.

## What it reads

| Path | Why |
|---|---|
| `~/.claude/.credentials.json` (or `$CLAUDE_CONFIG_DIR`) | The Claude Code OAuth **access token**, used to call the usage endpoint, and its expiry time. Also the plan type, to price your plan. The widget only reads this file; it never writes it. |
| `~/.claude/projects/**/*.jsonl` | Token usage per message, for the "tokens burned" and "API value" numbers. Only the `usage`, `model`, `id` and `timestamp` fields are extracted. |
| `~/.codex/sessions/**/*.jsonl` (or `$CODEX_HOME`) | Token usage and rate-limit snapshots that Codex logs. |
| `HKCU\...\Themes\Personalize` | Light/dark theme. |

Conversation contents are never parsed, stored or sent anywhere.

## What it sends over the network

- `GET https://api.anthropic.com/api/oauth/usage` with `Authorization: Bearer <Claude Code access token>`, over HTTPS (TLS 1.2+). The response size is capped at 1 MB.
- **Only if you turned on "Check for updates daily"** (off by default): at most once a day, `GET https://api.github.com/repos/mondrikrob/quota-burndown/releases/latest`, without any credentials or personal data. Only the release's version number is used. If it's newer, the widget shows a link to the release page. Nothing is downloaded or installed. The response size is capped at 512 KB.
- For Codex, the script starts the official `codex app-server` and asks it for your rate limits. Any network traffic from that comes from the Codex CLI itself.

Nothing else: no telemetry and no third-party hosts.

## How the token is handled

- **Read for each request.** The token is read from Claude Code's own credentials file before each request and kept only in memory for that request.
- **Read only.** The widget never writes, copies or logs the tokens: not to its cache, not to `widget.log`.

### Automatic login renewal (opt-in)

The Claude desktop app keeps its own login and never updates `~/.claude/.credentials.json`; only the `claude` CLI does, when it runs. So that file's access token expires after about 8 hours. By default the widget then shows **login expired**, and running `claude` once in a terminal fixes it.

If you answer yes at install time (or tick **Renew Claude login automatically** in the menu), the widget does that for you: when the login has expired, it runs **`claude doctor`**, Claude Code's own installation check. While checking your account, Claude Code renews its login and writes it back, exactly as it does every time you use it. The widget then reads the renewed login.

- **Official and free.** It's Claude Code's own command, renewing its own login. It makes no model request, so it uses no tokens.
- **Contained.** `claude` is started without a shell or window, with its input closed (so it can never wait for an answer), and given at most 60 seconds. Its working folder is `%USERPROFILE%\.quota-burndown`, because `claude doctor` reads the settings files of the folder it runs in.
- **Not repeated often.** If the login is still expired afterwards, `claude doctor` runs again after 5 minutes, twice, and then at most every 30 minutes. Meanwhile the widget suggests running `claude` yourself.

Versions 1.1.0 to 1.4.0 renewed the login differently, by calling Anthropic's token endpoint directly as if they were Claude Code. Version 1.5.0 removed that code.

## What it writes

Everything goes to `%USERPROFILE%\.quota-burndown`, which inherits your user profile's permissions:

- `settings.json`
- `claude-usage.json`: the last usage response, which contains no credentials
- `update-check.json`: when the update check last ran and the latest version number (only if the update check is on)
- `history.csv`
- `widget.log`
- `QuotaBurndown.ps1`: the installed copy

It also creates or removes these shortcuts:

- `Quota Burndown.lnk` in your Start menu, when you run `-Install`
- `Quota Burndown.lnk` in your Startup folder, only when you tick **Start with Windows**

Settings are validated when they're read, so a malformed `settings.json` falls back to defaults. Labels written to `history.csv` are sanitised so the file can't carry spreadsheet formulas.

## Execution policy

The shortcuts run `powershell.exe -ExecutionPolicy Bypass -File <script>`. This affects only that process, not your system policy. If your organisation requires signed scripts, sign `QuotaBurndown.ps1` with your own code-signing certificate and remove `-ExecutionPolicy Bypass` from the shortcuts.

## Processes it starts or stops

- **Starts:** `claude.exe doctor`, found on `PATH` or in `~/.local/bin`, only when automatic login renewal is on and the login has expired (at most every 5 minutes for the first tries, then every 30 minutes). See [Automatic login renewal](#automatic-login-renewal-opt-in).
- **Starts:** `codex.exe app-server --stdio`, found on `PATH`, in the Codex desktop app's folder, or in the npm global install. It's started without a shell, given at most 30 seconds and 4 MB of output, then stopped. If it stalls or Codex can't reach its server, it's tried once more (at most 20 seconds).
- **Stops:** `-Install` and `-Uninstall` first signal a running widget to exit. If it doesn't, they stop only PowerShell processes whose command line contains the installed script's path.

## Reporting a vulnerability

Please open a private security advisory on the repository (GitHub → *Security* → *Report a vulnerability*) instead of a public issue.
