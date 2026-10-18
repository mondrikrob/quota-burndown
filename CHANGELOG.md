# Changelog

## 1.9.0 (2026-10-18)

- **Google Gemini (Antigravity & Gemini CLI) support:**
  - Rate-limit tracking for 5-hour and Weekly quota windows, with separate tracking for scoped models (e.g. `Weekly · Argon` under Pro plans).
  - Auto-detection of Gemini subscription tiers (Google AI Pro $20/mo, Ultra $250/mo) and plan value comparison.
  - 3rd pair of taskbar strip signal bars (blue `5h` and `7d`), tray tooltip compacting, and cached fallback display when Antigravity is closed.
  - Transcript token accounting and API list-pricing for Gemini models from Antigravity logs (`transcript.jsonl`).
- **Gemini Flash Scout MCP integration:**
  - Integrated intake token accounting for `gemini-scout-mcp` via `scout-usage.jsonl` with automatic transcript deduplication, priced under Gemini 3.8 Flash.
- **Pricing and model handling updates:**
  - Added `claude-haiku-5-5` pricing and handled `codex-auto-review` models.
- **Documentation and runtime requirements:**
  - Clarified and documented that Antigravity must be running (can be minimized) for live loopback quota queries, while countdown timers and cached snapshots persist when closed.

## 1.8.0 (2026-10-16)

- Show banked reset counts and the next expiry for Claude Code and Codex. Click the reset information to open the provider's usage page; it is also available in the taskbar tooltip.
- Notify when new banked resets are detected and once within the final 24 hours before expiry. Save notification history across restarts, with a right-click menu toggle. Existing credits establish a baseline on first start; missing/stale/error readings do not produce alerts.
- Request Claude reset grants through the existing usage endpoint, using the detected installed Claude Code version. Read Codex reset details from the existing App Server usage response. No reset is redeemed automatically.

## 1.7.0 (2026-10-12)

- **Installer asks about autostart.** `-Install` (and `Install.cmd`) now asks "Start Quota Burndown when you sign in to Windows?", defaulting to yes. Before, autostart was only in the right-click menu, so a fresh install didn't come back after a restart. If **Start with Windows** is already ticked you aren't asked, and the answer is stored as `StartWithWindows` in `settings.json` so reinstalls don't ask again.

## 1.6.0 (2026-10-11)

- **Limit reached is now explicit.** An exhausted window shows a red `× LIMIT REACHED` label in the widget, a white × on its full red taskbar bar, and `FULL` in the tray tooltip. The marker clears after reset or a fresh lower reading.
- **Clearer missing and stale data.** Unavailable or stale strip readings show `?`; forecasts are suppressed on errors or readings older than 15 minutes. Failed Codex refreshes no longer silently keep an apparently healthy live state.
- **Security and correctness.** Bound both subprocess output pipes while reading, enforce deadlines even with continuous output, reject malformed usage responses and token syntax, disable HTTP redirects, validate cached update versions, and tighten forced process matching to the installed `-File` argument.
- **Installation and packaging.** Both consent choices default to no. The installer preserves failure exit codes. Release zips include README, LICENSE and SECURITY; release version input and output-directory replacement are validated.
- **Pricing.** Correct legacy Opus 4 and Sonnet 5.5 cache prices. Unknown model variants remain unpriced, and partial subtotals do not show a plan multiple. Added current Astra and Luna base prices.
- **Usability.** Keyboard-accessible buttons, F5 refresh, Escape hide and Shift+F10 menu. Tray text stays within Windows PowerShell 5.1's 63-character limit. Codex session folders use UTC dates.
- **Release review.** Added response, 100% state, accounting, output-bound, installer-default and packaging regressions; pinned CI dependencies and checkout. Corrected privacy, theme, fullscreen, checksum and provider-support claims. `claude doctor` is a diagnostics command; the earlier claim of guaranteed official renewal is withdrawn. See [the release review](docs/RELEASE_REVIEW.md).

## 1.5.0 (2026-10-05)

- **Renewal helper moved to `claude doctor`.** The widget stopped calling Anthropic's token endpoint directly and stopped writing `~/.claude/.credentials.json`. Instead it runs Claude Code's diagnostics command when the login expires. **Correction (2026-10-11):** this was originally described as “official login renewal.” Anthropic documents diagnostics, not a guaranteed renewal interface; renewal may be a version-dependent side effect. The helper is experimental and makes no model request.
  - Still opt-in, and asked once at install (now with "yes" as the suggested answer). If you turned it on before, it stays on.
  - While the login is expired, the widget checks the login file every minute, so a renewal shows up at once, whoever did it. If `claude doctor` didn't help (for example right after the PC woke and the network wasn't up yet), it's run again after 5 minutes, twice, and then every 30 minutes.
- **Fresher Claude numbers.** Claude usage is now fetched every 5 minutes instead of 15. If your `settings.json` still had the old default of 15, it's moved to 5 once. If you'd rather keep 15, set it again afterwards and it stays. When the endpoint answers "rate limited", the widget still waits as long as it's told.
- **Fix: Codex queries got stuck across sleep.** A query that was running when the PC went to sleep stayed stuck until long after it woke, because Windows doesn't count sleep time for that kind of timeout. Waits now check the real clock every second, so a stale query is stopped and retried within a second of waking.

## 1.4.0 (2026-10-03)

- **Strip on every monitor (optional).** New menu item **Show on all taskbars** (setting `StripAllTaskbars`, off by default): the strip also appears on the taskbars of your other monitors, left of their clock area.
- **Strip fits short taskbars.** On Windows 10's default taskbar or with small taskbar buttons, the bars now scale down instead of being cut off.
- **Steadier Codex numbers.** The live Codex query waits up to 30 seconds (was 20) and is retried once at once when it stalls or Codex can't reach its server, before falling back to "from logs". `widget.log` now says which step failed and after how long.
- **Docs:** Windows 10 compatibility notes; Windows 10 needs version 1809 or newer.

## 1.3.2 (2026-10-03)

- **Fix:** `-Snapshot` cut the widget's right and bottom edges off. The README screenshots are re-rendered with the whole card.
- **Docs:** a "Why" section, a fair comparison with similar tools, an FAQ and status badges in the README; a social preview image; bug report and feature request forms; CONTRIBUTING.md.

## 1.3.1 (2026-10-03)

- **Easier, verifiable install.** Each release now has a zip with a double-click `Install.cmd` (it unblocks the script next to it and runs `-Install`, nothing else), a `SHA256SUMS.txt`, and the checksums in the release notes. The repository is also a **Scoop bucket** with a pinned hash: `scoop bucket add quota-burndown https://github.com/mondrikrob/quota-burndown`.
- **Safer `history.csv`.** Labels lose *all* leading formula characters (`=`, `+`, `-`, `@`, tab), not just the first, so a label like `==1+1` can no longer become a spreadsheet formula.
- **Fix:** forecasts no longer fail for a reading without an update time.
- **Automated checks.** GitHub Actions runs a parse check, PSScriptAnalyzer and Pester tests on Windows PowerShell 5.1 and PowerShell 7 for every push.
- The internal log function is now `Write-WidgetLog`, so it can't clash with PowerShell 7's own `Write-Log`.

## 1.3.0 (2026-10-03)

- **Automatic Claude login renewal is now opt-in** (off by default). The first `-Install` asks you once, with a plain explanation: renewing presents the widget to Anthropic's login server as Claude Code, which is unofficial. You can switch it later in the menu (**Renew Claude login automatically**). When it's off and the login has expired, the widget says "login expired" and asks you to run `claude` once.
- **No more hard-coded Claude Code version.** When renewal is on, the version in its User-Agent comes from your installed `claude --version`.
- **Optional update check.** Also asked once at install, off by default, and in the menu as **Check for updates daily**. When on, the widget asks GitHub at most once a day for the latest release number and, if it's newer, shows a "vX.Y.Z available" link and a menu item that open the release page. Nothing is downloaded or installed.

## 1.2.0 (2026-10-02)

- **New name: Quota Burndown** (was "Usage Widget"). The script is now `QuotaBurndown.ps1` and data lives in `%USERPROFILE%\.quota-burndown`.
- **New logo,** used for the tray icon and the Start menu shortcut. The tray icon no longer shows a number; hover over it for the numbers.
- **Compact widget.** Each window is now two lines: label, % used, how far over or under the even pace you are, and when it resets (a clock icon, then "Sun 19:35 · 2d 3h"), then the bar. A third line appears only for a run-out warning. Each tool gets one summary line: this week's tokens, their API value and the multiple of your plan. Everything else (the even-pace %, forecast details, token breakdowns) is shown when you hover over a row.
- **Calmer run-out warnings.** Red now means you're over the even pace *and* will run out well before the reset. Marginal cases show as amber "tight", and the text says which rate the forecast is based on (last hour, today, or the average).

## 1.1.0 (2026-10-02)

- **Expired logins renew automatically.** The Claude desktop app never updates `~/.claude/.credentials.json`, so the widget now renews an expired Claude Code login itself and writes the new tokens back. See SECURITY.md for how this is done safely.
- **Clearer status messages:** "sign in needed" when the login can't be renewed, and "login expired" with the next retry time when renewal is rate-limited.

## 1.0.0 (2026-10-01)

First public release.

- **Usage display:** the desktop widget, compact taskbar strip and tray icon show the Claude Code and Codex 5-hour and weekly usage windows.
- **Pace:** each window shows the even-pace target ("should be at X%") and how far over or under it you are.
- **Run-out forecast:** based on your recent burn rate.
- **Tokens burned per window:** read from local Claude Code and Codex logs.
- **API-equivalent value:** what this week's tokens would cost at API prices, compared with your plan's price.
- **Usage history:** every reading is written to `history.csv`.
- **Install and uninstall:** `-Install` and `-Uninstall`, plus `-Once` for console output and `-Snapshot` for screenshots.
