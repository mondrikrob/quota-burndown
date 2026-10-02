# Security and privacy

Quota Burndown is a single PowerShell script (`QuotaBurndown.ps1`) that you can read in full before running it.

## What it reads

| Path | Why |
|---|---|
| `~/.claude/.credentials.json` (or `$CLAUDE_CONFIG_DIR`) | The Claude Code OAuth **access token**, used to call the usage endpoint, and the **refresh token**, used to renew it when it has expired. Also the plan type, to price your plan. |
| `~/.claude/projects/**/*.jsonl` | Token usage per message, for the "tokens burned" and "API value" numbers. Only the `usage`, `model`, `id` and `timestamp` fields are extracted. |
| `~/.codex/sessions/**/*.jsonl` (or `$CODEX_HOME`) | Token usage and rate-limit snapshots that Codex logs. |
| `HKCU\...\Themes\Personalize` | Light/dark theme. |

Conversation contents are never parsed, stored or sent anywhere.

## What it sends over the network

- `GET https://api.anthropic.com/api/oauth/usage` with `Authorization: Bearer <Claude Code access token>`, over HTTPS (TLS 1.2+). The response size is capped at 1 MB.
- **Only if you turned on "Renew Claude login automatically"** (off by default), and only when the access token has expired: `POST https://api.anthropic.com/v1/oauth/token` with your refresh token and Claude Code's public OAuth client ID. This is the same renewal the `claude` CLI performs; see [Automatic login renewal](#automatic-login-renewal-opt-in) below. The response size is capped at 64 KB.
- **Only if you turned on "Check for updates daily"** (off by default): at most once a day, `GET https://api.github.com/repos/mondrikrob/quota-burndown/releases/latest`, without any credentials or personal data. Only the release's version number is used. If it's newer, the widget shows a link to the release page. Nothing is downloaded or installed. The response size is capped at 512 KB.
- For Codex, the script starts the official `codex app-server` and asks it for your rate limits. Any network traffic from that comes from the Codex CLI itself.

Nothing else: no telemetry and no third-party hosts.

## How the token is handled

- **Read for each request.** The token is read from Claude Code's own credentials file before each request and kept only in memory for that request.
- **Never copied or logged.** The tokens are not written anywhere except Claude Code's own credentials file (and only by the opt-in renewal below): not to logs, not to the widget's cache. The cache keeps only a short SHA-256 fingerprint of a refresh token the server rejected, so that token isn't retried.

### Automatic login renewal (opt-in)

The Claude desktop app keeps its own login and never updates `~/.claude/.credentials.json`; only the `claude` CLI does, and only when it runs. So that file's access token expires after about 8 hours. By default the widget then shows **login expired**, and running `claude` once in a terminal fixes it.

If you answer yes at install time (or tick **Renew Claude login automatically** in the menu), the widget renews the expired token itself.

**What to know before turning it on.** This is not an official Anthropic feature. To renew the token, the widget presents itself to Anthropic's login server as Claude Code: it uses Claude Code's public OAuth client ID, and a `claude-code/<version>` User-Agent with the version of your installed `claude` CLI. It may stop working at any time, and Anthropic could consider it against their terms of service. Leave it off if that matters to you.

How the renewal is done:
- **Only the token fields change.** Just `accessToken`, `refreshToken` and `expiresAt` inside the `claudeAiOauth` entry. Every other byte of the file, including MCP logins, stays as it was.
- **Atomic write.** The new file is written to a temporary file and swapped in atomically, keeping the original file's permissions.
- **Strict validation.** Tokens from the server are written only if they consist of URL-safe characters.
- **No conflicts.** If the file changed since it was read (for example, the CLI renewed it at the same time), nothing is written.
- **No retries of rejected tokens.** A refresh token the server rejects is never retried; the widget then asks you to run `claude auth login`. Rate-limited renewals back off for an hour.
- **Small residual risk.** Refresh tokens are single-use. If the CLI and the widget renew at the very same moment, one of them loses, and you sign in once with `claude auth login`.

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

- **Starts:** `claude.exe --version`, found on `PATH` or in `~/.local/bin`, only when automatic login renewal is on and a renewal is due, to read the installed version (at most every 6 hours). It's started without a shell or window, with its input closed, and given at most 15 seconds.
- **Starts:** `codex.exe app-server --stdio`, found on `PATH`, in the Codex desktop app's folder, or in the npm global install. It's started without a shell, given at most 30 seconds and 4 MB of output, then stopped. If it stalls or Codex can't reach its server, it's tried once more (at most 20 seconds).
- **Stops:** `-Install` and `-Uninstall` first signal a running widget to exit. If it doesn't, they stop only PowerShell processes whose command line contains the installed script's path.

## Reporting a vulnerability

Please open a private security advisory on the repository (GitHub → *Security* → *Report a vulnerability*) instead of a public issue.
