# Security and privacy

Quota Burndown is a single PowerShell script (`QuotaBurndown.ps1`) that you can read in full before running it.

## What it reads

| Path | Why |
|---|---|
| `~/.claude/.credentials.json` (or `$CLAUDE_CONFIG_DIR`) | The Claude Code OAuth **access token**, used to call the usage endpoint, and its expiry time. Also the plan type, to price your plan. The widget only reads this file; it never writes it. |
| `~/.claude/projects/**/*.jsonl` | Token usage per message, for the "tokens burned" and "API value" numbers. Only the `usage`, `model`, `id` and `timestamp` fields are extracted. |
| `~/.codex/sessions/**/*.jsonl` (or `$CODEX_HOME`) | Token usage and rate-limit snapshots that Codex logs. |
| `HKCU\...\Themes\Personalize` | Light/dark theme. |

The reader loads chunks of local JSONL files into memory to find usage metadata; these chunks can contain conversation text. The Codex fallback decodes candidate rate-limit events as JSON. The widget does not retain or upload conversation text. Its persisted data contains usage metadata, settings and diagnostic messages.

## What it sends over the network

- `GET https://api.anthropic.com/api/oauth/usage?cedar_ember=1` with `Authorization: Bearer <Claude Code access token>`, over HTTPS (TLS 1.2+). The response size is capped at 1 MB. The query requests banked-reset information. This block is gated on a Claude Code client header: the widget detects the installed version using `claude --version` (once per process, five-second timeout), includes that version and identifies itself as quota-burndown. If version detection fails or the response omits reset details, those details remain unknown. This remains an undocumented integration, not provider-approved access.
- **Only if you turned on "Check for updates daily"** (off by default): `GET https://api.github.com/repos/mondrikrob/quota-burndown/releases/latest`, without credentials or usage data. After a successful check, it waits a day; after a failed check, it may retry once an hour. Only the release's version number is used. If it's newer, the widget shows a link to the release page. Nothing is downloaded or installed. The response size is capped at 512 KB.
- For Codex, the script starts the official `codex app-server` and asks it for your rate limits. Any network traffic from that comes from the Codex CLI itself.

The widget has no telemetry of its own. Requests made by the official CLIs, including the optional `claude doctor` helper, follow those providers' own network behavior and settings. Direct widget HTTP requests do not follow redirects.

## Provider support and credential-use policy

The Claude usage endpoint is undocumented. Anthropic's [current credential-use policy](https://code.claude.com/docs/en/legal-and-compliance#authentication-and-credential-use) restricts third-party handling and routing of subscription credentials. No explicit permission for this monitoring approach has been verified. Calling a read-only usage endpoint or using an official CLI diagnostic does not establish provider approval. Resolve this before claiming broad production readiness.

The Codex integration uses the documented [App Server interface](https://learn.chatgpt.com/docs/app-server). It shows the shared `codex` pool when present; additional model-specific pools are not currently displayed.

## How the token is handled

- **Read for each request.** The token is read from Claude Code's own credentials file before each request and kept only in memory for that request.
- **Read only.** The widget does not write the credentials file or intentionally persist tokens to its cache or log. Invalid token syntax is rejected without echoing it; network error messages redact the access token. Do not publish credential files or raw CLI diagnostics.

### Automatic login renewal (opt-in)

The Claude desktop app uses a separate login. The Claude Code access token in `~/.claude/.credentials.json` can expire; by default the widget then shows **login expired**. Run `claude` in a terminal and sign in if prompted to restore access.

If you answer yes at install time (or tick **Try Claude login renewal (experimental)** in the menu), the widget runs **`claude doctor`** when the login expires. Anthropic [documents this as a diagnostics command](https://code.claude.com/docs/en/cli-reference). Some versions may renew the login as a side effect. Renewal is not documented or guaranteed; the widget checks the expiry afterwards and reports failure if it did not help. Both installer choices default to no.

- **No model request.** The helper invokes Claude Code's diagnostics command; it does not send a prompt. The widget's renewal behavior remains experimental.
- **Contained.** `claude` is started without a shell or window, with its input closed (so it can never wait for an answer), and given at most 60 seconds. Its working folder is `%USERPROFILE%\.quota-burndown`, because `claude doctor` reads the settings files of the folder it runs in.
- **Not repeated often.** If the login is still expired afterwards, `claude doctor` runs again after 5 minutes, twice, and then at most every 30 minutes. Meanwhile the widget suggests running `claude` yourself.

Versions 1.1.0 to 1.4.0 renewed the login differently, by calling Anthropic's token endpoint directly as if they were Claude Code. Version 1.5.0 removed that code.

## What it writes

Everything goes to `%USERPROFILE%\.quota-burndown`, which inherits your user profile's permissions:

- `settings.json`
- `claude-usage.json`: the last usage response, which contains no credentials
- `banked-reset-notifications.json`: observed reset identifiers/counts and expiry-reminder history; no credentials
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

- **Starts:** `claude.exe --version`, once per widget process with a five-second timeout, to obtain the installed client version for the banked-reset usage request. No prompt or login renewal is requested.

- **Starts:** `claude.exe doctor`, found on `PATH` or in `~/.local/bin`, only when automatic login renewal is on and the login has expired (at most every 5 minutes for the first tries, then every 30 minutes). See [Automatic login renewal](#automatic-login-renewal-opt-in).
- **Starts:** `codex.exe app-server --stdio`, found on `PATH`, in the Codex desktop app's folder, or in the npm global install. It runs without a shell from the widget's data folder, with a 30-second deadline and limits of 4 million stdout characters and 65,536 stderr characters. If it stalls or Codex can't reach its server, it is tried once more (20-second deadline). Both pipes are bounded while reading, including output without newlines. The Claude diagnostics helper bounds both pipes to 65,536 characters each.
- **Stops:** `-Install` and `-Uninstall` first signal a running widget to exit. If it does not, they stop only other PowerShell processes with an exact `-File` argument naming the installed script. PowerShell 5.1 can kill the direct CLI child; it cannot guarantee removal of every descendant if a shim or CLI spawns other processes.

## Reporting a vulnerability

Please open a private security advisory on the repository (GitHub → *Security* → *Report a vulnerability*) instead of a public issue.
