# Changelog

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
